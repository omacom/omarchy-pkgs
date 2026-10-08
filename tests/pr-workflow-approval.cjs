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

test('a lone build left pending behind an older in-flight build does not hold back the tests', async () => {
  // Sync branches queue rather than cancel, so an approved build can stay
  // queued for hours. Only a newer held build needs to wait for it to start.
  const { state, invoke } = fixture([run(1, BUILD), run(2, TESTS)], { queueUntil: Infinity });
  await invoke();
  assert.deepEqual(state.approved, [1, 2]);
  assert.deepEqual(state.transitions, []);
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

// A push to a sync branch must not cancel that PR's multi-hour build; any
// other PR still cancels its superseded build.
test('only same-repository sync branches queue behind an in-flight build', () => {
  const expression = workflow.match(/^  cancel-in-progress: \$\{\{(.*)\}\}$/m)[1];
  const cancels = (repo, ref) => new Function('github', 'startsWith', `return (${expression})`)(
    { repository: 'omacom/omarchy-pkgs', head_ref: ref,
      event: { pull_request: { head: { repo: { full_name: repo } } } } },
    (text, prefix) => text.startsWith(prefix));
  assert.equal(cancels('omacom/omarchy-pkgs', 'auto/sync-upstream'), false);
  assert.equal(cancels('omacom/omarchy-pkgs', 'auto/sync-upstream-ttfx'), false);
  assert.equal(cancels('omacom/omarchy-pkgs', 'auto/sync-rebuilds'), false);
  assert.equal(cancels('omacom/omarchy-pkgs', 'ttfx/fix'), true);
  assert.equal(cancels('someone/omarchy-pkgs', 'auto/sync-upstream'), true);
  assert.equal(cancels(undefined, ''), true); // workflow_dispatch
});

// The sync workflows release their own GITHUB_TOKEN pushes: GitHub creates
// no pull_request_target run for those, so approve-pr.yml never runs.
const approveSyncPush = require('../.github/scripts/approve-sync-push.cjs');
function syncFixture(options = {}) {
  const f = fixture([run(1, BUILD, { head_branch: 'auto/sync-upstream' }),
    run(2, TESTS, { head_branch: 'auto/sync-upstream' })], options);
  Object.assign(f.state.pr, {
    user: { login: 'github-actions[bot]' },
    head: { ...f.state.pr.head, ref: 'auto/sync-upstream', repo: { id: 42, full_name: 'omacom/omarchy-pkgs' } },
    base: { repo: { full_name: 'omacom/omarchy-pkgs' } },
  });
  const push = overrides => approveSyncPush({
    github: f.github, context: { repo: { owner: 'omacom', repo: 'omarchy-pkgs' }, payload: {} },
    core: { info() {} }, number: 390, branch: 'auto/sync-upstream', headSha: pr.head.sha,
    since: earlier, attempts: 6, sleep: async () => {}, ...overrides,
  });
  return { ...f, push };
}

test('a labelled sync PR has its bot push released', async () => {
  const { state, push } = syncFixture();
  await push();
  assert.deepEqual(state.approved, [1, 2]);
});

test('a sync PR whose label a maintainer removed stays held', async () => {
  const { state, push } = syncFixture();
  state.pr.labels = [];
  await push();
  assert.deepEqual(state.approved, []);
});

test('runs older than the push are not taken for this push', async () => {
  const { state, push } = syncFixture();
  await assert.rejects(push({ since: '2026-09-19T03:00:00Z' }), /Timed out/);
  assert.deepEqual(state.approved, []);
});

for (const [name, change] of [
  ['a contributor PR', current => { current.user.login = 'someone'; }],
  ['a fork PR', current => { current.head.repo.full_name = 'someone/omarchy-pkgs'; }],
  ['another branch', current => { current.head.ref = 'auto/sync-rebuilds'; }],
]) {
  test(`the sync approver refuses ${name}, even when labelled`, async () => {
    const { state, push } = syncFixture();
    change(state.pr);
    await assert.rejects(push(), /refusing to approve/);
    assert.deepEqual(state.approved, []);
  });
}

for (const [name, change] of [
  ['closed', current => { current.state = 'closed'; }],
  ['moved on', current => { current.head.sha = 'newer-sha'; }],
]) {
  test(`a sync PR that has ${name} is left alone`, async () => {
    const { state, push } = syncFixture();
    change(state.pr);
    await push();
    assert.deepEqual(state.approved, []);
  });
}

test('the sync approver needs the push it is approving for', async () => {
  const { state, push } = syncFixture();
  for (const missing of [{ number: NaN }, { headSha: '' }, { since: '' }, { branch: '' }]) {
    await assert.rejects(push(missing), /Missing sync PR/);
  }
  assert.deepEqual(state.approved, []);
});

// A scoped dispatch must not push to the shared branch: it would replace the
// other pending updates in the open sync PR with just the named packages.
const branchScript = join(__dirname, '../.github/scripts/sync-pr-branch.sh');
const branchFor = (...names) => Object.fromEntries(execFileSync(branchScript,
  ['auto/sync-upstream', ...names], { encoding: 'utf8' })
  .trim().split('\n').map(line => line.split(/=(.*)/s).slice(0, 2)));

test('scheduled runs keep the shared branch; scoped runs get their own', () => {
  assert.deepEqual(branchFor(), { branch: 'auto/sync-upstream', scope: '' });
  assert.deepEqual(branchFor('ttfx'), { branch: 'auto/sync-upstream-ttfx', scope: 'ttfx' });
  assert.deepEqual(branchFor('ttfx', 'strata', 'ttfx'),
    { branch: 'auto/sync-upstream-strata-ttfx', scope: 'strata ttfx' });
  assert.equal(branchFor('python-foo.bar').branch, 'auto/sync-upstream-python-foo-bar');
  const names = ['a-very-long-package-name-one', 'another-very-long-package-name-two'];
  const long = branchFor(...names, 'third');
  assert.ok(long.branch.length <= 'auto/sync-upstream-'.length + 60);
  assert.notEqual(long.branch, branchFor(...names).branch);
});

test('scoped branch names reject anything that is not a package name', () => {
  for (const name of ['../x', 'A', 'x y', 'a@{b', '-x', '.x', 'x;true']) {
    assert.equal(spawnSync(branchScript, ['auto/sync-upstream', name]).status, 1, name);
  }
});

test('sync workflows push scoped runs aside and keep actions: write out of the sync job', () => {
  for (const file of ['sync-upstream.yml']) {
    const text = readFileSync(join(__dirname, '../.github/workflows', file), 'utf8');
    const sync = text.slice(text.indexOf('\n  sync:\n'), text.indexOf('\n  approve:\n'));
    const approveJob = text.slice(text.indexOf('\n  approve:\n'));
    assert.match(sync, /sync-pr-branch\.sh auto\/sync-[\w-]+ "\$\{package_args\[@\]\}"/, file);
    assert.match(sync, /branch: \$\{\{ steps\.branch\.outputs\.branch \}\}/, file);
    assert.doesNotMatch(sync, /^ +actions: write$/m, file);
    assert.match(approveJob, /^      actions: write$/m, file);
    // The sync PR is bot-authored and trusted: it labels itself so its own
    // pushes build, including the push that opens the PR.
    assert.match(sync, /labels: \|\n +automated\n +build-approved\n/, file);
    assert.match(approveJob, /needs\.sync\.outputs\.operation == 'created'/, file);
    assert.match(approveJob, /needs\.sync\.outputs\.operation == 'updated'/, file);
  }
});

test('rebuild sync opens its PR with the bot token and auto-merges it', () => {
  const file = 'sync-rebuilds.yml';
  const text = readFileSync(join(__dirname, '../.github/workflows', file), 'utf8');
  assert.match(text, /sync-pr-branch\.sh auto\/sync-rebuilds "\$\{package_args\[@\]\}"/, file);
  assert.match(text, /branch: \$\{\{ steps\.branch\.outputs\.branch \}\}/, file);
  // A GITHUB_TOKEN merge would not start publish.yml, so the PR and the
  // merge both go through the PAT.
  assert.match(text, /token: \$\{\{ secrets\.PKGS_BOT_TOKEN \}\}/, file);
  assert.doesNotMatch(text, /secrets\.GITHUB_TOKEN/, file);
  assert.match(text, /gh pr merge --auto --merge "\$PR"/, file);
  assert.doesNotMatch(text, /^ +actions: write$/m, file);
  assert.doesNotMatch(text, /\n  approve:\n/, file);
});
