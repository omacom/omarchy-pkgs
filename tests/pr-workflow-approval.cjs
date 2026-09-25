const assert = require('node:assert/strict');
const { readFileSync, mkdtempSync, rmSync } = require('node:fs');
const { join } = require('node:path');
const { tmpdir } = require('node:os');
const { test } = require('node:test');
const { execFileSync, spawnSync } = require('node:child_process');
const approve = require('../.github/scripts/approve-pr-workflows.cjs');

const BUILD = '.github/workflows/build-pr.yml';
const TESTS = '.github/workflows/test.yml';
const time = '2026-09-19T02:47:52Z';
const earlier = '2026-09-19T02:36:04Z';
const pr = {
  number: 390, state: 'open', updated_at: time,
  head: { sha: 'reviewed-sha', ref: 'ghost', repo: { id: 42 } },
  labels: [{ name: 'build-approved' }],
};
const clone = value => structuredClone(value);
const run = (id, path, overrides = {}) => ({
  id, path, event: 'pull_request', head_sha: pr.head.sha,
  head_repository: { id: 42 }, head_branch: 'ghost', pull_requests: [],
  status: 'completed', conclusion: 'action_required', created_at: time,
  ...overrides,
});

function fixture(initial = [run(1, TESTS, { created_at: earlier }), run(2, BUILD)], options = {}) {
  const state = { pr: clone(pr), runs: clone(initial), approved: [], reads: 0, tick: 0, transitions: [] };
  const repo = { owner: 'omacom', repo: 'omarchy-pkgs' };
  const github = {
    rest: {
      pulls: { get: async args => {
        assert.deepEqual(args, { ...repo, pull_number: 390 });
        state.reads++;
        options.onRead?.(state);
        return { data: clone(state.pr) };
      } },
      actions: {
        listWorkflowRunsForRepo() {},
        getWorkflowRun: async ({ run_id }) => {
          const current = state.runs.find(run => run.id === run_id);
          state.transitions.push([run_id, current.status]);
          return { data: clone(current) };
        },
        approveWorkflowRun: async args => {
          assert.deepEqual(args, { ...repo, run_id: args.run_id });
          options.onApprove?.(state, args.run_id);
          const current = state.runs.find(run => run.id === args.run_id);
          assert.equal(current.conclusion, 'action_required');
          state.approved.push(current.id);
          current.status = 'queued';
          current.conclusion = null;
        },
      },
    },
    paginate: async (method, args) => {
      assert.equal(method, github.rest.actions.listWorkflowRunsForRepo);
      assert.deepEqual(args, { ...repo, event: 'pull_request', head_sha: pr.head.sha, per_page: 100 });
      return clone(state.runs).reverse(); // GitHub returns newest first.
    },
  };
  const invoke = overrides => approve({
    github, context: { repo, payload: { action: 'labeled', pull_request: clone(pr) } },
    core: { info() {} }, vouchStatus: 'unknown', attempts: 6,
    sleep: async () => {
      state.tick++;
      for (const current of state.runs) {
        if (current.status === 'queued' && state.tick >= (options.queueUntil ?? 1)) current.status = 'in_progress';
      }
      options.onSleep?.(state);
    },
    ...overrides,
  });
  return { state, invoke, github };
}

test('an unvouched, labeled fork PR releases both required workflows', async () => {
  const { state, invoke } = fixture();
  await invoke();
  assert.deepEqual(state.approved, [1, 2]);
});

test('waits for the label-triggered build instead of stopping at the old build', async () => {
  const { state, invoke } = fixture([
    run(1, BUILD, { created_at: earlier }), run(2, TESTS, { created_at: earlier }),
  ], {
    onSleep(state) {
      if (state.tick === 2) {
        assert.deepEqual(state.approved, []);
        state.runs.push(run(3, BUILD));
      }
    },
    queueUntil: 4,
    onApprove(state, id) {
      if (id === 3) assert.equal(state.runs.find(run => run.id === 1).status, 'in_progress');
    },
  });
  await invoke({ attempts: 10 });
  assert.deepEqual(state.approved, [1, 2, 3]);
  assert.ok(state.transitions.some(([id, status]) => id === 1 && status === 'queued'));
});

test('approves only the two known workflows for this fork, branch, PR and SHA', async () => {
  const unrelated = [
    { path: '.github/workflows/publish.yml' }, { event: 'push' },
    { head_sha: 'other-sha' }, { head_repository: { id: 99 } },
    { head_branch: 'other-branch' }, { pull_requests: [{ number: 391 }] },
  ].map((overrides, i) => run(10 + i, BUILD, overrides));
  const { state, invoke } = fixture([run(1, TESTS), run(2, BUILD), ...unrelated]);
  await invoke();
  assert.deepEqual(state.approved, [1, 2]);
});

test('accepts a run explicitly associated with this PR', async () => {
  const { state, invoke } = fixture([
    run(1, TESTS), run(2, BUILD, { pull_requests: [{ number: 390 }] }),
  ]);
  await invoke();
  assert.deepEqual(state.approved, [1, 2]);
});

test('does not restart running or completed workflows', async () => {
  const { state, invoke } = fixture([
    run(1, TESTS, { conclusion: 'success' }),
    run(2, BUILD, { status: 'in_progress', conclusion: null }),
  ]);
  await invoke();
  assert.deepEqual(state.approved, []);
});

test('an obsolete build hold cannot cancel a newer build that was already released', async () => {
  for (const current of [
    { status: 'queued', conclusion: null }, { status: 'in_progress', conclusion: null },
    { status: 'completed', conclusion: 'success' }, { status: 'completed', conclusion: 'failure' },
  ]) {
    const { state, invoke } = fixture([
      run(1, BUILD, { created_at: earlier }), run(2, TESTS), run(3, BUILD, current),
    ]);
    await invoke();
    assert.deepEqual(state.approved, [2]);
  }
});

for (const status of ['denounced', '', undefined, 'unexpected']) {
  test(`vouch status ${String(status)} fails closed`, async () => {
    const { state, invoke } = fixture();
    await assert.rejects(invoke({ vouchStatus: status }), /Cannot approve workflows/);
    assert.deepEqual(state.approved, []);
  });
}

for (const status of ['bot', 'collaborator', 'vouched']) {
  test(`a labeled ${status} can also clear GitHub's approval gate`, async () => {
    const { state, invoke } = fixture();
    await invoke({ vouchStatus: status });
    assert.deepEqual(state.approved, [1, 2]);
  });
}

for (const [name, change] of [
  ['removed label', pr => { pr.labels = []; }],
  ['changed head', pr => { pr.head.sha = 'new-sha'; }],
  ['closed PR', pr => { pr.state = 'closed'; }],
]) {
  test(`${name} stops approval, including changes immediately before a write`, async () => {
    for (const read of [1, 2]) {
      const { state, invoke } = fixture(undefined, { onRead(state) {
        if (state.reads === read) change(state.pr);
      } });
      await invoke();
      assert.deepEqual(state.approved, []);
    }
  });
}

test('revocation between approvals prevents releasing further workflows', async () => {
  const { state, invoke } = fixture(undefined, { onSleep(state) { state.pr.labels = []; } });
  await invoke();
  assert.deepEqual(state.approved, [1]);
});

test('a delayed tests workflow is also awaited', async () => {
  const { state, invoke } = fixture([run(2, BUILD)], {
    onSleep(state) { if (state.tick === 2) state.runs.push(run(1, TESTS)); },
  });
  await invoke();
  assert.deepEqual(state.approved, [1, 2]);
});

test('reopening a labeled PR waits for its new tests, even if old tests passed at the same SHA', async () => {
  const { state, invoke } = fixture([
    run(1, TESTS, { created_at: earlier, conclusion: 'success' }), run(2, BUILD),
  ], { onSleep(state) { if (state.tick === 2) state.runs.push(run(3, TESTS)); } });
  await invoke({ context: { repo: { owner: 'omacom', repo: 'omarchy-pkgs' },
    payload: { action: 'reopened', pull_request: clone(pr) } } });
  assert.deepEqual(state.approved, [2, 3]);
});

test('missing current runs time out without approving stale builds', async () => {
  const { state, invoke } = fixture([run(1, TESTS), run(2, BUILD, { created_at: earlier })]);
  await assert.rejects(invoke(), /Timed out/);
  assert.deepEqual(state.approved, []);
});

test('API failure is reported rather than silently treated as approval', async () => {
  const { state, invoke } = fixture(undefined, { onApprove() { throw new Error('Forbidden'); } });
  await assert.rejects(invoke(), /Forbidden/);
  assert.deepEqual(state.approved, []);
});

// Execute the actual build workflow's approval script and shell gate. This
// covers the stale event payload that originally accompanied held PR runs.
const workflow = readFileSync(join(__dirname, '../.github/workflows/build-pr.yml'), 'utf8');
const approvalScript = workflow.match(/- id: approval[\s\S]*?script: \|\n([\s\S]*?)(?=      # One matrix)/)[1]
  .split('\n').map(line => line.replace(/^            /, '')).join('\n');
const gateScript = workflow.match(/          case "\$STATUS" in[\s\S]*?          esac/)[0] + '\nprintf "%s" "$trusted"';

test('the build reads the live label rather than its pre-label event payload', async () => {
  const execute = new (Object.getPrototypeOf(async function () {}).constructor)('github', 'context', 'core', approvalScript);
  for (const [current, approved] of [
    [pr, true], [{ ...pr, labels: [] }, false],
    [{ ...pr, head: { ...pr.head, sha: 'new-sha' } }, false],
    [{ ...pr, state: 'closed' }, false],
  ]) {
    const outputs = {};
    await execute({ rest: { pulls: { get: async () => ({ data: current }) } } },
      { repo: {}, payload: { pull_request: { ...pr, labels: [] } } },
      { setOutput: (key, value) => { outputs[key] = value; } });
    assert.equal(outputs.approved, approved);
  }
});

test('the build gate permits a missing vouch only with approval, never a denouncement or lookup failure', () => {
  for (const [status, approved, expected] of [
    ['unknown', 'true', 'true'], ['unknown', 'false', 'false'],
    ['denounced', 'true', 'false'], ['', 'true', 'false'], ['unexpected', 'true', 'false'],
    ['vouched', 'false', 'true'], ['collaborator', 'false', 'true'],
    ['bot', 'false', 'true'], ['dispatch', 'false', 'true'],
  ]) {
    assert.equal(execFileSync('bash', ['-c', gateScript], {
      env: { ...process.env, STATUS: status, APPROVED: approved }, encoding: 'utf8',
    }), expected);
  }
});

// Exercise the actual reporting job, including its GitHub check name: a
// successful/skipped check called "result" would accidentally allow merging
// a PR whose build never ran. GitHub keeps a missing required check pending.
const resultJob = workflow.slice(workflow.indexOf('\n  result:\n'));
const resultName = resultJob.match(/^    name: (.+)$/m)[1];
const resultScript = resultJob.split('      - run: |\n')[1];
function report({ trusted = 'false', vouch = 'unknown', empty = 'false', changes = 'success', build = 'skipped' } = {}) {
  const needs = {
    changes: { result: changes, outputs: { trusted, vouch_status: vouch, empty } },
    build: { result: build },
  };
  // The reporting expressions use &&, || and string equality, with the
  // same semantics in JavaScript and Actions for these string-only fixtures.
  const render = text => text.replace(/\$\{\{(.*?)\}\}/g, (_, expression) =>
    new Function('needs', `return (${expression})`)(needs));
  const directory = mkdtempSync(join(tmpdir(), 'build-approval-report-'));
  const summaryPath = join(directory, 'summary');
  try {
    const result = spawnSync('bash', ['-e', '-c', render(resultScript)], {
      env: { ...process.env, GITHUB_STEP_SUMMARY: summaryPath }, encoding: 'utf8',
    });
    return { name: render(resultName), ...result,
      summary: result.stdout.includes('::notice::') ? readFileSync(summaryPath, 'utf8') : '' };
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
}

test('an unvouched PR waits without publishing a passing or failing required result', () => {
  const result = report();
  assert.equal(result.name, 'Awaiting build approval');
  assert.equal(result.status, 0);
  assert.match(result.stdout, /::notice::Awaiting maintainer build approval/);
  assert.doesNotMatch(result.stdout, /::error::/);
  assert.match(result.summary, /required \*\*result\*\* check remains pending/);
});

test('applying build-approved transitions the waiting PR to the required build result', () => {
  assert.notEqual(report().name, 'result');
  const approved = report({ trusted: 'true', build: 'success' });
  assert.equal(approved.name, 'result');
  assert.equal(approved.status, 0);
  const failed = report({ trusted: 'true', build: 'failure' });
  assert.equal(failed.name, 'result');
  assert.notEqual(failed.status, 0);
});

test('trusted tooling-only PRs still satisfy the required result without a package build', () => {
  const result = report({ trusted: 'true', vouch: 'vouched' });
  assert.equal(result.name, 'result');
  assert.equal(result.status, 0);
});

for (const [name, overrides] of [
  ['denounced author', { vouch: 'denounced' }],
  ['failed trust lookup', { vouch: '', changes: 'failure' }],
  ['missing trust result', { vouch: '' }],
  ['missing gate output', { trusted: '' }],
  ['failed planning', { changes: 'failure' }],
  ['cancelled planning', { changes: 'cancelled' }],
  ['empty PR', { empty: 'true' }],
  ['cancelled build', { trusted: 'true', build: 'cancelled' }],
]) {
  test(`${name} fails the required result instead of masquerading as pending approval`, () => {
    const result = report(overrides);
    assert.equal(result.name, 'result');
    assert.notEqual(result.status, 0);
    assert.doesNotMatch(result.stdout, /::notice::Awaiting maintainer build approval/);
  });
}
