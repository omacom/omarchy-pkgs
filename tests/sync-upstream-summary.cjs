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
  const invoke = (overrides = {}) => {
    results.forEach((result, i) => writeFileSync(join(resultsPath, `${i}.json`), JSON.stringify(result)));
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
  assert.deepEqual(result.updates, { passing: 6, failing: 1, unknown: 0 });
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
    merge: { outcome: 'skipped', conclusion: 'skipped' },
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
  assert.deepEqual(record, { ...f.groups[0], apply: 'success', pr: 'failure', merge: 'skipped', number: '' });
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

test('a no-update run succeeds without package artifacts or PR jobs', async t => {
  const f = fixture(t, 0);
  const result = await f.invoke({ resultsPath: join(f.resultsPath, 'absent'), prsResult: 'skipped' });
  assert.equal(result.succeeded, true);
  assert.match(result.content, /No package updates needed/);
  assert.deepEqual(f.lookup, []);
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

for (const [name, event, inputs, expected] of [
  ['manual hourly run', {}, { cadence: 'hourly' },
    { cadence: 'hourly', lane: 'auto-merge', prefix: 'auto/track-branches', concurrency: 'track-branches' }],
  ['manual six-hourly run', {}, { cadence: 'six-hourly' },
    { cadence: 'six-hourly', lane: 'reviewed', prefix: 'auto/sync-upstream', concurrency: 'sync-upstream' }],
  ['legacy manual run without a cadence', {}, {},
    { cadence: 'six-hourly', lane: 'reviewed', prefix: 'auto/sync-upstream', concurrency: 'sync-upstream' }],
]) {
  test(`${name} keeps its package selection, existing PR branches and concurrency`, t => {
    const f = fixture(t, 0);
    const github = { event };
    const cadence = evaluate(cadenceExpression, github, inputs);
    const outputPath = join(f.resultsPath, 'scope-output');
    execFileSync('bash', ['-e', '-c', scopeScript], {
      env: { ...process.env, CADENCE: cadence, GITHUB_OUTPUT: outputPath },
    });
    const scope = Object.fromEntries(readFileSync(outputPath, 'utf8').trim().split('\n').map(line => line.split('=')));
    assert.deepEqual(scope, { cadence: expected.cadence, lane: expected.lane, prefix: expected.prefix });
    assert.equal(evaluate(concurrencyExpression, github, inputs), expected.concurrency);
    assert.equal(evaluate(runNameExpression, github, inputs), expected.cadence);
  });
}

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

test('the controller box dispatches both cadences and GitHub schedules neither', () => {
  assert.doesNotMatch(upstreamWorkflow, /^\s*schedule:/m);
  const dispatch = readFileSync(join(__dirname, '../ci/dispatch.sh'), 'utf8');
  assert.deepEqual([...dispatch.matchAll(/workflow=sync-upstream\.yml +inputs='\{"cadence":"([^"]+)"\}'/g)]
    .map(match => match[1]).sort(), ['hourly', 'six-hourly']);
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
