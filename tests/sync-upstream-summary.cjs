const assert = require('node:assert/strict');
const { test } = require('node:test');
const { existsSync, mkdtempSync, readFileSync, writeFileSync, rmSync } = require('node:fs');
const { execFileSync, spawnSync } = require('node:child_process');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const summarize = require('../.github/scripts/sync-upstream-summary.cjs');

function fixture(t, count = 1) {
  const resultsPath = mkdtempSync(join(tmpdir(), 'sync-results-'));
  t.after(() => rmSync(resultsPath, { recursive: true, force: true }));
  const groups = Array.from({ length: count }, (_, i) => ({
    branch: `auto/sync-upstream-package-${i}`, packages: `package-${i}`,
  }));
  const results = groups.map((group, i) => ({
    ...group, apply: 'success', pr: 'success', merge: 'success', number: String(i + 1),
  }));
  const states = new Map(results.map(result => [Number(result.number), 'SUCCESS']));
  const merged = new Set();
  const lookup = [];
  const failures = [];
  const warnings = [];
  const outputs = {};
  let summary;
  const github = {
    rest: { pulls: { list: async args => {
      lookup.push(args);
      return { data: groups.map((group, i) => ({
        number: i + 1, head: { ref: group.branch, repo: { full_name: 'omacom/omarchy-pkgs' } },
      })) };
    } } },
    graphql: async (_, { owner, repo, number }) => {
      assert.equal(owner, 'omacom');
      assert.equal(repo, 'omarchy-pkgs');
      const state = states.get(number);
      if (state instanceof Error) throw state;
      return { repository: { pullRequest: {
        merged: merged.has(number), state: merged.has(number) ? 'MERGED' : 'OPEN',
        commits: { nodes: [{ commit: { statusCheckRollup: state ? { state } : null } }] },
      } } };
    },
  };
  // The arm job's outcomes, keyed by branch and PR number, as package-prs.yml
  // writes them; armed: false leaves them out, as when the job never ran.
  const invoke = ({ armed = true, ...overrides } = {}) => {
    results.forEach((result, i) => writeFileSync(join(resultsPath, `${i}.json`), JSON.stringify(result)));
    if (armed) {
      const outcomes = Object.fromEntries(results.filter(r => r && (r.pr === 'success' || r.pr === 'unchanged') && r.number && r.review !== true)
        .map(r => [r.branch, { number: r.number, outcome: r.merge }]));
      writeFileSync(join(resultsPath, 'armed.outcomes'), JSON.stringify(outcomes));
    }
    return summarize({
      github, context: { repo: { owner: 'omacom', repo: 'omarchy-pkgs' }, runId: 123 },
      core: {
        warning: message => warnings.push(message),
        setFailed: message => failures.push(message),
        setOutput: (name, value) => { outputs[name] = value; },
        summary: { addRaw: html => { summary = html; return { write: async () => {} }; } },
      },
      groups, resultsPath, syncResult: 'success', prsResult: 'success', ...overrides,
    });
  };
  return { groups, results, states, merged, github, invoke, lookup, failures, warnings, outputs,
    resultsPath, get summary() { return summary; } };
}

test('10 passing PRs and one failed build leave the sync green and link to the failure', async t => {
  const f = fixture(t, 11);
  f.states.set(11, 'FAILURE');
  const result = await f.invoke();
  assert.equal(result.succeeded, true);
  assert.deepEqual(f.failures, []);
  assert.deepEqual(result.checks, { passing: 10, failing: 1, pending: 0, unknown: 0 });
  assert.match(f.outputs.content, /Upstream sync ran successfully/);
  assert.match(f.outputs.content, /PR checks at notification time: 10 passing, 1 failing, 0 pending/);
  assert.match(f.outputs.content, /href="https:\/\/github.com\/omacom\/omarchy-pkgs\/pull\/11">package-10 #11<\/a>: PR checks failing/);
  assert.match(f.summary, /<th>PR update<\/th><th>PR checks<\/th>/);
});

test('a rejected PR push counts as a package failure and finds its existing PR', async t => {
  const f = fixture(t, 7); // The reported run: six updates succeeded, Strata's push failed.
  Object.assign(f.results[6], { pr: 'failure', merge: 'skipped', number: '' });
  const result = await f.invoke();
  assert.equal(result.succeeded, true);
  assert.deepEqual(result.updates, { passing: 6, unchanged: 0, failing: 1, unknown: 0 });
  assert.deepEqual(f.failures, []);
  assert.deepEqual(f.lookup, [{ owner: 'omacom', repo: 'omarchy-pkgs',
    head: 'omacom:auto/sync-upstream-package-6', state: 'open', per_page: 100 }]);
  assert.match(result.content, /PR updates: 6 passing, 1 failing/);
  assert.match(result.content, /pull\/7">package-6 #7<\/a>: Could not push or update the PR/);
});

test('the workflow records failed outcomes despite successful conclusions and keeps retry keys stable', async t => {
  const f = fixture(t);
  const workflow = readFileSync(join(__dirname, '../.github/workflows/package-prs.yml'), 'utf8');
  const script = workflow.match(/- name: Record this package's result[\s\S]*?run: \|\n([\s\S]*?)(?=\n      - name: Upload)/)[1]
    .split('\n').map(line => line.replace(/^          /, '')).join('\n');
  const outputPath = join(f.resultsPath, 'outputs');
  const steps = {
    apply: { outcome: 'success', conclusion: 'success' },
    pr: { outcome: 'failure', conclusion: 'success', outputs: {} },
  };
  for (const attempt of ['1', '2']) {
    execFileSync('bash', ['-e', '-o', 'pipefail', '-c', script], {
      env: { ...process.env, RUNNER_TEMP: f.resultsPath, GITHUB_OUTPUT: outputPath,
        GITHUB_RUN_ATTEMPT: attempt, GROUP_JSON: JSON.stringify(f.groups[0]), STEPS_JSON: JSON.stringify(steps) },
    });
  }
  const keys = readFileSync(outputPath, 'utf8').trim().split('\n').map(line => line.slice('key='.length));
  assert.equal(keys[0], keys[1]);
  const record = JSON.parse(readFileSync(join(f.resultsPath, 'package-pr-results', `${keys[0]}.json`), 'utf8'));
  assert.deepEqual(record, { ...f.groups[0], apply: 'success', token: 'skipped', should_push: 'skipped', hold: 'skipped', pr: 'failure', pr_operation: '', number: '' });
  const result = await f.invoke({ resultsPath: join(f.resultsPath, 'package-pr-results') });
  assert.equal(result.succeeded, true);
  assert.equal(result.updates.failing, 1);
});

test('apply and auto-merge errors are package results even when all packages fail', async t => {
  const f = fixture(t, 2);
  Object.assign(f.results[0], { apply: 'failure', pr: 'skipped', merge: 'skipped', number: '' });
  f.results[1].merge = 'failure';
  const result = await f.invoke();
  assert.equal(result.succeeded, true);
  assert.equal(result.updates.failing, 2);
  assert.match(result.content, /Could not apply the package update/);
  assert.match(result.content, /Could not enable auto-merge/);
});

test('a failed App token is reported as such, not as a failed push', async t => {
  const f = fixture(t, 1);
  Object.assign(f.results[0], { token: 'failure', hold: 'skipped', pr: 'skipped', merge: 'skipped', number: '' });
  const result = await f.invoke();
  assert.equal(result.updates.failing, 1);
  assert.match(result.content, /Could not get the sync App token/);
  assert.doesNotMatch(result.content, /Could not push or update the PR/);
});

test("a PR the arm job did not report on is not called passing", async t => {
  const f = fixture(t, 2);
  const result = await f.invoke({ armed: false });
  assert.equal(result.updates.failing, 2);
  assert.match(result.content, /Auto-merge result missing/);
});

test("an outcome for another PR on the same branch does not count", async t => {
  const f = fixture(t, 1);
  await f.invoke();
  writeFileSync(join(f.resultsPath, 'armed.outcomes'), JSON.stringify({ [f.groups[0].branch]: { number: '99', outcome: 'success' } }));
  const results = f.results.map(r => ({ ...r }));
  const result = await summarize({
    github: f.github, context: { repo: { owner: 'omacom', repo: 'omarchy-pkgs' }, runId: 1 },
    core: { warning() {}, setFailed() {}, setOutput() {}, summary: { addRaw: () => ({ write: async () => {} }) } },
    groups: f.groups, resultsPath: f.resultsPath, syncResult: 'success', prsResult: 'success',
  });
  assert.equal(results.length, 1);
  assert.equal(result.updates.failing, 1);
  assert.match(result.content, /Auto-merge result missing/);
});

test("a PR the rule refused or that closed fails with its reason, and an outcome without one is missing", async t => {
  const f = fixture(t, 3);
  await f.invoke();
  writeFileSync(join(f.resultsPath, 'armed.outcomes'), JSON.stringify({
    [f.groups[0].branch]: { number: f.results[0].number, outcome: 'refused', reason: 'PR is a draft' },
    [f.groups[1].branch]: { number: f.results[1].number, outcome: 'closed', reason: 'PR is closed' },
    [f.groups[2].branch]: { number: f.results[2].number },
  }));
  const result = await summarize({
    github: f.github, context: { repo: { owner: 'omacom', repo: 'omarchy-pkgs' }, runId: 1 },
    core: { warning() {}, setFailed() {}, setOutput() {}, summary: { addRaw: () => ({ write: async () => {} }) } },
    groups: f.groups, resultsPath: f.resultsPath, syncResult: 'success', prsResult: 'success',
  });
  assert.equal(result.updates.failing, 3);
  assert.match(result.content, /Auto-merge refused: PR is a draft/);
  assert.match(result.content, /PR was closed before auto-merge/);
  assert.match(result.content, /Auto-merge result missing/);
});

test("a reviewed group needs no auto-merge outcome", async t => {
  const f = fixture(t, 1);
  Object.assign(f.groups[0], { review: true });
  Object.assign(f.results[0], { review: true, merge: 'skipped' });
  const result = await f.invoke({ armed: false });
  assert.equal(result.updates.failing, 0);
});

test('a reviewed PR that could not be held as a draft is a package failure', async t => {
  const f = fixture(t, 1);
  Object.assign(f.results[0], { hold: 'failure', pr: 'skipped', merge: 'skipped' });
  const result = await f.invoke();
  assert.equal(result.updates.failing, 1);
  assert.match(result.content, /Could not turn the reviewed PR back into a draft/);
});

test('unregistered and running checks are pending, never counted as passing', async t => {
  const f = fixture(t, 3);
  f.states.set(1, null);
  f.states.set(2, 'PENDING');
  f.states.set(3, 'EXPECTED');
  const result = await f.invoke();
  assert.deepEqual(result.checks, { passing: 0, failing: 0, pending: 3, unknown: 0 });
});

test('merged PRs are counted even after their branches are deleted', async t => {
  const f = fixture(t);
  f.merged.add(1);
  const result = await f.invoke();
  assert.equal(result.checks.passing, 1);
  assert.deepEqual(f.lookup, []); // Uses the recorded number, not a surviving branch.
});

test('a merge does not turn failing or unavailable checks into passing checks', async t => {
  const f = fixture(t, 2);
  f.merged.add(1);
  f.merged.add(2);
  f.states.set(1, 'FAILURE');
  f.states.set(2, null);
  const result = await f.invoke();
  assert.deepEqual(result.checks, { passing: 0, failing: 1, pending: 0, unknown: 1 });
});

test('failure to create a new PR links to the run without inventing a PR', async t => {
  const f = fixture(t);
  Object.assign(f.results[0], { pr: 'failure', merge: 'skipped', number: '' });
  f.github.rest.pulls.list = async () => ({ data: [] });
  const result = await f.invoke();
  assert.equal(result.succeeded, true);
  assert.equal(result.updates.failing, 1);
  assert.match(result.content, /no PR link available; <a href="https:\/\/github.com\/omacom\/omarchy-pkgs\/actions\/runs\/123">view run/);
  assert.doesNotMatch(result.content, /\/pull\//);
});

test('a failed status lookup is unknown and retains the PR link', async t => {
  const f = fixture(t);
  f.states.set(1, new Error('API unavailable'));
  const result = await f.invoke();
  assert.equal(result.succeeded, true);
  assert.equal(result.checks.unknown, 1);
  assert.equal(result.checks.passing, 0);
  assert.match(result.content, /pull\/1">package-0 #1<\/a>: PR checks unavailable/);
  assert.equal(f.warnings.length, 1);
});

test('PR discovery failure does not hide the package update failure', async t => {
  const f = fixture(t);
  Object.assign(f.results[0], { pr: 'failure', merge: 'skipped', number: '' });
  f.github.rest.pulls.list = async () => { throw new Error('API unavailable'); };
  const result = await f.invoke();
  assert.equal(result.succeeded, true);
  assert.equal(result.updates.failing, 1);
  assert.equal(result.checks.unknown, 1);
  assert.match(result.content, /Could not push or update the PR; PR checks unavailable/);
});

for (const overrides of [{ syncResult: 'failure' }, { prsResult: 'failure' }, { prsResult: 'skipped' }]) {
  test(`orchestration failure remains red: ${JSON.stringify(overrides)}`, async t => {
    const f = fixture(t);
    const result = await f.invoke(overrides);
    assert.equal(result.succeeded, false);
    assert.equal(f.failures.length, 1);
    assert.match(f.outputs.content, /Upstream sync failed/);
  });
}

for (const kind of ['missing', 'duplicate', 'malformed', 'null', 'wrong package']) {
  test(`${kind} result cannot silently produce a green sync`, async t => {
    const f = fixture(t, 2);
    if (kind === 'missing') f.results.pop();
    if (kind === 'duplicate') f.results.push(f.results[1]);
    if (kind === 'malformed') writeFileSync(join(f.resultsPath, 'broken.json'), '{');
    if (kind === 'null') f.results[1] = null;
    if (kind === 'wrong package') f.results[1].packages = 'another-package';
    const result = await f.invoke();
    assert.equal(result.succeeded, false);
    assert.ok(result.updates.unknown > 0);
    assert.equal(f.failures.length, 1);
  });
}

test('a missing artifact directory is a failure when updates were expected', async t => {
  const f = fixture(t);
  const result = await f.invoke({ resultsPath: join(f.resultsPath, 'absent') });
  assert.equal(result.succeeded, false);
  assert.equal(result.updates.unknown, 1);
});

test('a no-update run succeeds quietly without spamming Basecamp while writing the job summary', async t => {
  for (const cadence of ['five-minute', 'hourly', 'six-hourly']) {
    const f = fixture(t, 0);
    const result = await f.invoke({ resultsPath: join(f.resultsPath, 'absent'), prsResult: 'skipped', cadence });
    assert.equal(result.succeeded, true);
    assert.equal(f.outputs.content, '');
    assert.equal(result.content, '');
    assert.match(f.summary, /No package updates needed/);
    assert.deepEqual(f.lookup, []);
  }
});

test('fully green PR updates (passing or pending checks) succeed quietly without spamming Basecamp', async t => {
  const f = fixture(t, 3);
  f.states.set(1, 'SUCCESS');
  f.states.set(2, 'PENDING');
  f.states.set(3, null);
  const result = await f.invoke({ cadence: 'five-minute' });
  assert.equal(result.succeeded, true);
  assert.deepEqual(result.updates, { passing: 3, unchanged: 0, failing: 0, unknown: 0 });
  assert.deepEqual(result.checks, { passing: 1, failing: 0, pending: 2, unknown: 0 });
  assert.equal(f.outputs.content, '');
  assert.equal(result.content, '');
  assert.match(f.summary, /PR updates: 3 passing, 0 failing\./);
  assert.match(f.summary, /PR checks at notification time: 1 passing, 0 failing, 2 pending\./);
});

test('a clean reviewed draft PR succeeds quietly without spamming Basecamp', async t => {
  const f = fixture(t, 1);
  Object.assign(f.groups[0], { review: true });
  Object.assign(f.results[0], { review: true, merge: 'skipped' });
  f.states.set(1, 'PENDING');
  const result = await f.invoke({ armed: false, cadence: 'six-hourly' });
  assert.equal(result.succeeded, true);
  assert.equal(f.outputs.content, '');
  assert.equal(result.content, '');
  assert.match(f.summary, /PR updates: 1 passing, 0 failing\./);
});

test('an updated PR whose link cannot be resolved still notifies Basecamp', async t => {
  const f = fixture(t, 1);
  Object.assign(f.results[0], { pr_operation: 'updated', number: '' });
  f.github.rest.pulls.list = async () => ({ data: [] });
  const result = await f.invoke({ cadence: 'hourly' });
  assert.equal(result.succeeded, true);
  assert.match(f.outputs.content, /no PR link available.*PR link unavailable/);
});

test('create-pull-request none and closed operations stay quiet in Basecamp', async t => {
  const f = fixture(t, 3);
  Object.assign(f.results[0], { pr: 'success', pr_operation: 'none', number: '' });
  Object.assign(f.results[1], { pr: 'success', pr_operation: 'none' });
  Object.assign(f.results[2], { pr: 'success', pr_operation: 'closed', merge: 'closed' });
  f.github.rest.pulls.list = async () => ({ data: [] });
  f.states.set(2, 'FAILURE');
  f.states.set(3, null);
  const result = await f.invoke({ cadence: 'six-hourly' });
  assert.equal(result.succeeded, true);
  assert.equal(result.updates.passing, 0);
  assert.equal(result.updates.unchanged, 3);
  assert.equal(result.updates.failing, 0);
  assert.equal(f.outputs.content, '');
  assert.equal(result.content, '');
  assert.match(f.summary, /PR updates: 0 passing, 3 unchanged, 0 failing\./);
});

test('a failed sync with no groups still produces a failure notification', async t => {
  const f = fixture(t, 0);
  const result = await f.invoke({ syncResult: 'failure', prsResult: 'skipped' });
  assert.equal(result.succeeded, false);
  assert.match(result.content, /Sync job: failure/);
  assert.doesNotMatch(result.content, /No package updates needed/);
});

test('notification and summary escape package names', async t => {
  const f = fixture(t);
  f.groups[0].packages = f.results[0].packages = '<unsafe & "name">';
  f.states.set(1, 'ERROR');
  await f.invoke();
  assert.doesNotMatch(f.summary, /<unsafe/);
  assert.match(f.outputs.content, /&lt;unsafe &amp; &quot;name&quot;&gt;/);
});

const upstreamWorkflow = readFileSync(join(__dirname, '../.github/workflows/sync-upstream.yml'), 'utf8');
const scopeStep = upstreamWorkflow.match(/- name: Select the package group[\s\S]*?(?=\n      # Runs in an Arch)/)[0];
const scopeScript = scopeStep.split('        run: |\n')[1].split('\n')
  .map(line => line.replace(/^          /, '')).join('\n');
const cadenceExpression = scopeStep.match(/CADENCE: \$\{\{ (.+) \}\}/)[1];
const concurrencyExpression = upstreamWorkflow.match(/  group: \$\{\{ (.+) \}\}/)[1];
const runNameExpression = upstreamWorkflow.match(/run-name: Sync upstream \(\$\{\{ (.+) \}\}\)/)[1];
// These expressions only use strings, equality, && and ||, whose semantics
// match between Actions and JavaScript for the event fixtures below.
const evaluate = (expression, github, inputs) => new Function('github', 'inputs', `return (${expression})`)(github, inputs);

const packagesExpressionMatch = scopeStep.match(/PACKAGES: \$\{\{ (.+) \}\}/);

for (const [name, event, inputs, expected] of [
  ['manual hourly run', {}, { cadence: 'hourly', packages: '' },
    { cadence: 'hourly', lane: 'auto-merge', prefix: 'auto/track-branches', concurrency: 'track-branches', closeSuperseded: 'true' }],
  ['manual five-minute run', {}, { cadence: 'five-minute', packages: '' },
    { cadence: 'five-minute', lane: 'five-minute', prefix: 'auto/sync-five-minute', concurrency: 'track-branches-five-minute', closeSuperseded: 'true' }],
  ['manual six-hourly run', {}, { cadence: 'six-hourly', packages: '' },
    { cadence: 'six-hourly', lane: 'reviewed', prefix: 'auto/sync-upstream', concurrency: 'sync-upstream', closeSuperseded: 'true' }],
  ['legacy manual run without a cadence', {}, {},
    { cadence: 'six-hourly', lane: 'reviewed', prefix: 'auto/sync-upstream', concurrency: 'sync-upstream', closeSuperseded: 'true' }],
  ['manual scoped hourly run', {}, { cadence: 'hourly', packages: 'perplexity' },
    { cadence: 'hourly', lane: 'auto-merge', prefix: 'auto/track-branches', concurrency: 'track-branches', closeSuperseded: 'false' }],
  ['manual scoped five-minute run with surrounding whitespace', {}, { cadence: 'five-minute', packages: '  omarchy-dev  ' },
    { cadence: 'five-minute', lane: 'five-minute', prefix: 'auto/sync-five-minute', concurrency: 'track-branches-five-minute', closeSuperseded: 'false' }],
  ['manual hourly run with whitespace-only packages', {}, { cadence: 'hourly', packages: '   ' },
    { cadence: 'hourly', lane: 'auto-merge', prefix: 'auto/track-branches', concurrency: 'track-branches', closeSuperseded: 'true' }],
  ['manual hourly run with carriage-return packages', {}, { cadence: 'hourly', packages: '\r' },
    { cadence: 'hourly', lane: 'auto-merge', prefix: 'auto/track-branches', concurrency: 'track-branches', closeSuperseded: 'false' }],
]) {
  test(`${name} keeps its package selection, existing PR branches and concurrency`, t => {
    const f = fixture(t, 0);
    const github = { event };
    const cadence = evaluate(cadenceExpression, github, inputs);
    assert.ok(packagesExpressionMatch, 'Select the package group must pass PACKAGES env');
    const packages = evaluate(packagesExpressionMatch[1], github, inputs) || '';
    const outputPath = join(f.resultsPath, 'scope-output');
    execFileSync('bash', ['-e', '-c', scopeScript], {
      env: { ...process.env, CADENCE: cadence, PACKAGES: packages, GITHUB_OUTPUT: outputPath },
    });
    const scope = Object.fromEntries(readFileSync(outputPath, 'utf8').trim().split('\n').map(line => line.split('=')));
    assert.deepEqual(scope, {
      cadence: expected.cadence,
      lane: expected.lane,
      prefix: expected.prefix,
      'close-superseded': expected.closeSuperseded,
    });
    assert.equal(evaluate(concurrencyExpression, github, inputs), expected.concurrency);
    assert.equal(evaluate(runNameExpression, github, inputs), expected.cadence);
  });
}

test('every package-prs.yml concurrency group owns a disjoint prefix and gates close-superseded on scoped runs', t => {
  const rebuildsWorkflow = readFileSync(join(__dirname, '../.github/workflows/sync-rebuilds.yml'), 'utf8');
  const buildPrWorkflow = readFileSync(join(__dirname, '../.github/workflows/build-pr.yml'), 'utf8');
  const cancelExpr = buildPrWorkflow.match(/^  cancel-in-progress: \$\{\{(.*)\}\}$/m)[1];
  const cancels = (repo, ref) => new Function('github', 'startsWith', `return (${cancelExpr})`)(
    { repository: 'omacom/omarchy-pkgs', head_ref: ref,
      event: { pull_request: { head: { repo: { full_name: repo } } } } },
    (text, prefix) => text.startsWith(prefix));

  // Collect every (concurrency, prefix) pair across all package-prs.yml callers.
  const lanes = [];
  for (const cadence of ['five-minute', 'hourly', 'six-hourly']) {
    const f = fixture(t, 0);
    const outputPath = join(f.resultsPath, `scope-${cadence}`);
    execFileSync('bash', ['-e', '-c', scopeScript], {
      env: { ...process.env, CADENCE: cadence, PACKAGES: '', GITHUB_OUTPUT: outputPath },
    });
    const scope = Object.fromEntries(readFileSync(outputPath, 'utf8').trim().split('\n').map(line => line.split('=')));
    lanes.push({
      name: `sync-upstream (${cadence})`,
      concurrency: evaluate(concurrencyExpression, { event: {} }, { cadence }),
      prefix: scope.prefix,
    });
  }
  const rebuildsPrefix = rebuildsWorkflow.match(/\n      prefix: (\S+)\n/)[1];
  const rebuildsConcurrency = rebuildsWorkflow.match(/\n  group: (\S+)\n/)[1];
  lanes.push({ name: 'sync-rebuilds', concurrency: rebuildsConcurrency, prefix: rebuildsPrefix });

  // No two concurrency groups may share or overlap a branch prefix under
  // close-superseded's `headRefName == PREFIX || startswith(PREFIX + "-")` rule.
  for (let i = 0; i < lanes.length; i++) {
    assert.equal(cancels('omacom/omarchy-pkgs', `${lanes[i].prefix}-sample`), false,
      `${lanes[i].name} prefix ${lanes[i].prefix} must be exempt from build-pr cancellation`);
    for (let j = i + 1; j < lanes.length; j++) {
      const a = lanes[i];
      const b = lanes[j];
      assert.notEqual(a.concurrency, b.concurrency, `${a.name} and ${b.name} concurrency`);
      assert.equal(a.prefix === b.prefix || a.prefix.startsWith(`${b.prefix}-`) || b.prefix.startsWith(`${a.prefix}-`), false,
        `${a.name} (${a.prefix}) overlaps ${b.name} (${b.prefix})`);
    }
  }

  // Both sync-upstream.yml and sync-rebuilds.yml wire close-superseded to package-prs.yml
  // and skip package-prs.yml when a scoped run produces no updates.
  for (const [file, wf] of [['sync-upstream.yml', upstreamWorkflow], ['sync-rebuilds.yml', rebuildsWorkflow]]) {
    assert.match(wf, /\n      close-superseded: \$\{\{ needs\.sync\.outputs\.close-superseded == 'true' \}\}\n/, file);
    const prsIf = wf.match(/\n  prs:\n    needs: sync\n    if: \$\{\{ (.+) \}\}\n/);
    assert.ok(prsIf, `${file} must have prs job if expression`);
    const jsExpr = prsIf[1].replace(/\.([a-z]+-[a-z-]+)/g, "['$1']");
    const evalPrsIf = (groups, closeSuperseded) => new Function('cancelled', 'needs', `return (${jsExpr})`)(
      () => false,
      { sync: { outputs: { groups, 'close-superseded': closeSuperseded } } },
    );
    assert.equal(evalPrsIf('', 'true'), false, `${file}: empty groups must skip prs`);
    assert.equal(evalPrsIf('[]', 'true'), true, `${file}: unscoped no-op run still runs close-superseded`);
    assert.equal(evalPrsIf('[]', 'false'), false, `${file}: scoped no-op run skips prs entirely`);
    assert.equal(evalPrsIf('[{"branch":"x","packages":"a"}]', 'false'), true, `${file}: scoped run with updates runs prs`);
  }

  // Verify sync-rebuilds.yml Group the bumps into PRs step outputs close-superseded accurately.
  const rebuildsGroupStep = rebuildsWorkflow.match(/- name: Group the bumps into PRs[\s\S]*?(?=\n      - name: Hand the bumps)/)[0];
  assert.match(rebuildsGroupStep, /PACKAGES: \$\{\{ inputs\.packages \}\}/);
  const rebuildsGroupScript = rebuildsGroupStep.split('        run: |\n')[1].split('\n')
    .map(line => line.replace(/^          /, '')).join('\n')
    .replace('groups=$(.github/scripts/package-pr-groups.sh auto/sync-rebuilds "$RUNNER_TEMP/pins.patch")', 'groups="[]"');
  for (const [pkgs, expectedClose] of [['', 'true'], ['   ', 'true'], ['\t', 'true'], ['\r', 'false'], ['walker', 'false'], [' a b ', 'false']]) {
    const f = fixture(t, 0);
    const out = join(f.resultsPath, 'rebuilds-out');
    execFileSync('bash', ['-e', '-c', rebuildsGroupScript], {
      env: { ...process.env, PACKAGES: pkgs, GITHUB_OUTPUT: out },
    });
    const parsed = Object.fromEntries(readFileSync(out, 'utf8').trim().split('\n').map(line => line.split('=')));
    assert.equal(parsed['close-superseded'], expectedClose, `sync-rebuilds PACKAGES=${JSON.stringify(pkgs)}`);
  }
});

test('invalid cadence fails before selecting packages or PR branches', t => {
  const f = fixture(t, 0);
  const outputPath = join(f.resultsPath, 'scope-output');
  const result = spawnSync('bash', ['-e', '-c', scopeScript], {
    env: { ...process.env, CADENCE: 'unexpected', GITHUB_OUTPUT: outputPath }, encoding: 'utf8',
  });
  assert.notEqual(result.status, 0);
  assert.match(result.stdout, /Unknown update cadence/);
  assert.equal(existsSync(outputPath), false);
});

test('the controller box dispatches every cadence and GitHub schedules none', () => {
  assert.doesNotMatch(upstreamWorkflow, /^\s*schedule:/m);
  const dispatch = readFileSync(join(__dirname, '../ci/dispatch.sh'), 'utf8');
  assert.deepEqual([...dispatch.matchAll(/workflow=sync-upstream\.yml +inputs='\{"cadence":"([^"]+)"\}'/g)]
    .map(match => match[1]).sort(), ['five-minute', 'hourly', 'six-hourly']);
  assert.equal(existsSync(join(__dirname, '../.github/workflows/track-branches.yml')), false);
});

test('an hourly package failure gets the same successful-sync notification and PR link', async t => {
  const f = fixture(t);
  f.results[0].pr = 'failure';
  const result = await f.invoke({ cadence: 'hourly' });
  assert.equal(result.succeeded, true);
  assert.match(result.content, /Package group: hourly/);
  assert.match(result.content, /PR updates: 0 passing, 1 failing/);
  assert.match(result.content, /pull\/1/);
});

test('an hourly feed-fetch failure still reports the three successful PR updates', async t => {
  const f = fixture(t, 3);
  const result = await f.invoke({ cadence: 'hourly', syncResult: 'failure' });
  assert.equal(result.succeeded, false);
  assert.match(result.content, /Package group: hourly/);
  assert.match(result.content, /PR updates: 3 passing, 0 failing/);
  assert.match(result.content, /Sync job: failure/);
  assert.match(result.content, /actions\/runs\/123/);
});

test('all-unchanged open PRs succeed quietly without spamming Basecamp while writing the job summary', async t => {
  const f = fixture(t, 2);
  f.results[0].pr = 'unchanged';
  f.results[1].pr = 'unchanged';
  f.states.set(1, 'FAILURE');
  f.states.set(2, 'FAILURE');
  const report = await f.invoke({ armed: true, cadence: 'six-hourly' });
  assert.equal(report.succeeded, true);
  assert.equal(report.updates.passing, 0);
  assert.equal(report.updates.unchanged, 2);
  assert.equal(report.updates.failing, 0);
  assert.equal(report.checks.failing, 2);
  assert.equal(f.outputs.content, '');
  assert.equal(report.content, '');
  assert.match(f.summary, /PR updates: 0 passing, 2 unchanged, 0 failing\./);
  assert.match(f.summary, /<td>Unchanged<\/td><td>failing<\/td>/);
});

test('mixed clean passing update and unchanged failing PR stays quiet in Basecamp while recording counts in summary', async t => {
  const f = fixture(t, 2);
  f.results[1].pr = 'unchanged';
  f.states.set(1, 'PENDING');
  f.states.set(2, 'FAILURE');
  const report = await f.invoke({ cadence: 'six-hourly' });
  assert.equal(report.succeeded, true);
  assert.equal(report.updates.passing, 1);
  assert.equal(report.updates.unchanged, 1);
  assert.equal(f.outputs.content, '');
  assert.equal(report.content, '');
  assert.match(f.summary, /PR updates: 1 passing, 1 unchanged, 0 failing\./);
});

test('mixed failing new PR check and unchanged PR notifies Basecamp with separate counts', async t => {
  const { results, states, outputs, invoke } = fixture(t, 2);
  results[1].pr = 'unchanged';
  states.set(1, 'FAILURE');
  states.set(2, 'FAILURE');
  const report = await invoke({ cadence: 'six-hourly' });
  assert.equal(report.succeeded, true);
  assert.equal(report.updates.passing, 1);
  assert.equal(report.updates.unchanged, 1);
  assert.match(outputs.content, /PR updates: 1 passing, 1 unchanged, 0 failing\./);
  assert.match(outputs.content, /pull\/1">package-0 #1<\/a>: PR checks failing/);
  assert.doesNotMatch(outputs.content, /pull\/2">package-1 #2<\/a>/);
});

test('unchanged PR with refused auto-merge still reports failure to Basecamp', async t => {
  const f = fixture(t, 1);
  f.results[0].pr = 'unchanged';
  f.results[0].merge = 'refused';
  const report = await f.invoke({ cadence: 'six-hourly' });
  assert.equal(report.updates.failing, 1);
  assert.equal(report.updates.unchanged, 0);
  assert.match(f.outputs.content, /Auto-merge refused/);
});
