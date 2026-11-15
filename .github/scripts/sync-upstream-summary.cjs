const { readdirSync, readFileSync } = require('node:fs');
const { join } = require('node:path');

const escape = value => String(value).replace(/[&<>"']/g, char => ({
  '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
})[char]);
const link = (url, label) => `<a href="${escape(url)}">${escape(label)}</a>`;

function readResults(path) {
  let files;
  try {
    files = readdirSync(path);
  } catch (error) {
    if (error.code === 'ENOENT') return [];
    throw error;
  }
  return files.filter(file => file.endsWith('.json'))
    .map(file => JSON.parse(readFileSync(join(path, file), 'utf8')));
}

function updateFailure(result) {
  if (result.apply !== 'success') return 'Could not apply the package update';
  if (result.pr !== 'success') return 'Could not push or update the PR';
  if (!['success', 'skipped'].includes(result.merge)) return 'Could not enable auto-merge';
  return '';
}

async function inspectPR({ github, context, group, result }) {
  let number = Number(result?.number);
  if (!number) {
    // create-pull-request has no outputs when its push fails. The existing
    // open PR still gives the maintainer somewhere useful to investigate.
    const { data: prs } = await github.rest.pulls.list({
      ...context.repo, head: `${context.repo.owner}:${group.branch}`,
      state: 'open', per_page: 100,
    });
    number = prs.find(pr => pr.head.ref === group.branch &&
      pr.head.repo?.full_name.toLowerCase() ===
        `${context.repo.owner}/${context.repo.repo}`.toLowerCase())?.number;
  }
  if (!number) return { checks: 'not available' };

  const url = `${context.serverUrl || 'https://github.com'}/${context.repo.owner}/${context.repo.repo}/pull/${number}`;
  try {
    const data = await github.graphql(`query($owner: String!, $repo: String!, $number: Int!) {
      repository(owner: $owner, name: $repo) {
        pullRequest(number: $number) {
          merged
          state
          commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        }
      }
    }`, { ...context.repo, number });
    const pr = data.repository.pullRequest;
    const state = pr.commits.nodes[0]?.commit.statusCheckRollup?.state;
    let checks;
    if (['FAILURE', 'ERROR'].includes(state)) checks = 'failing';
    else if (state === 'SUCCESS') checks = 'passing';
    else if (!state && (pr.merged || pr.state === 'CLOSED')) checks = 'unknown';
    else checks = 'pending'; // Includes checks that have not registered yet.
    return { number, url, checks };
  } catch (error) {
    // A status lookup must not turn a completed package update into a failed
    // sync. Keep the PR link, and explicitly report unavailable check results.
    return { number, url, checks: 'unknown', warning: error.message };
  }
}

module.exports = async function summarize({ github, context, core, groups,
  syncResult, prsResult, resultsPath, cadence }) {
  const runUrl = `${context.serverUrl || 'https://github.com'}/${context.repo.owner}/${context.repo.repo}/actions/runs/${context.runId}`;
  const problems = [];
  if (syncResult !== 'success') problems.push(`Sync job: ${syncResult}`);
  if (prsResult !== 'success' && !(prsResult === 'skipped' && groups.length === 0)) {
    problems.push(`PR workflow: ${prsResult}`);
  }

  let results = [];
  try {
    results = readResults(resultsPath);
  } catch (error) {
    problems.push(`Could not read package results: ${error.message}`);
  }

  const updates = { passing: 0, failing: 0, unknown: 0 };
  const checks = { passing: 0, failing: 0, pending: 0, unknown: 0 };
  const rows = [];
  for (const group of groups) {
    const matches = results.filter(result => result?.branch === group.branch && result.packages === group.packages);
    const result = matches.length === 1 ? matches[0] : undefined;
    const failure = result ? updateFailure(result) : 'Package result missing or duplicated';
    if (!result) {
      updates.unknown++;
      problems.push(`${group.packages}: ${failure}`);
    } else if (failure) updates.failing++;
    else updates.passing++;

    let pr;
    try {
      pr = await inspectPR({ github, context, group, result });
    } catch (error) {
      pr = { checks: 'unknown', warning: error.message };
    }
    if (pr.warning) core.warning(`${group.packages}: PR checks unavailable: ${pr.warning}`);
    if (pr.checks in checks) checks[pr.checks]++;
    rows.push({ ...group, ...pr, failure });
  }

  const succeeded = problems.length === 0;
  const heading = succeeded ? '🟢 Upstream sync ran successfully' : '🔴 Upstream sync failed';
  const content = [`<strong>${heading}</strong>`];
  if (cadence) content.push(`Package group: ${escape(cadence)}.`);
  if (groups.length) {
    content.push(`PR updates: ${updates.passing} passing, ${updates.failing} failing` +
      (updates.unknown ? `, ${updates.unknown} unknown` : '') + '.');
    content.push(`PR checks at notification time: ${checks.passing} passing, ${checks.failing} failing, ${checks.pending} pending` +
      (checks.unknown ? `, ${checks.unknown} unknown` : '') + '.');
  } else if (succeeded) content.push('No package updates needed.');

  for (const problem of problems) content.push(escape(problem));
  for (const row of rows) {
    const reasons = [];
    if (row.failure) reasons.push(row.failure);
    if (row.checks === 'failing') reasons.push('PR checks failing');
    if (row.checks === 'unknown') reasons.push('PR checks unavailable');
    if (!reasons.length) continue;
    const target = row.url ? link(row.url, `${row.packages} #${row.number}`) :
      `${escape(row.packages)} — no PR link available; ${link(runUrl, 'view run')}`;
    content.push(`${target}: ${escape(reasons.join('; '))}.`);
  }
  content.push(link(runUrl, 'View run'));

  const html = content.join('<br>');
  core.setOutput('content', html);
  const table = rows.length ? '<table><tr><th>Package / PR</th><th>PR update</th><th>PR checks</th></tr>' +
    rows.map(row => `<tr><td>${row.url ? link(row.url, `${row.packages} #${row.number}`) : escape(row.packages)}</td>` +
      `<td>${escape(row.failure || 'Passing')}</td><td>${escape(row.checks)}</td></tr>`).join('') + '</table>' : '';
  await core.summary.addRaw(html + table).write();
  // Missing reports and orchestration errors remain failures. Individual PR
  // update/check failures are actionable summary data, not a failed sync.
  if (!succeeded) core.setFailed('Upstream sync did not complete; see the summary.');
  return { succeeded, updates, checks, rows, content: html };
};
