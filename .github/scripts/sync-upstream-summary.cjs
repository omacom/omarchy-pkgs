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
  if (result.token === 'failure') return 'Could not get the sync App token';
  if (result.should_push === 'failure') return 'Could not inspect the existing PR';
  if (result.hold === 'failure') return 'Could not turn the reviewed PR back into a draft';
  if (result.pr !== 'success' && result.pr !== 'unchanged') return 'Could not push or update the PR';
  if (!result.armable) return '';
  switch (result.merge) {
    case 'success': return '';
    case 'missing': return 'Auto-merge result missing';
    case 'refused': return `Auto-merge refused: ${result.mergeReason || 'no reason given'}`;
    case 'closed': return 'PR was closed before auto-merge';
    default: return 'Could not enable auto-merge';
  }
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
  // The arm job arms auto-merge after the PR jobs and records an outcome per
  // branch and PR number; that outcome is the package's auto-merge result.
  // A PR that should have been armed and has no outcome for its own number
  // is not called passing.
  let armed = {};
  try {
    armed = JSON.parse(readFileSync(join(resultsPath, 'armed.outcomes'), 'utf8'));
  } catch (error) {
    if (error.code !== 'ENOENT') problems.push(`Could not read auto-merge outcomes: ${error.message}`);
  }
  for (const result of results) {
    if (!result || (result.pr !== 'success' && result.pr !== 'unchanged') || result.pr_operation === 'closed' || !result.number || result.review === true) continue;
    const outcome = armed[result.branch];
    const mine = outcome && String(outcome.number) === String(result.number) && typeof outcome.outcome === 'string';
    Object.assign(result, { armable: true, merge: mine ? outcome.outcome : 'missing', mergeReason: mine ? outcome.reason : '' });
  }

  const updates = { passing: 0, unchanged: 0, failing: 0, unknown: 0 };
  const checks = { passing: 0, failing: 0, pending: 0, unknown: 0 };
  const rows = [];
  for (const group of groups) {
    const matches = results.filter(result => result?.branch === group.branch && result.packages === group.packages);
    const result = matches.length === 1 ? matches[0] : undefined;
    const failure = result ? updateFailure(result) : 'Package result missing or duplicated';
    const unchanged = !failure && (result?.pr === 'unchanged' || (result?.pr === 'success' && (result?.pr_operation === 'none' || result?.pr_operation === 'closed')));
    if (!result) {
      updates.unknown++;
      problems.push(`${group.packages}: ${failure}`);
    } else if (failure) updates.failing++;
    else if (unchanged) updates.unchanged++;
    else updates.passing++;

    let pr;
    try {
      pr = await inspectPR({ github, context, group, result });
    } catch (error) {
      pr = { checks: 'unknown', warning: error.message };
    }
    if (pr.warning) core.warning(`${group.packages}: PR checks unavailable: ${pr.warning}`);
    if (pr.checks in checks) checks[pr.checks]++;
    rows.push({ ...group, ...pr, failure, unchanged });
  }

  const succeeded = problems.length === 0;
  const heading = succeeded ? '🟢 Upstream sync ran successfully' : '🔴 Upstream sync failed';
  const content = [`<strong>${heading}</strong>`];
  if (cadence) content.push(`Package group: ${escape(cadence)}.`);
  if (groups.length) {
    content.push(`PR updates: ${updates.passing} passing` +
      (updates.unchanged ? `, ${updates.unchanged} unchanged` : '') +
      `, ${updates.failing} failing` +
      (updates.unknown ? `, ${updates.unknown} unknown` : '') + '.');
    content.push(`PR checks at notification time: ${checks.passing} passing, ${checks.failing} failing, ${checks.pending} pending` +
      (checks.unknown ? `, ${checks.unknown} unknown` : '') + '.');
  } else if (succeeded) content.push('No package updates needed.');

  for (const problem of problems) content.push(escape(problem));
  for (const row of rows) {
    const reasons = [];
    if (row.failure) reasons.push(row.failure);
    if (!row.unchanged) {
      if (row.checks === 'failing') reasons.push('PR checks failing');
      if (row.checks === 'unknown') reasons.push('PR checks unavailable');
      if (!row.failure && row.checks === 'not available') reasons.push('PR link unavailable');
    }
    if (!reasons.length) continue;
    const target = row.url ? link(row.url, `${row.packages} #${row.number}`) :
      `${escape(row.packages)} — no PR link available; ${link(runUrl, 'view run')}`;
    content.push(`${target}: ${escape(reasons.join('; '))}.`);
  }
  content.push(link(runUrl, 'View run'));

  const html = content.join('<br>');
  // Only post to Basecamp when a run needs attention: workflow or package
  // update failures, or failing/unavailable checks on a newly created or
  // updated PR. Truly green runs (no updates, clean updates with passing or
  // pending checks, and unchanged open PRs) still write the Actions summary.
  const actionable = !succeeded ||
    updates.failing > 0 ||
    updates.unknown > 0 ||
    rows.some(row => !row.unchanged && row.checks !== 'passing' && row.checks !== 'pending');
  const quiet = !actionable;
  core.setOutput('content', quiet ? '' : html);
  const table = rows.length ? '<table><tr><th>Package / PR</th><th>PR update</th><th>PR checks</th></tr>' +
    rows.map(row => `<tr><td>${row.url ? link(row.url, `${row.packages} #${row.number}`) : escape(row.packages)}</td>` +
      `<td>${escape(row.failure || (row.unchanged ? 'Unchanged' : 'Passing'))}</td><td>${escape(row.checks)}</td></tr>`).join('') + '</table>' : '';
  await core.summary.addRaw(html + table).write();
  // Missing reports and orchestration errors remain failures. Individual PR
  // update/check failures are actionable summary data, not a failed sync.
  if (!succeeded) core.setFailed('Upstream sync did not complete; see the summary.');
  return { succeeded, updates, checks, rows, content: quiet ? '' : html };
};
