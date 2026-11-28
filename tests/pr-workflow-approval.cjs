const assert = require('node:assert/strict');
const { readFileSync, writeFileSync, mkdirSync, mkdtempSync, rmSync } = require('node:fs');
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
const approvalScript = workflow.match(/- id: approval[\s\S]*?script: \|\n([\s\S]*?)(?=      - id: gate)/)[1]
  .split('\n').map(line => line.replace(/^            /, '')).join('\n');
const gateScript = workflow.match(/          case "\$STATUS" in[\s\S]*?          esac/)[0] + '\nprintf "%s" "$trusted"';

function parseWorkflowJobs(text) {
  const jobs = new Map();
  let current = null;
  for (const line of text.slice(text.indexOf("\njobs:\n") + 7).split("\n")) {
    if (line && !line.startsWith(" ") && !line.startsWith("#")) break;
    const header = line.match(/^  ([A-Za-z0-9_-]+):\s*$/);
    if (header) {
      current = { name: header[1], lines: [] };
      jobs.set(current.name, current);
    } else if (current && !/^\s*#/.test(line)) {
      current.lines.push(line);
    }
  }
  return new Map([...jobs].map(([name, { lines }]) => {
    const body = lines.join("\n");
    const needs = [];
    for (let i = 0; i < lines.length; i++) {
      const m = lines[i].match(/^    needs:\s*(.*)$/);
      if (!m) continue;
      const v = m[1].trim();
      if (v.startsWith("[")) needs.push(...v.slice(1, -1).split(",").map(s => s.trim()).filter(Boolean));
      else if (v) needs.push(v);
      else while (lines[i + 1]?.match(/^      -\s*(\S+)/)) needs.push(lines[++i].match(/^      -\s*(\S+)/)[1]);
    }
    const condition = body.match(/^    if:\s*(.+)$/m)?.[1].trim() ?? "";
    return [name, { name, body, needs, condition }];
  }));
}

test('build-pr.yml runs gate before planning and package build jobs', () => {
  const jobs = parseWorkflowJobs(workflow);
  const gate = jobs.get('gate');
  const changes = jobs.get('changes');
  const build = jobs.get('build');
  const result = jobs.get('result');

  assert.ok(gate && changes && build && result);
  const checkoutOrPlan = /actions\/checkout|git\s+(?:fetch|checkout)\b|pkgbuilds\/|bin\/build-matrix|bin\/build\b/;
  assert.doesNotMatch(gate.body, checkoutOrPlan);
  assert.deepEqual(changes.needs, ['gate']);
  assert.equal(changes.condition, "needs.gate.outputs.trusted == 'true'");
  assert.deepEqual(build.needs, ['changes']);
  assert.equal(build.condition, "needs.changes.outputs.count != '0'");
  assert.deepEqual([...result.needs].sort(), ['build', 'changes', 'gate']);
  assert.equal(result.condition, 'always()');

  const behindGate = (name, seen = new Set()) => {
    const job = !seen.has(name) && jobs.get(name);
    if (!job || /\b(?:always|failure|cancelled)\s*\(/.test(job.condition)) return false;
    seen.add(name);
    return name === 'changes' || job.needs.some(dep => behindGate(dep, seen));
  };
  for (const job of jobs.values()) {
    if (checkoutOrPlan.test(job.body)) {
      assert.ok(behindGate(job.name), `${job.name} must run behind gate`);
    }
  }
});

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
function report({
  trusted = 'false',
  vouch = 'unknown',
  empty = 'false',
  gate = 'success',
  changes = gate === 'success' && trusted === 'true' ? 'success' : 'skipped',
  build = 'skipped',
} = {}) {
  const needs = {
    gate: { result: gate, outputs: { trusted, vouch_status: vouch } },
    changes: { result: changes, outputs: { empty } },
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
  const dispatch = report({ trusted: 'true', vouch: '', build: 'success' });
  assert.equal(dispatch.name, 'result');
  assert.equal(dispatch.status, 0);
});

for (const [name, overrides] of [
  ['denounced author', { vouch: 'denounced' }],
  ['failed trust lookup', { vouch: '', gate: 'failure' }],
  ['cancelled trust lookup', { vouch: '', gate: 'cancelled' }],
  ['missing trust result', { vouch: '' }],
  ['missing gate output', { trusted: '' }],
  ['failed planning', { trusted: 'true', changes: 'failure' }],
  ['cancelled planning', { trusted: 'true', changes: 'cancelled' }],
  ['unskipped planning on untrusted PR', { changes: 'success' }],
  ['empty PR', { trusted: 'true', empty: 'true' }],
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
  assert.equal(cancels('omacom/omarchy-pkgs', 'auto/track-branches-omarchy-dev-omarchy-settings-dev'), false);
  assert.equal(cancels('omacom/omarchy-pkgs', 'auto/sync-five-minute-omarchy-dev-omarchy-settings-dev'), false);
  assert.equal(cancels('omacom/omarchy-pkgs', 'ttfx/fix'), true);
  assert.equal(cancels('someone/omarchy-pkgs', 'auto/sync-upstream'), true);
  assert.equal(cancels(undefined, ''), true); // workflow_dispatch
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

// Every bot lane opens one PR per package through package-prs.yml. The sync
// App pushes and opens the PRs: a GITHUB_TOKEN push would wait for build
// approval. The merge App arms auto-merge, in a job of its own: a
// GITHUB_TOKEN merge would not start publish.yml.
test('every bot lane opens its PRs per package through package-prs.yml', () => {
  for (const file of ['sync-upstream.yml', 'sync-rebuilds.yml']) {
    const text = readFileSync(join(__dirname, '../.github/workflows', file), 'utf8');
    assert.match(text, /package-pr-groups\.sh (?:"\$PREFIX"|auto\/sync-rebuilds) "\$RUNNER_TEMP\/pins\.patch"/, file);
    assert.match(text, /uses: \.\/\.github\/workflows\/package-prs\.yml/, file);
    assert.match(text, /prefix: (?:\$\{\{ needs.sync.outputs.prefix \}\}|auto\/sync-rebuilds)\n/, file);
    assert.doesNotMatch(text, /PKGS_BOT_TOKEN/, file);
    assert.match(text, /\n      PKGS_MERGE_APP_KEY: \$\{\{ secrets\.PKGS_MERGE_APP_KEY \}\}\n/, file);
    // An environment secret is empty in a called workflow unless the caller
    // passes it by name, even though the called job names the environment.
    assert.match(text, /\n      PKGS_SYNC_APP_KEY: \$\{\{ secrets\.PKGS_SYNC_APP_KEY \}\}\n/, file);
    assert.doesNotMatch(text, /create-pull-request|build-approved|\n  approve:\n/, file);
    assert.doesNotMatch(text, /^ +(contents|pull-requests|actions): write$/m, file);
  }
  const prs = readFileSync(join(__dirname, '../.github/workflows/package-prs.yml'), 'utf8');
  assert.match(prs, /token: \$\{\{ steps\.app\.outputs\.token \}\}/);
  assert.match(prs, /\n      PKGS_SYNC_APP_KEY:\n        required: true\n/);
  assert.doesNotMatch(prs, /secrets\.GITHUB_TOKEN/);
  // Both jobs that push or close take the sync App's key from bot-sync, which
  // only master can use, and mint a token limited to contents and PRs.
  for (const job of ['pr', 'close-superseded']) {
    const body = prs.split(new RegExp(`\\n  ${job}:\\n`))[1].split(/\n  [a-z-]+:\n/)[0];
    assert.match(body, /\n    environment:\n      name: bot-sync\n      deployment: false\n/, job);
    assert.match(body, /uses: actions\/create-github-app-token@[0-9a-f]{40} # v/, job);
    assert.match(body, /private-key: \$\{\{ secrets\.PKGS_SYNC_APP_KEY \}\}/, job);
    assert.match(body, /permission-contents: write\n +permission-pull-requests: write\n/, job);
  }
  // Every step that writes through the App takes the token minted in its own job.
  const step = name => {
    const start = prs.indexOf(`- name: ${name}\n`);
    assert.ok(start > 0, name);
    const end = prs.indexOf('\n      - name: ', start + 1);
    return prs.slice(start, end < 0 ? undefined : end);
  };
  assert.match(step('Hold an existing reviewed PR as a draft'), /\n +GH_TOKEN: \$\{\{ steps\.app\.outputs\.token \}\}\n/);
  assert.match(step('Open or update the PR'), /\n +token: \$\{\{ steps\.app\.outputs\.token \}\}\n/);
  assert.match(step('Close superseded PRs'), /\n +GH_TOKEN: \$\{\{ steps\.app\.outputs\.token \}\}\n/);
  // Recipes run only in the describe job, which can write nothing; the PR job
  // takes its text, or the caller's body when there is none.
  const job = name => prs.split(new RegExp(`\\n  ${name}:\\n`))[1].split(/\n  [a-z-]+:\n/)[0];
  const describe = job('describe');
  assert.match(describe, /\n    permissions:\n      contents: read\n/);
  assert.match(describe, /\n    continue-on-error: true\n/);
  assert.match(describe, /\n    timeout-minutes: \d+\n/);
  assert.match(describe, /timeout \d+ python3 helpers\/sync-pr-body\.py "\$\{args\[@\]\}" "\$\{names\[@\]\}"/);
  assert.doesNotMatch(describe, /secrets\.|create-github-app-token|environment:/);
  assert.doesNotMatch(job('pr'), /sync-pr-body\.py/);
  assert.doesNotMatch(job('close-superseded'), /sync-pr-body\.py/);
  // close-superseded paginates all open PRs (no 500-PR cap) and detects
  // non-conflicting PRs whose edits already landed on master via merge-tree.
  assert.doesNotMatch(job('close-superseded'), /--limit 500/);
  assert.match(job('close-superseded'), /gh api graphql --paginate/);
  assert.match(job('close-superseded'), /git merge-tree --write-tree HEAD FETCH_HEAD/);
  assert.match(prs, /\n      close-superseded:\n        description: .+?\n        type: boolean\n        default: true\n/);
  assert.match(job('close-superseded'), /^    if: \$\{\{ !cancelled\(\) && inputs\.close-superseded \}\}\n/);
  assert.match(job('pr'), /^    needs: describe\n    if: \$\{\{ !cancelled\(\) && inputs\.groups != '\[\]' \}\}\n/);
  const choose = step("Choose this PR's description");
  assert.match(choose, /printf '%s\\n' "\$FALLBACK" > "\$RUNNER_TEMP\/pr-body\.md"/);
  assert.match(choose, /FALLBACK: \$\{\{ inputs\.body \}\}/);
  assert.match(step('Fetch the PR descriptions'), /\n +continue-on-error: true\n/);
  // Only this run's describe artifact, and only after a clean download.
  assert.match(step('Fetch the PR descriptions'), /artifact-ids: \$\{\{ needs\.describe\.outputs\.artifact-id \}\}/);
  assert.match(step('Fetch the PR descriptions'), /\n +merge-multiple: true\n +path: \$\{\{ runner\.temp \}\}\/pr-descriptions\n/);
  assert.match(describe, /\n    outputs:\n      artifact-id: \$\{\{ steps\.upload\.outputs\.artifact-id \}\}\n/);
  assert.match(choose, /DOWNLOADED: \$\{\{ steps\.descriptions\.outcome == 'success' \}\}/);
  assert.match(choose, /if \[\[ \$DOWNLOADED == true && -s \$described \]\]; then/);
  // One group's failure, in git apply or the script, costs only its own description.
  assert.match(describe, /if ! \{ git apply [^\n]+ &&\n +timeout \d+ python3 helpers\/sync-pr-body\.py/);
  assert.match(describe, /git checkout -q -- pkgbuilds \|\| true\n +git clean -qfd -- pkgbuilds \|\| true/);
  assert.match(step('Open or update the PR'), /\n +body-path: \$\{\{ runner\.temp \}\}\/pr-body\.md\n/);
  assert.doesNotMatch(step('Open or update the PR'), /\n +body: /);
  // Both jobs key each PR the same way: the branch name with a newline, hashed.
  assert.match(describe, /key=\$\(printf '%s\\n' "\$branch" \| sha256sum \| cut -d' ' -f1\)/);
  assert.match(choose, /key=\$\(printf '%s\\n' "\$BRANCH" \| sha256sum \| cut -d' ' -f1\)/);
  // No PAT anywhere: the merge App arms auto-merge in the arm job, the only
  // job that holds its key. GitHub merges as whoever armed it.
  assert.doesNotMatch(prs, /PKGS_BOT_TOKEN/);
  assert.doesNotMatch(job('pr'), /gh pr merge|PKGS_MERGE_APP_KEY|bot-merge/);
  const arm = job('arm');
  assert.match(arm, /^    needs: pr\n    if: \$\{\{ !cancelled\(\) && inputs\.groups != '\[\]' \}\}\n/);
  assert.match(arm, /\n    environment:\n      name: bot-merge\n      deployment: false\n/);
  assert.match(arm, /private-key: \$\{\{ secrets\.PKGS_MERGE_APP_KEY \}\}/);
  assert.match(arm, /client-id: \$\{\{ vars\.PKGS_MERGE_APP_CLIENT_ID \}\}/);
  assert.match(arm, /permission-contents: read\n +permission-pull-requests: read\n/);
  assert.match(arm, /if: \$\{\{ steps\.plan\.outputs\.enable == 'true' \}\}\n[^\n]+create-github-app-token@[^\n]+\n[^\n]+\n[^\n]+\n[^\n]+\n +permission-contents: write\n +permission-pull-requests: write\n/);
  assert.doesNotMatch(arm, /PKGS_SYNC_APP_KEY|python3|git apply|download-artifact/);
  assert.match(arm, /ref: \$\{\{ github\.event\.repository\.default_branch \}\}/);
  assert.match(arm, /planArms\(/);
  assert.match(arm, /gh pr merge --auto "--\$method" --match-head-commit "\$sha" "\$number"/);
  assert.match(arm, /REPORT: \$\{\{ inputs\.report-package-failures \}\}/);
  // The PR jobs hand the arm job nothing: it finds and judges each PR itself.
  const uses = [...arm.matchAll(/uses: ([^@\s]+)@/g)].map(match => match[1]);
  assert.deepEqual(uses, ['actions/checkout', 'actions/create-github-app-token', 'actions/github-script',
    'actions/create-github-app-token', 'actions/upload-artifact']);
  assert.doesNotMatch(prs, /package-pr-arm|pull-request-head-sha/);
  assert.match(prs, /\n      PKGS_MERGE_APP_KEY:\n        required: true\n/);
  assert.match(prs, /fail-fast: false/);
  assert.match(prs, /draft: \$\{\{ matrix\.group\.review == true \}\}/);
  // A newer update to a reviewed PR re-drafts it first, and nothing is pushed if that fails.
  const hold = prs.indexOf('- name: Hold an existing reviewed PR as a draft');
  assert.ok(hold > 0 && hold < prs.indexOf('- name: Open or update the PR'), 'hold runs before the push');
  assert.match(prs, /id: hold\n +if: \$\{\{ steps\.apply\.outcome == 'success' && steps\.should_push\.outputs\.push == 'true' && matrix\.group\.review == true \}\}/);
  assert.match(prs, /\.github\/scripts\/hold-reviewed-pr\.sh "\$BRANCH" "\$\{packages\[@\]\}"/);
  assert.match(prs, /id: pr\n +if: \$\{\{ steps\.apply\.outcome == 'success' && steps\.should_push\.outputs\.push == 'true' && steps\.hold\.outcome != 'failure' \}\}/);
  assert.doesNotMatch(prs, /^ +(contents|pull-requests|actions): write$/m);
});

// The shell a workflow step runs, read from the YAML, so a test runs the
// exact block the runner would.
function runBlock(file, step) {
  const text = readFileSync(join(__dirname, '../.github/workflows', file), 'utf8');
  const lines = text.split('\n');
  const at = lines.findIndex(line => line.trim() === `- name: ${step}`);
  assert.ok(at >= 0, step);
  const run = lines.findIndex((line, i) => i > at && /^\s+run: \|$/.test(line));
  const indent = lines[run].search(/\S/) + 2;
  const body = [];
  for (const line of lines.slice(run + 1)) {
    if (line.trim() && line.search(/\S/) < indent) break;
    body.push(line.slice(indent));
  }
  return body.join('\n');
}

// A fake gh for the merge App's steps: each PR's auto-merge state in a JSON
// file, every call logged, gh pr merge arming the PR unless it is listed as
// failing, and gh pr view failing for the PRs listed.
function armFixture(prs, { failMerge = [], failView = [], failDisable = [] } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'arm-'));
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  const state = join(dir, 'prs.json');
  writeFileSync(state, JSON.stringify(prs));
  writeFileSync(join(bin, 'gh'), `#!/usr/bin/env node
const fs = require('fs');
fs.appendFileSync(${JSON.stringify(join(dir, 'calls'))}, process.argv.slice(2).join(' ') + '\\n');
const prs = JSON.parse(fs.readFileSync(${JSON.stringify(state)}, 'utf8'));
const args = process.argv.slice(2);
const n = args.find(a => /^[0-9]+$/.test(a));
if (args[0] === 'pr' && args[1] === 'view') {
  if (${JSON.stringify(failView)}.includes(n)) process.exit(1);
  const pr = prs[n];
  const jq = args[args.indexOf('--jq') + 1];
  const facts = jq.includes('headRefOid') ? [pr.state || 'OPEN', pr.isDraft || false, pr.base || 'master', pr.head || ''] : [];
  if (jq.includes('autoMergeRequest')) facts.push(pr.armed ? 'true' : 'false');
  console.log(facts.join(' '));
} else if (args[0] === 'pr' && args[1] === 'merge') {
  if (args.includes('--disable-auto')) {
    if (${JSON.stringify(failDisable)}.includes(n)) process.exit(1);
    prs[n].armed = false;
  } else if (${JSON.stringify(failMerge)}.includes(n)) process.exit(1);
  else prs[n].armed = true;
  fs.writeFileSync(${JSON.stringify(state)}, JSON.stringify(prs));
}
`, { mode: 0o755 });
  const plan = entries => writeFileSync(join(dir, 'arm-plan.json'), JSON.stringify(entries));
  const run = (script, env = {}) => spawnSync('bash', ['-eo', 'pipefail', '-c', script], {
    encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, RUNNER_TEMP: dir, GITHUB_REPOSITORY: 'omacom/omarchy-pkgs', ...env },
  });
  const calls = () => { try { return readFileSync(join(dir, 'calls'), 'utf8').trim().split('\n'); } catch { return []; } };
  const outcomes = () => JSON.parse(readFileSync(join(dir, 'armed/armed.outcomes'), 'utf8'));
  return { plan, run, calls, outcomes, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}

const sha = c => c.repeat(40);
const enable = (branch, number, head, method = 'merge') => ({ branch, number, action: 'enable', head_sha: sha(head), base: 'master', method });

test('the arm job arms what the plan judged, at the judged head, and reports the rest', () => {
  const f = armFixture({ 101: { head: sha('a') }, 102: { armed: true, head: sha('b') }, 103: {}, 104: {},
    105: { head: sha('e') }, 106: { head: sha('f'), base: 'rc' }, 107: { head: sha('9'), isDraft: true },
    108: { head: sha('8'), state: 'MERGED' } });
  try {
    f.plan([
      enable('auto/sync-upstream-a', '101', 'a'),
      enable('auto/sync-upstream-b', '102', 'b'),
      enable('auto/sync-upstream-e', '105', '5'), // pushed since it was judged
      enable('auto/sync-upstream-f', '106', 'f'), // retargeted since
      enable('auto/sync-upstream-g', '107', '9'), // drafted since
      enable('auto/sync-upstream-h', '108', '8'), // merged since: the update landed
      { branch: 'auto/sync-upstream-c', number: '103', outcome: 'refused', reason: 'PR is a draft' },
      { branch: 'auto/sync-upstream-d', number: '104', outcome: 'success', reason: 'already merged' },
    ]);
    const result = f.run(runBlock('package-prs.yml', 'Arm auto-merge on each PR'), { REPORT: 'true' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    const merges = f.calls().filter(call => call.startsWith('pr merge'));
    assert.deepEqual(merges, [`pr merge --auto --merge --match-head-commit ${sha('a')} 101 -R omacom/omarchy-pkgs`]);
    const outcomes = f.outcomes();
    for (const branch of ['e', 'f', 'g']) {
      assert.equal(outcomes[`auto/sync-upstream-${branch}`].outcome, 'failure', branch);
      assert.match(outcomes[`auto/sync-upstream-${branch}`].reason, /^moved since it was judged: /, branch);
      delete outcomes[`auto/sync-upstream-${branch}`];
    }
    assert.deepEqual(outcomes['auto/sync-upstream-h'], { number: '108', outcome: 'success', reason: 'merged' });
    delete outcomes['auto/sync-upstream-h'];
    assert.deepEqual(outcomes, {
      'auto/sync-upstream-a': { number: '101', outcome: 'success', reason: '' },
      'auto/sync-upstream-b': { number: '102', outcome: 'success', reason: '' },
      'auto/sync-upstream-c': { number: '103', outcome: 'refused', reason: 'PR is a draft' },
      'auto/sync-upstream-d': { number: '104', outcome: 'success', reason: 'already merged' },
    });
    assert.match(result.stdout, /::warning::Could not enable auto-merge on #103 \(auto\/sync-upstream-c\): refused, PR is a draft/);
  } finally { f.cleanup(); }
});

test('one PR that cannot be armed does not stop the others, and fails the job without a report', () => {
  for (const report of ['true', 'false']) {
    const f = armFixture({ 101: { head: sha('a') }, 102: {}, 103: { head: sha('c') }, 104: {} }, { failMerge: ['101'], failView: ['102'] });
    try {
      f.plan([
        enable('auto/sync-upstream-a', '101', 'a'),
        enable('auto/sync-upstream-b', '102', 'b'),
        enable('auto/sync-upstream-e', '104', 'g'), // not a SHA
        enable('auto/sync-upstream-c', '103', 'c'),
      ]);
      const result = f.run(runBlock('package-prs.yml', 'Arm auto-merge on each PR'), { REPORT: report });
      assert.equal(result.status, report === 'true' ? 0 : 1, report + result.stdout + result.stderr);
      const outcomes = f.outcomes();
      assert.deepEqual(Object.fromEntries(Object.entries(outcomes).map(([b, o]) => [b, o.outcome])), {
        'auto/sync-upstream-a': 'failure', 'auto/sync-upstream-b': 'failure',
        'auto/sync-upstream-e': 'failure', 'auto/sync-upstream-c': 'success',
      });
      assert.equal(outcomes['auto/sync-upstream-b'].reason, 'could not read the PR');
      assert.equal(outcomes['auto/sync-upstream-e'].reason, 'bad plan entry');
      assert.ok(!f.calls().some(call => call.includes(' 104 ')), 'a bad entry calls nothing');
    } finally { f.cleanup(); }
  }
});

test('an empty plan arms nothing and passes', () => {
  const f = armFixture({});
  try {
    f.plan([]);
    const result = f.run(runBlock('package-prs.yml', 'Arm auto-merge on each PR'), { REPORT: 'false' });
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.deepEqual(f.outcomes(), {});
    assert.deepEqual(f.calls(), []);
  } finally { f.cleanup(); }
});

test('auto-merge acts only when the live state needs it, and a failed lookup is never "not armed"', () => {
  const choose = join(__dirname, '../.github/scripts/auto-merge-action.sh');
  const cases = [[true, 'true', 'false', 'none'], [false, 'true', 'false', 'enable'],
    [true, 'false', 'true', 'withdraw'], [false, 'false', 'true', 'none'], [false, 'false', 'false', 'none']];
  for (const [armed, on, off, action] of cases) {
    const f = armFixture({ 7: { armed } });
    try {
      const result = f.run(`${choose} 7 ${on} ${off}`);
      assert.equal(result.status, 0, result.stderr);
      assert.equal(result.stdout.trim().split('\n').at(-1), `action=${action}`, JSON.stringify([armed, on, off]));
    } finally { f.cleanup(); }
  }
  const apply = runBlock('auto-merge-pr.yml', 'Arm or withdraw auto-merge');
  const env = { PR: '7', HEAD_SHA: sha('a'), BASE: 'master', METHOD: 'squash' };
  const scenarios = [
    // [state, options, action, exit status, what gh pr merge was asked]
    [false, {}, 'withdraw', 0, []], // already gone: done
    [true, {}, 'withdraw', 0, ['pr merge --disable-auto 7 -R omacom/omarchy-pkgs']],
    [true, { failDisable: ['7'] }, 'withdraw', 1, ['pr merge --disable-auto 7 -R omacom/omarchy-pkgs']],
    [true, { failView: ['7'] }, 'withdraw', 1, []],
    [false, { failView: ['7'] }, 'enable', 1, []],
    [false, {}, 'enable', 0, [`pr merge --auto --squash --match-head-commit ${sha('a')} 7 -R omacom/omarchy-pkgs`]],
    [false, { failMerge: ['7'] }, 'enable', 1, [`pr merge --auto --squash --match-head-commit ${sha('a')} 7 -R omacom/omarchy-pkgs`]],
    // Moved between the decision and the write: nothing is armed.
    [false, { pr: { base: 'rc' } }, 'enable', 0, []],
    [false, { pr: { head: sha('b') } }, 'enable', 0, []],
    [false, { pr: { isDraft: true } }, 'enable', 0, []],
  ];
  for (const [armed, { pr = {}, ...options }, action, status, merges] of scenarios) {
    const f = armFixture({ 7: { armed, head: sha('a'), ...pr } }, options);
    try {
      const result = f.run(apply, { ...env, ACTION: action });
      const label = JSON.stringify([armed, options, action]);
      assert.equal(result.status, status, label + result.stdout + result.stderr);
      assert.deepEqual(f.calls().filter(call => call.startsWith('pr merge')), merges, label);
    } finally { f.cleanup(); }
  }
  for (const bad of ['1e2', '0x10', '07', 'auto/sync-upstream-a', '']) {
    const f = armFixture({});
    try {
      assert.notEqual(f.run(`${choose} '${bad}' true false`).status, 0, bad);
      assert.notEqual(f.run(apply, { ...env, PR: bad, ACTION: 'enable' }).status, 0, bad);
      assert.deepEqual(f.calls(), [], bad);
    } finally { f.cleanup(); }
  }
});

// One PR per package, except packages pinned from the same upstream branch,
// which move in lockstep and so share one.
const groupsScript = join(__dirname, '../.github/scripts/package-pr-groups.sh');
test('package PRs split per package and keep branch siblings and lockstep groups together', () => {
  const dir = mkdtempSync(join(tmpdir(), 'package-pr-groups-'));
  try {
    const git = (...args) => execFileSync('git', ['-C', dir, '-c', 'user.name=T', '-c', 'user.email=t@t', ...args]);
    git('init', '-q');
    const write = (name, watch, extra = {}) => {
      const pkg = join(dir, 'pkgbuilds', name);
      mkdirSync(join(pkg, '.omarchy'), { recursive: true });
      writeFileSync(join(pkg, 'PKGBUILD'), `pkgname=${name}\npkgver=1\npkgrel=1\n`);
      writeFileSync(join(pkg, '.omarchy/package.json'), JSON.stringify({ ...extra, upstream: { watch } }));
    };
    const branch = { git_branch: 'https://github.com/omacom/omarchy.git', branch: 'quattro' };
    write('omarchy-dev', branch);
    write('omarchy-settings-dev', branch);
    write('omasnap-git', { git_branch: 'https://github.com/omacom/omasnap.git', branch: 'main' });
    write('zed', { github: 'zed-industries/zed' });
    write('speakersafetyd', { git_tags: 'https://github.com/AsahiLinux/speakersafetyd.git' }, { review: true });
    write('untouched', { github: 'x/y' });
    write('nvidia-utils', undefined, { lockstep: 'nvidia' });
    write('linux-omarchy', undefined, { lockstep: 'nvidia' });
    git('add', '.');
    git('commit', '-qm', 'base');
    for (const name of ['omarchy-dev', 'omarchy-settings-dev', 'omasnap-git', 'zed', 'speakersafetyd', 'nvidia-utils', 'linux-omarchy']) {
      writeFileSync(join(dir, 'pkgbuilds', name, 'PKGBUILD'), `pkgname=${name}\npkgver=2\npkgrel=1\n`);
    }
    const patch = join(dir, 'pins.patch');
    const groups = JSON.parse(execFileSync(groupsScript, ['auto/track-branches', patch], { cwd: dir, encoding: 'utf8' }));
    assert.deepEqual(groups, [
      { branch: 'auto/track-branches-linux-omarchy-nvidia-utils', packages: 'linux-omarchy nvidia-utils' },
      { branch: 'auto/track-branches-omarchy-dev-omarchy-settings-dev', packages: 'omarchy-dev omarchy-settings-dev' },
      { branch: 'auto/track-branches-omasnap-git', packages: 'omasnap-git' },
      { branch: 'auto/track-branches-speakersafetyd', packages: 'speakersafetyd', review: true },
      { branch: 'auto/track-branches-zed', packages: 'zed' },
    ]);
    assert.match(readFileSync(patch, 'utf8'), /pkgbuilds\/zed\/PKGBUILD/);
    git('checkout', '-q', '--', 'pkgbuilds');
    assert.deepEqual(JSON.parse(execFileSync(groupsScript, ['auto/sync-upstream', patch], { cwd: dir, encoding: 'utf8' })), []);
  } finally {
    rmSync(dir, { recursive: true, force: true });
  }
});

// hold-reviewed-pr.sh against a fake gh: a recorded log of calls, and a PR
// state file the fake's mutations change unless `stuck` pins it.
const holdScript = join(__dirname, '../.github/scripts/hold-reviewed-pr.sh');
function holdFixture({ pr = '41', draft = false, armed = true, stuck = false, sameContent = false } = {}) {
  const dir = mkdtempSync(join(tmpdir(), 'hold-reviewed-pr-'));
  const git = (cwd, ...args) => execFileSync('git', ['-C', cwd, '-c', 'user.name=T', '-c', 'user.email=t@t', ...args]);
  const origin = join(dir, 'origin.git');
  const work = join(dir, 'work');
  execFileSync('git', ['init', '-q', '--bare', origin]);
  mkdirSync(join(work, 'pkgbuilds/speakersafetyd'), { recursive: true });
  git(work, 'init', '-q');
  git(work, 'remote', 'add', 'origin', origin);
  writeFileSync(join(work, 'pkgbuilds/speakersafetyd/PKGBUILD'), 'pkgver=3.0.0\n');
  git(work, 'add', '.');
  git(work, 'commit', '-qm', 'reviewed update');
  git(work, 'push', '-q', 'origin', 'HEAD:refs/heads/auto/sync-upstream-speakersafetyd');
  if (!sameContent) writeFileSync(join(work, 'pkgbuilds/speakersafetyd/PKGBUILD'), 'pkgver=3.0.1\n');
  const bin = join(dir, 'bin');
  mkdirSync(bin);
  const stateFile = join(dir, 'state');
  writeFileSync(stateFile, `${draft} ${armed}\n`);
  writeFileSync(join(bin, 'gh'), `#!/bin/bash
echo "$*" >> "${join(dir, 'calls')}"
read -r draft armed < "${stateFile}"
case "$1 $2" in
  "api -X") echo "${pr}" ;;
  "pr view") echo "$draft $armed" ;;
  "pr merge") ${stuck ? 'true' : `echo "$draft false" > "${stateFile}"`} ;;
  "pr ready") ${stuck ? 'true' : `echo "true $armed" > "${stateFile}"`} ;;
esac
`, { mode: 0o755 });
  const run = () => spawnSync(holdScript, ['auto/sync-upstream-speakersafetyd', 'speakersafetyd'], {
    cwd: work, encoding: 'utf8',
    env: { ...process.env, PATH: `${bin}:${process.env.PATH}`, GITHUB_REPOSITORY: 'omacom/omarchy-pkgs' },
  });
  const calls = () => { try { return readFileSync(join(dir, 'calls'), 'utf8').trim().split('\n'); } catch { return []; } };
  return { run, calls, cleanup: () => rmSync(dir, { recursive: true, force: true }) };
}
const mutations = calls => calls.filter(call => /^pr (merge|ready)/.test(call));

test('a newer update re-drafts a ready, armed reviewed PR and checks both before the push', () => {
  const f = holdFixture();
  try {
    const result = f.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    // Only this repository's PR into master: a fork may use the same branch name.
    assert.match(f.calls()[0], /^api -X GET repos\/omacom\/omarchy-pkgs\/pulls -f head=omacom:auto\/sync-upstream-speakersafetyd -f base=master -f state=open --jq /);
    assert.deepEqual(mutations(f.calls()), ['pr merge --disable-auto 41 -R omacom/omarchy-pkgs', 'pr ready --undo 41 -R omacom/omarchy-pkgs']);
    assert.match(f.calls().at(-1), /^pr view 41 /, 'the state is read back after the change');
    assert.match(result.stdout, /#41 is back to a draft with auto-merge off/);
  } finally { f.cleanup(); }
});

test('a reviewed PR that stays ready or armed stops the push', () => {
  const f = holdFixture({ stuck: true });
  try {
    const result = f.run();
    assert.equal(result.status, 1);
    assert.match(result.stdout, /#41 is still draft=false auto-merge=true: not pushing/);
  } finally { f.cleanup(); }
});

test('a reviewed PR already carrying the same update, or no PR at all, is left alone', () => {
  for (const options of [{ sameContent: true }, { pr: '' }]) {
    const f = holdFixture(options);
    try {
      const result = f.run();
      assert.equal(result.status, 0, result.stdout + result.stderr);
      assert.deepEqual(mutations(f.calls()), [], JSON.stringify(options));
    } finally { f.cleanup(); }
  }
});

test('a draft without auto-merge needs no change but is still checked', () => {
  const f = holdFixture({ draft: true, armed: false });
  try {
    const result = f.run();
    assert.equal(result.status, 0, result.stdout + result.stderr);
    assert.deepEqual(mutations(f.calls()), []);
    assert.equal(f.calls().filter(call => call.startsWith('pr view')).length, 2);
  } finally { f.cleanup(); }
});

const { decide } = require('../.github/scripts/auto-merge-pr.cjs');
const repository = 'omacom/omarchy-pkgs';
const mergeable = (overrides = {}) => ({
  state: 'open', draft: false, labels: [], changed_files: 2,
  base: { ref: 'master', repo: { full_name: repository, default_branch: 'master' } },
  head: { ref: 'superwhisper-bin', repo: { full_name: repository } }, ...overrides,
});
const packageFiles = [{ filename: 'pkgbuilds/superwhisper-bin/PKGBUILD' },
  { filename: 'pkgbuilds/superwhisper-bin/.omarchy/package.json' }];

test('auto-merge follows the build gate: trusted authors, or build-approved for unknown ones', () => {
  for (const vouchStatus of ['collaborator', 'vouched', 'bot']) {
    assert.equal(decide({ pr: mergeable(), files: packageFiles, vouchStatus, repository }).enable, true, vouchStatus);
  }
  assert.equal(decide({ pr: mergeable(), files: packageFiles, vouchStatus: 'unknown', repository }).enable, false);
  const labelled = mergeable({ labels: [{ name: 'build-approved' }] });
  assert.equal(decide({ pr: labelled, files: packageFiles, vouchStatus: 'unknown', repository }).enable, true);
  // A denouncement is absolute, and a failed lookup is not approval.
  for (const vouchStatus of ['denounced', '', undefined, 'error']) {
    assert.equal(decide({ pr: labelled, files: packageFiles, vouchStatus, repository }).enable, false, String(vouchStatus));
  }
});

test('auto-merge leaves the PRs of an author who merges by hand, and takes back one armed earlier', () => {
  for (const login of ['emirb', 'EmirB']) {
    const decision = decide({ pr: mergeable({ user: { login } }), files: packageFiles, vouchStatus: 'collaborator', repository });
    assert.equal(decision.enable, false, login);
    assert.match(decision.reason, /merges by hand/);
  }
  const { withdraw } = require('../.github/scripts/auto-merge-pr.cjs');
  const mine = decide({ pr: mergeable({ user: { login: 'emirb' } }), files: packageFiles, vouchStatus: 'collaborator', repository });
  assert.equal(withdraw(mine, 'collaborator', false), true);
  assert.equal(decide({ pr: mergeable({ user: { login: 'ryanrhughes' } }), files: packageFiles, vouchStatus: 'collaborator', repository }).enable, true);
});

test('auto-merge only lands PRs that change nothing outside pkgbuilds/', () => {
  const check = files => decide({ pr: mergeable(), files, vouchStatus: 'collaborator', repository }).enable;
  assert.equal(check(packageFiles), true);
  assert.equal(check([...packageFiles, { filename: '.github/workflows/publish.yml' }]), false);
  assert.equal(check([{ filename: 'bin/build' }]), false);
  assert.equal(check([{ filename: 'pkgbuilds/x/PKGBUILD', previous_filename: 'helpers/x.sh' }]), false);
  assert.equal(check([]), false);
});

test('auto-merge accepts a new test file, never a change to test.yml or an existing test', () => {
  const check = files => decide({ pr: mergeable({ changed_files: files.length }), files, vouchStatus: 'collaborator', repository }).enable;
  const wiring = patch => ({ filename: '.github/workflows/test.yml', status: 'modified', patch });
  const newTest = { filename: 'tests/superwhisper-bin-install.sh', status: 'added' };
  assert.equal(check([...packageFiles, newTest]), true);
  // The merge App has no Workflows permission, and a workflow change needs a
  // maintainer anyway, however small.
  const adds = '@@ -67,6 +67,7 @@ jobs:\n               ./tests/voxtype-bin-install.sh\n+              ./tests/superwhisper-bin-install.sh';
  assert.equal(check([...packageFiles, newTest, wiring(adds)]), false);
  // An existing test can run on master with write access; editing it is not a package change.
  assert.equal(check([...packageFiles, { filename: 'tests/build-isolation.sh', status: 'modified' }]), false);
});

test('auto-merge only lands PRs into the default branch', () => {
  const check = base => decide({ pr: mergeable({ base }), files: packageFiles, vouchStatus: 'collaborator', repository });
  assert.equal(check({ ref: 'master', repo: { full_name: repository, default_branch: 'master' } }).enable, true);
  // rc has no required checks: an armed PR into it would merge at once, unbuilt.
  const rc = check({ ref: 'rc', repo: { full_name: repository, default_branch: 'master' } });
  assert.equal(rc.enable, false);
  assert.match(rc.reason, /targets rc/);
  assert.equal(check(undefined).enable, false);
  const text = readFileSync(join(__dirname, '../.github/workflows/auto-merge-pr.yml'), 'utf8');
  // Every base triggers the workflow, so a PR moved off master (edited)
  // loses auto-merge instead of keeping it unseen.
  assert.match(text, /pull_request_target:\n    types: \[[^\]]*\bedited\b[^\]]*\]\n/);
  assert.doesNotMatch(text, /pull_request_target:\n    branches:/);
});

test('auto-merge refuses a PR whose file list the API cut short', () => {
  const check = changed_files => decide({ pr: mergeable({ changed_files }), files: packageFiles, vouchStatus: 'collaborator', repository });
  assert.equal(check(2).enable, true);
  const cut = check(3001);
  assert.equal(cut.enable, false);
  assert.match(cut.reason, /3001 files/);
});

test('sync PRs land as merge commits and other PRs squash', () => {
  const method = pr => decide({ pr, files: packageFiles, vouchStatus: 'bot', repository }).method;
  assert.equal(method(mergeable({ head: { ref: 'auto/sync-upstream-zed', repo: { full_name: repository } } })), 'merge');
  assert.equal(method(mergeable()), 'squash');
  // A fork's auto/ branch is not a sync lane.
  assert.equal(method(mergeable({ head: { ref: 'auto/sync-upstream-zed', repo: { full_name: 'someone/omarchy-pkgs' } } })), 'squash');
});

test('auto-merge accepts regenerated owners.json directories, never a change to an approval', () => {
  const file = { filename: 'release/owners.json', status: 'modified' };
  const owners = (approved, dirs) => JSON.stringify({ version: 2, approved, dirs });
  const dir = (name, names) => ({ dir: name, pkgbase: name, arches: ['x86_64'], names, provides: [], replaces: [] });
  const sudo = { dir: 'weather', kind: 'replaces', name: 'sudo', arches: ['x86_64'] };
  const base = owners([], [dir('walker', ['walker'])]);
  const check = (head, files = [...packageFiles, file]) =>
    decide({ pr: mergeable(), files, vouchStatus: 'collaborator', repository, owners: { base, head } }).enable;
  // A new package, and a renamed one: only directories change.
  assert.equal(check(owners([], [dir('walker', ['walker']), dir('weather', ['weather'])])), true);
  assert.equal(check(owners([], [dir('walker', ['walker', 'walker-git'])])), true);
  // An approval lets a directory claim another's name: a maintainer decides,
  // however the line is written.
  assert.equal(check(owners([sudo], [dir('walker', ['walker'])])), false);
  assert.equal(check(owners([{ ...sudo, pkgbase: 'weather' }], [dir('walker', ['walker'])])), false);
  // Another version, a file that does not parse, a new file, or no contents.
  assert.equal(check(JSON.stringify({ version: 3, approved: [], dirs: [] })), false);
  assert.equal(check('{"version":2,'), false);
  assert.equal(check(owners([], []), [...packageFiles, { ...file, status: 'added' }]), false);
  assert.equal(decide({ pr: mergeable(), files: [...packageFiles, file], vouchStatus: 'collaborator', repository }).enable, false);
});

test('auto-merge is withdrawn when the PR no longer qualifies, and on a failed lookup only when its files do not', () => {
  const { withdraw } = require('../.github/scripts/auto-merge-pr.cjs');
  const no = { enable: false }, yes = { enable: true };
  for (const status of ['bot', 'collaborator', 'vouched', 'unknown', 'denounced']) {
    assert.equal(withdraw(no, status), true, status);
    assert.equal(withdraw(yes, status), false, status);
  }
  // The vouch lookup failed: no answer about the author, so auto-merge
  // stays as it is while the files still qualify, and goes when they do not.
  for (const status of ['', undefined, 'error']) {
    assert.equal(withdraw(no, status, true), false, String(status));
    assert.equal(withdraw(no, status, false), true, String(status));
  }
  const text = readFileSync(join(__dirname, '../.github/workflows/auto-merge-pr.yml'), 'utf8');
  assert.match(text, /types: \[opened, reopened, synchronize,/);
  assert.match(text, /gh pr merge --disable-auto "\$PR" -R "\$GITHUB_REPOSITORY" \|\| \[\[ "\$\(armed\)" == false \]\]/);
});

test('auto-merge skips drafts and closed PRs, and arms every bot lane', () => {
  const check = pr => decide({ pr, files: packageFiles, vouchStatus: 'bot', repository }).enable;
  assert.equal(check(mergeable({ draft: true })), false);
  assert.equal(check(mergeable({ state: 'closed' })), false);
  // The bot lanes already enable their own auto-merge; agreeing is harmless.
  for (const ref of ['auto/sync-upstream-zed', 'auto/sync-rebuilds-walker', 'auto/track-branches-omarchy-dev-omarchy-settings-dev']) {
    assert.equal(check(mergeable({ head: { ref, repo: { full_name: repository } } })), true, ref);
  }
});

test('auto-merge decides without a write credential and arms with the merge App alone', () => {
  const text = readFileSync(join(__dirname, '../.github/workflows/auto-merge-pr.yml'), 'utf8');
  const job = name => text.split(new RegExp(`\\n  ${name}:\\n`))[1].split(/\n  [a-z-]+:\n/)[0];
  assert.match(text, /pull_request_target:/);
  assert.doesNotMatch(text, /PKGS_BOT_TOKEN|head\.sha \}\}|head\.ref \}\}|refs\/pull\//);
  // Edits to a PR's title or body must not keep cancelling a withdraw.
  assert.match(text, /\nconcurrency:\n  group: auto-merge-pr-[^\n]+\n  cancel-in-progress: false\n/);
  // Nothing third-party runs here: the vouch action installs an unpinned
  // Nushell, and author trust is read by auto-merge-pr.cjs instead.
  assert.doesNotMatch(text, /mitchellh|setup-nu/);
  // decide holds no environment and no secret, and checks out only the
  // default branch.
  const decideJob = job('decide');
  assert.match(decideJob, /ref: \$\{\{ github\.event\.repository\.default_branch \}\}/);
  assert.doesNotMatch(decideJob, /environment:|secrets\.(?!GITHUB_TOKEN)|create-github-app-token/);
  assert.match(decideJob, /\n    outputs:\n      action: \$\{\{ steps\.action\.outputs\.action \}\}\n    steps:/);
  // apply holds the merge App's key and runs only first-party actions and gh.
  // It decides again, live, from the event's PR, author trust included:
  // nothing but the action crosses from decide, so a stale decision arms
  // nothing the rule would not arm now.
  const apply = job('apply');
  assert.match(apply, /^    needs: decide\n    if: \$\{\{ needs\.decide\.outputs\.action == 'enable' \|\| needs\.decide\.outputs\.action == 'withdraw' \}\}\n/);
  assert.match(apply, /\n    environment:\n      name: bot-merge\n      deployment: false\n/);
  assert.match(apply, /private-key: \$\{\{ secrets\.PKGS_MERGE_APP_KEY \}\}/);
  assert.match(apply, /permission-contents: write\n +permission-pull-requests: write\n/);
  assert.doesNotMatch(apply, /mitchellh/);
  const uses = [...apply.matchAll(/uses: ([^@\s]+)@/g)].map(match => match[1]);
  assert.deepEqual(uses, ['actions/checkout', 'actions/github-script', 'actions/create-github-app-token']);
  assert.doesNotMatch(apply, /needs\.decide\.outputs\.(?!action)/);
  assert.match(apply, /vouched: readFileSync\('\.github\/VOUCHED\.td', 'utf8'\)/);
  assert.match(apply, /NUMBER: \$\{\{ github\.event\.pull_request\.number \|\| github\.event\.inputs\.pr \}\}/);
  assert.ok(apply.indexOf('github-script') < apply.indexOf('create-github-app-token'), 'decides before the token exists');
  assert.match(text, /types: \[opened, reopened, synchronize, ready_for_review, labeled, unlabeled, edited\]/);
  assert.match(apply, /gh pr merge --auto "--\$METHOD" --match-head-commit "\$HEAD_SHA" "\$PR"/);
  assert.match(apply, /PR: \$\{\{ steps\.decide\.outputs\.number \}\}/);
  assert.match(apply, /\[\[ \$METHOD == merge \]\] \|\| METHOD=squash/);
  assert.doesNotMatch(text, /^ +(contents|pull-requests|actions): write$/m);
});

const { vouchedStatus, authorStatus, prNumber, planArms } = require('../.github/scripts/auto-merge-pr.cjs');

// The vouch action's rule, mitchellh/vouch v1.5.0 (vouch/lib.nu check-user):
// the first entry for the user decides, ignoring case; a bare name counts for
// every platform; another platform's entry does not count.
test('VOUCHED.td is read as the vouch action reads it', () => {
  const file = [
    '# Trust list', '', 'github:Alice', '-github:mallory spam', 'bob', 'gitlab:carol',
    '-github:dave first', 'github:dave later', '  github:erin  # details, not a comment',
    // vouch/file.nu: no inline comments, and only a space ends the handle.
    'github:gil#note', 'github:hal\treason', '-github:ivy#x', 'github:ivy', '  # github:jo',
  ].join('\n');
  const cases = { alice: 'vouched', ALICE: 'vouched', mallory: 'denounced', bob: 'vouched', carol: 'unknown',
    dave: 'denounced', erin: 'vouched', frank: 'unknown', 'github:alice': 'unknown',
    gil: 'unknown', 'gil#note': 'vouched', hal: 'unknown', ivy: 'vouched', jo: 'unknown' };
  for (const [login, status] of Object.entries(cases)) assert.equal(vouchedStatus(file, login), status, login);
  // The repository's own file parses: its first entry is vouched.
  const real = readFileSync(join(__dirname, '../.github/VOUCHED.td'), 'utf8');
  const first = real.split('\n').find(line => /^github:/.test(line)).slice('github:'.length);
  assert.equal(vouchedStatus(real, first), 'vouched');
});

test('author trust: bots, then write access, then VOUCHED.td, as vouch decides it', async () => {
  const github = permissions => ({ rest: { repos: { getCollaboratorPermissionLevel: async ({ username }) => {
    if (!(username in permissions)) throw Object.assign(new Error('404'), { status: 404 });
    return { data: { permission: permissions[username] } };
  } } } });
  const context = { repo: { owner: 'omacom', repo: 'omarchy-pkgs' } };
  const vouched = 'github:vic\n-github:den\n';
  const status = (login, permissions = {}) => authorStatus({ github: github(permissions), context, login, vouched });
  assert.equal(await status('omarchy-pkgs-sync[bot]'), 'bot');
  assert.equal(await status('ann', { ann: 'admin' }), 'collaborator');
  assert.equal(await status('wes', { wes: 'write' }), 'collaborator');
  assert.equal(await status('rea', { rea: 'read' }), 'unknown');
  assert.equal(await status('vic'), 'vouched');
  assert.equal(await status('den'), 'denounced');
  assert.equal(await status('den', { den: 'write' }), 'collaborator', 'vouch checks access before the file');
});

test('a transient permission error is retried as vouch retries it, a 404 is not', async () => {
  const context = { repo: { owner: 'omacom', repo: 'omarchy-pkgs' } };
  const flaky = statuses => {
    const seen = [];
    return { seen, github: { rest: { repos: { getCollaboratorPermissionLevel: async () => {
      const status = statuses[seen.length];
      seen.push(status ?? 'ok');
      if (status) throw Object.assign(new Error(String(status)), { status });
      return { data: { permission: 'write' } };
    } } } } };
  };
  const waits = [];
  const wait = async ms => { waits.push(ms); };
  let f = flaky([503, 429, 403]);
  assert.equal(await authorStatus({ ...f, context, login: 'wes', vouched: '', wait }), 'collaborator');
  assert.deepEqual(waits, [1000, 2000, 4000]);
  f = flaky([404]);
  assert.equal(await authorStatus({ ...f, context, login: 'wes', vouched: 'github:wes', wait }), 'vouched');
  assert.equal(f.seen.length, 1);
  f = flaky([500, 500, 500, 500, 500, 500, 500]);
  assert.equal(await authorStatus({ ...f, context, login: 'wes', vouched: '', wait }), 'unknown');
  assert.equal(f.seen.length, 6, 'five retries, then the file');
});

test('a PR number is taken only as a person types it', () => {
  assert.equal(prNumber('3562'), 3562);
  assert.equal(prNumber(3562), 3562);
  for (const bad of ['1e2', '0x10', '07', ' 7', '7 ', '', undefined, '-1', '1.0', 'auto/sync-upstream-a']) {
    assert.throws(() => prNumber(bad), /not a PR number/, String(bad));
  }
});

// A fake GitHub for planArms: PRs by number, found by owner:branch and base.
function fakeGitHub(prs, { failCompare = [] } = {}) {
  const calls = [];
  const rest = {
    repos: {
      get: async () => ({ data: { default_branch: 'master' } }),
      getCollaboratorPermissionLevel: async () => { throw Object.assign(new Error('404'), { status: 404 }); },
    },
    pulls: {
      list: async query => {
        calls.push(query);
        const [owner, branch] = query.head.split(':');
        return { data: Object.values(prs).filter(pr => pr.head.repo.owner.login === owner && pr.head.ref === branch
          && pr.base.ref === query.base && pr.state === query.state).sort((a, b) => b.number - a.number).slice(0, query.per_page) };
      },
      get: async ({ pull_number }) => ({ data: prs[pull_number] }),
    },
  };
  // The diff is read by base...head SHA, never by PR number.
  rest.repos.compareCommitsWithBasehead = async ({ basehead }) => {
    const [base, head] = basehead.split('...');
    const pr = Object.values(prs).find(pr => pr.head.sha === head && pr.base.ref === base);
    if (failCompare.includes(pr.number)) throw new Error('503 Service Unavailable');
    return { data: { files: pr.files } };
  };
  return { calls, github: { rest } };
}

test('the arm plan judges each group PR by the auto-merge rule and never a fork or reviewed group', async () => {
  const pr = (number, branch, overrides = {}) => ({
    number, state: 'open', draft: false, merged_at: null, labels: [], user: { login: 'omarchy-pkgs-sync[bot]' },
    head: { ref: branch, sha: String(number % 10).repeat(40), repo: { full_name: 'omacom/omarchy-pkgs', owner: { login: 'omacom' } } },
    base: { ref: 'master', sha: 'b'.repeat(40), repo: { default_branch: 'master' } },
    changed_files: 1, files: [{ filename: `pkgbuilds/${branch.split('-').pop()}/PKGBUILD`, status: 'modified' }],
    ...overrides,
  });
  const { github, calls } = fakeGitHub({
    1: pr(1, 'auto/sync-upstream-a'),
    2: pr(2, 'auto/sync-upstream-b', { files: [{ filename: '.github/workflows/publish.yml', status: 'modified' }] }),
    3: pr(3, 'auto/sync-upstream-c', { merged_at: '2026-11-26T00:00:00Z', state: 'closed' }),
    4: pr(4, 'auto/sync-upstream-d', { state: 'closed' }),
    5: pr(5, 'auto/sync-upstream-e', { head: { ref: 'auto/sync-upstream-e', sha: 'f'.repeat(40),
      repo: { full_name: 'mallory/omarchy-pkgs', owner: { login: 'mallory' } } } }),
    6: pr(6, 'auto/sync-upstream-f', { draft: true }),
    7: pr(7, 'auto/sync-upstream-g'),
    // An older open PR and a newer closed one on the same branch: the open one counts.
    8: pr(8, 'auto/sync-upstream-h'),
    18: pr(18, 'auto/sync-upstream-h', { state: 'closed' }),
    9: pr(9, 'auto/sync-upstream-i'),
    10: pr(10, 'auto/sync-upstream-j', { files: Array.from({ length: 300 }, (_, i) => ({ filename: `pkgbuilds/p${i}/PKGBUILD`, status: 'modified' })), changed_files: 300 }),
  }, { failCompare: [9] });
  const groups = ['a', 'b', 'c', 'd', 'e', 'f'].map(x => ({ branch: `auto/sync-upstream-${x}` }))
    .concat([{ branch: 'auto/sync-upstream-g', review: true }], ['h', 'i', 'j'].map(x => ({ branch: `auto/sync-upstream-${x}` })));
  const context = { repo: { owner: 'omacom', repo: 'omarchy-pkgs' } };
  const plan = await planArms({ github, context, core: { info() {} }, groups, vouched: '' });
  const brief = plan.map(({ branch, number, action, outcome, head_sha, method }) =>
    [branch.slice(-1), number, action || outcome, head_sha && head_sha[0], method]);
  assert.deepEqual(brief, [
    ['a', '1', 'enable', '1', 'merge'],
    ['b', '2', 'refused', undefined, undefined],
    ['c', '3', 'success', undefined, undefined],
    ['d', '4', 'closed', undefined, undefined],
    ['f', '6', 'refused', undefined, undefined],
    ['h', '8', 'enable', '8', 'merge'],
    ['i', '9', 'failure', undefined, undefined],
    ['j', '10', 'refused', undefined, undefined],
  ]);
  assert.match(plan[1].reason, /changes more than packages/);
  assert.equal(plan[4].reason, 'PR is a draft');
  assert.equal(plan[0].base, 'master');
  assert.match(plan[6].reason, /^lookup failed: 503/);
  assert.match(plan[7].reason, /300 or more files/);
  // Looked up by this repository's branch into the default branch, open
  // first; the reviewed group is not looked up at all.
  const looked = groups.filter(g => !g.review).map(g => `omacom:${g.branch}`);
  assert.deepEqual([...new Set(calls.map(call => call.head))], looked);
  assert.ok(calls.every(call => call.base === 'master'));
  assert.deepEqual(calls.filter(call => call.head === 'omacom:auto/sync-upstream-c').map(call => call.state), ['open', 'closed']);
});

test('close-superseded closes only superseded PRs and guards against errors and concurrent pushes', () => {
  const { execFileSync } = require('node:child_process');
  const { mkdtempSync, mkdirSync, writeFileSync, chmodSync, readFileSync: read, rmSync } = require('node:fs');
  const { tmpdir } = require('node:os');
  const prs = read(join(__dirname, '../.github/workflows/package-prs.yml'), 'utf8');
  const stepStart = prs.indexOf('- name: Close superseded PRs\n');
  assert.ok(stepStart > 0);
  const runMarker = '        run: |\n';
  const runStart = prs.indexOf(runMarker, stepStart);
  assert.ok(runStart > 0);
  const script = prs.slice(runStart + runMarker.length)
    .split('\n')
    .map(l => l.startsWith('          ') ? l.slice(10) : l)
    .join('\n');

  const root = mkdtempSync(join(tmpdir(), 'close-superseded-'));
  try {
    const remote = join(root, 'remote.git');
    const work = join(root, 'work');
    const bin = join(root, 'bin');
    const closedLog = join(root, 'closed.log');
    mkdirSync(bin);
    const git = (cwd, args) => execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' },
    }).trim();

    git(root, ['init', '--bare', '-b', 'master', remote]);
    git(root, ['clone', remote, work]);
    writeFileSync(join(work, 'a.txt'), 'v1\n');
    writeFileSync(join(work, 'b.txt'), 'v1\n');
    writeFileSync(join(work, 'c.txt'), 'v1\n');
    git(work, ['add', '.']);
    git(work, ['commit', '-m', 'base']);
    git(work, ['push', 'origin', 'master']);

    const makeBranch = (name, file, content) => {
      git(work, ['checkout', '-b', name, 'origin/master']);
      writeFileSync(join(work, file), content);
      git(work, ['add', file]);
      git(work, ['commit', '-m', name]);
      const sha = git(work, ['rev-parse', 'HEAD']);
      git(work, ['push', 'origin', name]);
      return sha;
    };

    const shaLanded = makeBranch('auto/sync-upstream-landed', 'a.txt', 'v2\n');
    const shaValid = makeBranch('auto/sync-upstream-valid', 'b.txt', 'v2\n');
    const shaConflict = makeBranch('auto/sync-upstream-conflict', 'c.txt', 'branch-v2\n');
    const shaMoved = makeBranch('auto/sync-upstream-moved', 'a.txt', 'v2\n');
    const shaMergeErr = makeBranch('auto/sync-upstream-mergeerr', 'b.txt', 'v3\n');

    git(work, ['checkout', 'master']);
    writeFileSync(join(work, 'a.txt'), 'v2\n');
    writeFileSync(join(work, 'c.txt'), 'master-v2\n');
    git(work, ['add', 'a.txt', 'c.txt']);
    git(work, ['commit', '-m', 'master moves on']);
    git(work, ['push', 'origin', 'master']);

    const sameRepo = { nameWithOwner: 'omacom/omarchy-pkgs' };
    const nodes = [
      { number: 10, headRefName: 'auto/sync-upstream-landed', baseRefName: 'master', headRefOid: shaLanded, mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 11, headRefName: 'auto/sync-upstream-valid', baseRefName: 'master', headRefOid: shaValid, mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 12, headRefName: 'auto/sync-upstream-conflict', baseRefName: 'master', headRefOid: shaConflict, mergeable: 'UNKNOWN', headRepository: sameRepo },
      { number: 13, headRefName: 'auto/sync-upstream-moved', baseRefName: 'master', headRefOid: shaMoved, mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 14, headRefName: 'auto/sync-upstream-fetcherr', baseRefName: 'master', headRefOid: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef', mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 15, headRefName: 'auto/sync-upstream-mergeerr', baseRefName: 'master', headRefOid: shaMergeErr, mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 16, headRefName: 'auto/sync-upstream', baseRefName: 'master', headRefOid: shaLanded, mergeable: 'CONFLICTING', headRepository: { nameWithOwner: 'fork/omarchy-pkgs' } },
    ];
    writeFileSync(join(root, 'nodes.json'), JSON.stringify({ data: { repository: { pullRequests: { nodes } } } }));

    // Wrap git to inject a status-128 merge-tree error for shaMergeErr only.
    const realGit = execFileSync('which', ['git'], { encoding: 'utf8' }).trim();
    const gitStub = `#!/bin/bash
if [[ "$1" == "merge-tree" ]]; then
  if [[ "$("${realGit}" rev-parse FETCH_HEAD 2>/dev/null || true)" == "${shaMergeErr}" ]]; then
    exit 128
  fi
fi
exec "${realGit}" "$@"
`;
    writeFileSync(join(bin, 'git'), gitStub);
    chmodSync(join(bin, 'git'), 0o755);

    const ghStub = `#!/bin/bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  jq_expr=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--jq" ]]; then jq_expr="$2"; shift 2; else shift; fi
  done
  jq -r "$jq_expr" "${join(root, 'nodes.json')}"
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
  num="$3"
  case "$num" in
    10) echo "OPEN master ${shaLanded}" ;;
    11) echo "OPEN master ${shaValid}" ;;
    12) echo "OPEN master ${shaConflict}" ;;
    13) echo "OPEN master 1111111111111111111111111111111111111111" ;;
    14) echo "OPEN master deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" ;;
    15) echo "OPEN master ${shaMergeErr}" ;;
  esac
elif [[ "$1" == "pr" && "$2" == "close" ]]; then
  echo "$3" >> "${closedLog}"
fi
`;
    writeFileSync(join(bin, 'gh'), ghStub);
    chmodSync(join(bin, 'gh'), 0o755);

    execFileSync('bash', ['-euo', 'pipefail', '-c', script], {
      cwd: work,
      env: {
        ...process.env,
        PATH: `${bin}:${process.env.PATH}`,
        GITHUB_REPOSITORY: 'omacom/omarchy-pkgs',
        GROUPS_JSON: '[]',
        PREFIX: 'auto/sync-upstream',
        DEFAULT_BRANCH: 'master',
      },
    });

    const closed = read(closedLog, 'utf8').trim().split('\n').filter(Boolean);
    assert.deepEqual(closed, ['10', '12']);
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('close-superseded isolates five-minute and hourly prefixes so neither closes the other\x27s PRs', () => {
  const { execFileSync } = require('node:child_process');
  const { mkdtempSync, mkdirSync, writeFileSync, chmodSync, readFileSync: read, existsSync: exists, rmSync } = require('node:fs');
  const { tmpdir } = require('node:os');
  const prs = read(join(__dirname, '../.github/workflows/package-prs.yml'), 'utf8');
  const stepStart = prs.indexOf('- name: Close superseded PRs\n');
  assert.ok(stepStart > 0);
  const runMarker = '        run: |\n';
  const runStart = prs.indexOf(runMarker, stepStart);
  assert.ok(runStart > 0);
  const script = prs.slice(runStart + runMarker.length)
    .split('\n')
    .map(l => l.startsWith('          ') ? l.slice(10) : l)
    .join('\n');

  const root = mkdtempSync(join(tmpdir(), 'close-superseded-scope-'));
  try {
    const remote = join(root, 'remote.git');
    const work = join(root, 'work');
    const bin = join(root, 'bin');
    mkdirSync(bin);
    const git = (cwd, args) => execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' },
    }).trim();

    git(root, ['init', '--bare', '-b', 'master', remote]);
    git(root, ['clone', remote, work]);
    writeFileSync(join(work, 'dev.txt'), 'v1\n');
    writeFileSync(join(work, 'hourly.txt'), 'v1\n');
    git(work, ['add', '.']);
    git(work, ['commit', '-m', 'base']);
    git(work, ['push', 'origin', 'master']);

    const makeBranch = (name, file, content) => {
      git(work, ['checkout', '-b', name, 'origin/master']);
      writeFileSync(join(work, file), content);
      git(work, ['add', file]);
      git(work, ['commit', '-m', name]);
      const sha = git(work, ['rev-parse', 'HEAD']);
      git(work, ['push', 'origin', name]);
      return sha;
    };

    const shaFiveMinConflict = makeBranch('auto/sync-five-minute-omarchy-dev-omarchy-settings-dev', 'dev.txt', 'pr-v2\n');
    const shaLegacyFiveMinLanded = makeBranch('auto/track-branches-omarchy-dev-omarchy-settings-dev', 'dev.txt', 'master-v2\n');
    const shaLegacyFiveMinPending = makeBranch('auto/track-branches-legacy-pending', 'pending.txt', 'pending-v1\n');
    const shaHourlyConflict = makeBranch('auto/track-branches-perplexity', 'hourly.txt', 'pr-v2\n');
    const shaHourlyLanded = makeBranch('auto/track-branches-rawmakase-bin', 'hourly.txt', 'master-v2\n');
    const shaSixHourlyConflict = makeBranch('auto/sync-upstream-zed', 'hourly.txt', 'pr-v2\n');

    git(work, ['checkout', 'master']);
    writeFileSync(join(work, 'dev.txt'), 'master-v2\n');
    writeFileSync(join(work, 'hourly.txt'), 'master-v2\n');
    git(work, ['add', '.']);
    git(work, ['commit', '-m', 'master advances']);
    git(work, ['push', 'origin', 'master']);

    const sameRepo = { nameWithOwner: 'omacom/omarchy-pkgs' };
    const nodes = [
      { number: 201, headRefName: 'auto/sync-five-minute-omarchy-dev-omarchy-settings-dev', baseRefName: 'master', headRefOid: shaFiveMinConflict, mergeable: 'CONFLICTING', headRepository: sameRepo },
      { number: 202, headRefName: 'auto/track-branches-perplexity', baseRefName: 'master', headRefOid: shaHourlyConflict, mergeable: 'CONFLICTING', headRepository: sameRepo },
      { number: 203, headRefName: 'auto/track-branches-rawmakase-bin', baseRefName: 'master', headRefOid: shaHourlyLanded, mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 204, headRefName: 'auto/track-branches', baseRefName: 'master', headRefOid: shaHourlyConflict, mergeable: 'CONFLICTING', headRepository: sameRepo },
      { number: 205, headRefName: 'auto/sync-upstream-zed', baseRefName: 'master', headRefOid: shaSixHourlyConflict, mergeable: 'CONFLICTING', headRepository: sameRepo },
      { number: 206, headRefName: 'auto/track-branches-omarchy-dev-omarchy-settings-dev', baseRefName: 'master', headRefOid: shaLegacyFiveMinLanded, mergeable: 'MERGEABLE', headRepository: sameRepo },
      { number: 207, headRefName: 'auto/track-branches-legacy-pending', baseRefName: 'master', headRefOid: shaLegacyFiveMinPending, mergeable: 'MERGEABLE', headRepository: sameRepo },
    ];
    writeFileSync(join(root, 'nodes.json'), JSON.stringify({ data: { repository: { pullRequests: { nodes } } } }));

    let runIndex = 0;
    const runWithPrefix = (prefix, groupsJson = '[]') => {
      const closedLog = join(root, `closed-${++runIndex}.log`);
      const ghStub = `#!/bin/bash
set -euo pipefail
if [[ "$1" == "api" && "$2" == "graphql" ]]; then
  jq_expr=""
  while [[ $# -gt 0 ]]; do
    if [[ "$1" == "--jq" ]]; then jq_expr="$2"; shift 2; else shift; fi
  done
  jq -r "$jq_expr" "${join(root, 'nodes.json')}"
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
  case "$3" in
    201) echo "OPEN master ${shaFiveMinConflict}" ;;
    202) echo "OPEN master ${shaHourlyConflict}" ;;
    203) echo "OPEN master ${shaHourlyLanded}" ;;
    204) echo "OPEN master ${shaHourlyConflict}" ;;
    205) echo "OPEN master ${shaSixHourlyConflict}" ;;
    206) echo "OPEN master ${shaLegacyFiveMinLanded}" ;;
    207) echo "OPEN master ${shaLegacyFiveMinPending}" ;;
  esac
elif [[ "$1" == "pr" && "$2" == "close" ]]; then
  echo "$3" >> "${closedLog}"
fi
`;
      writeFileSync(join(bin, 'gh'), ghStub);
      chmodSync(join(bin, 'gh'), 0o755);
      execFileSync('bash', ['-euo', 'pipefail', '-c', script], {
        cwd: work,
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          GITHUB_REPOSITORY: 'omacom/omarchy-pkgs',
          GROUPS_JSON: groupsJson,
          PREFIX: prefix,
          DEFAULT_BRANCH: 'master',
        },
      });
      return exists(closedLog) ? read(closedLog, 'utf8').trim().split('\n').filter(Boolean) : [];
    };

    // Five-minute run with no updates closes ONLY five-minute PR #201; never hourly #202/#203/#204 or six-hourly #205.
    assert.deepEqual(runWithPrefix('auto/sync-five-minute'), ['201']);
    // Hourly run with no updates closes hourly PRs #202/#203/#204 plus any already-landed legacy
    // auto/track-branches-omarchy-dev-omarchy-settings-dev PR #206, never five-minute #201 or six-hourly #205.
    assert.deepEqual(runWithPrefix('auto/track-branches'), ['202', '203', '204', '206']);
    // A refreshed PR in GROUPS_JSON is never closed even under its own prefix.
    assert.deepEqual(
      runWithPrefix('auto/sync-five-minute', JSON.stringify([{ branch: 'auto/sync-five-minute-omarchy-dev-omarchy-settings-dev', packages: 'omarchy-dev omarchy-settings-dev' }])),
      [],
    );
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('check-shadowed runs on every PR without paths filter and narrows full-tree helper triggers', () => {
  const wf = readFileSync(join(__dirname, '../.github/workflows/check-shadowed.yml'), 'utf8');
  const onBlock = wf.split('\njobs:\n')[0];
  assert.doesNotMatch(onBlock, /^ +paths:/m);
  assert.match(wf, /helpers\/message-helpers\.sh helpers\/paths\.sh helpers\/package-metadata\.sh/);
  assert.doesNotMatch(wf, /release\/shadowed-packages\.txt helpers /);
});
test('publish.yml renders PR comments as Markdown tables for sources and slots', () => {
  const { execFileSync } = require('node:child_process');
  const wf = readFileSync(join(__dirname, '../.github/workflows/publish.yml'), 'utf8');
  const start = wf.indexOf('      - name: Render\n');
  assert.ok(start > 0);
  const marker = "jq -r --arg outcome \"${{ needs.publish.result }}\" '\n";
  const jqStart = wf.indexOf(marker, start);
  assert.ok(jqStart > 0);
  const jqEnd = wf.indexOf("\n          ' publish-record.json > comment.md", jqStart);
  assert.ok(jqEnd > jqStart);
  const filter = wf.slice(jqStart + marker.length, jqEnd).replaceAll("'\"'\"'", "'");

  const render = (record, outcome = 'success') =>
    execFileSync('jq', ['-r', '--arg', 'outcome', outcome, filter], {
      input: JSON.stringify(record),
      encoding: 'utf8',
    });

  // 1. All skipped: groups identical-status arches onto one row
  const skipped = render({
    target: 'live', commit: '86c5371abcdef', run: 'https://example.test/run/1',
    plan: [], slots: [],
    sources: [
      { package: 'amp-desktop-bin', arch: 'x86_64', source: 'already-published' },
      { package: 'amp-desktop-bin', arch: 'aarch64', source: 'already-published' },
      { package: 'bambustudio-bin', arch: 'x86_64', source: 'already-published' },
    ],
  });
  assert.match(skipped, /\| Package \| Arch \| Status \|/);
  assert.match(skipped, /\| `amp-desktop-bin` \| `aarch64`, `x86_64` \| already published \(skipped\) \|/);
  assert.match(skipped, /_Nothing to publish: already at master's version everywhere\._/);

  // 2. Published with mixed statuses + slots table
  const published = render({
    target: 'live', commit: '1234567abcdef', run: 'https://example.test/run/2',
    plan: [{ package: 'notion-desktop', arch: 'x86_64', channels: 'edge', publish_arches: 'x86_64' }],
    sources: [
      { package: 'notion-desktop', arch: 'x86_64', source: 'pr-artifact' },
      { package: 'notion-desktop', arch: 'aarch64', source: 'rebuild' },
    ],
    slots: [
      { mirror: 'edge', arch: 'x86_64', status: 'published', packages: ['notion-desktop-7.45.2-2-x86_64.pkg.tar.zst', 'notion-desktop-debug-7.45.2-2-x86_64.pkg.tar.zst'] },
    ],
  });
  assert.match(published, /\| `notion-desktop` \| `x86_64` \| PR artifact \|/);
  assert.match(published, /\| `notion-desktop` \| `aarch64` \| rebuilt at merge \|/);
  assert.match(published, /\| Channel \| Status \| Packages \|/);
  assert.match(published, /\| `edge\/x86_64` \| published \| `notion-desktop-7\.45\.2-2-x86_64\.pkg\.tar\.zst` \|/);
  assert.doesNotMatch(published, /-debug-/);

  // 3. Failure state
  const failed = render({
    target: 'live', commit: '9999999abcdef', run: 'https://example.test/run/3',
    plan: [], slots: [],
    sources: [{ package: 'foo', arch: 'x86_64', source: 'build-failed' }],
  }, 'failure');
  assert.match(failed, /### Publish FAILED → \*\*live\*\*/);
  assert.match(failed, /\| `foo` \| `x86_64` \| \*\*build-failed\*\* \|/);
  assert.match(failed, /_A build failed, so no channel was touched\._/);
});

test('should-push-pr.sh skips unchanged PRs and human WIP fixes while refreshing real updates and conflicts', () => {
  const { execFileSync } = require('node:child_process');
  const { mkdtempSync, mkdirSync, writeFileSync, chmodSync, rmSync } = require('node:fs');
  const { tmpdir } = require('node:os');
  const script = join(__dirname, '../.github/scripts/should-push-pr.sh');

  // Verify package-prs.yml wires the step with the App token and gates hold/pr on push == true.
  const prs = readFileSync(join(__dirname, '../.github/workflows/package-prs.yml'), 'utf8');
  assert.match(prs, /- name: Check whether the PR needs an update\n +id: should_push\n/);
  assert.match(prs, /\.github\/scripts\/should-push-pr\.sh "\$BRANCH" "\$\{packages\[@\]\}"/);
  assert.match(prs, /steps\.should_push\.outputs\.push == 'true' && matrix\.group\.review == true/);
  assert.match(prs, /steps\.should_push\.outputs\.push == 'true' && steps\.hold\.outcome != 'failure'/);

  const root = mkdtempSync(join(tmpdir(), 'should-push-'));
  try {
    const remote = join(root, 'remote.git');
    const work = join(root, 'work');
    const bin = join(root, 'bin');
    mkdirSync(bin);
    const git = (cwd, args) => execFileSync('git', args, {
      cwd,
      encoding: 'utf8',
      env: { ...process.env, GIT_AUTHOR_NAME: 't', GIT_AUTHOR_EMAIL: 't@t', GIT_COMMITTER_NAME: 't', GIT_COMMITTER_EMAIL: 't@t' },
    }).trim();

    git(root, ['init', '--bare', '-b', 'master', remote]);
    git(root, ['clone', remote, work]);
    mkdirSync(join(work, 'pkgbuilds/demo/.omarchy'), { recursive: true });
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=1.0\npkgrel=1\n');
    writeFileSync(join(work, 'pkgbuilds/demo/.omarchy/package.json'), '{"source":"local"}\n');
    git(work, ['add', '.']);
    git(work, ['commit', '-m', 'base']);
    git(work, ['push', 'origin', 'master']);

    // Create existing bot PR branch with pkgver=2.0
    git(work, ['checkout', '-b', 'auto/sync-upstream-demo', 'origin/master']);
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=2.0\npkgrel=1\n_build=1\n');
    git(work, ['add', '.']);
    git(work, ['commit', '-m', 'bot bump 2.0']);
    const botOid = git(work, ['rev-parse', 'HEAD']);
    git(work, ['push', 'origin', 'auto/sync-upstream-demo']);

    // Create branch with human WIP fix commit on top of bot commit at pkgver=2.0
    git(work, ['checkout', '-b', 'auto/sync-upstream-human', 'auto/sync-upstream-demo']);
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=2.0\npkgrel=1\n_build=1\n# human fix\n');
    git(work, ['add', '.']);
    git(work, ['commit', '-m', 'human fix']);
    git(work, ['push', 'origin', 'auto/sync-upstream-human']);

    // Return to master and apply sync output (pkgver=2.0, _build=1) to working tree
    git(work, ['checkout', 'master']);
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=2.0\npkgrel=1\n_build=1\n');

    const recentDate = new Date(Date.now() - 3600 * 1000).toISOString();
    const staleDate = new Date(Date.now() - 8 * 86400 * 1000).toISOString();

    const ghStub = `#!/bin/bash
set -euo pipefail
if [[ "$1" == "api" ]]; then
  if [[ "$STUB_PR" == "" ]]; then echo ""; else echo "$STUB_PR"; fi
elif [[ "$1" == "pr" && "$2" == "view" ]]; then
  printf "%s|%s|%s|%s|%s|%s|%s\n" "$STUB_MERGEABLE" "$STUB_COMMITS" "$STUB_FIRST_OID" "$STUB_TIP_OID" "$STUB_AUTHOR" "$STUB_DATE" "$STUB_CHECKS"
fi
`;
    writeFileSync(join(bin, 'gh'), ghStub);
    chmodSync(join(bin, 'gh'), 0o755);

    const run = (branch, env) => {
      const out = execFileSync('bash', [script, branch, 'demo'], {
        cwd: work,
        encoding: 'utf8',
        env: {
          ...process.env,
          PATH: `${bin}:${process.env.PATH}`,
          GITHUB_REPOSITORY: 'omacom/omarchy-pkgs',
          DEFAULT_BRANCH: 'master',
          STUB_FIRST_OID: botOid,
          STUB_TIP_OID: botOid,
          STUB_DATE: recentDate,
          STUB_CHECKS: 'SETTLED',
          ...env,
        },
      });
      return Object.fromEntries(out.trim().split('\n').map(l => l.split('=')));
    };

    // 1. No open PR -> push=true (new)
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '', STUB_MERGEABLE: '', STUB_COMMITS: '0', STUB_AUTHOR: '' }),
      { push: 'true', pr: '', reason: 'new' });

    // 2. Open PR with identical package files and settled checks -> push=false (unchanged)
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync' }),
      { push: 'false', pr: '42', reason: 'unchanged' });

    // 3. Transient check failure or missing checks -> push=true (transient-check)
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync', STUB_CHECKS: 'TRANSIENT' }),
      { push: 'true', pr: '42', reason: 'transient-check' });
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync', STUB_CHECKS: 'NONE' }),
      { push: 'true', pr: '42', reason: 'transient-check' });

    // 4. Stale PR (>= 7 days old) -> push=true (stale-retry)
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync', STUB_DATE: staleDate }),
      { push: 'true', pr: '42', reason: 'stale-retry' });

    // 4b. Empty commit author login does not shift date or check_state fields
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: '', STUB_CHECKS: 'TRANSIENT' }),
      { push: 'true', pr: '42', reason: 'transient-check' });
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: '', STUB_DATE: staleDate, STUB_CHECKS: 'SETTLED' }),
      { push: 'true', pr: '42', reason: 'stale-retry' });

    // 5. Conflicting bot PR -> push=true (conflict)
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'CONFLICTING', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync' }),
      { push: 'true', pr: '42', reason: 'conflict' });

    // 6. Human WIP fix pushed onto branch (even if conflicting) while bot's base commit matches -> push=false (human-commit)
    assert.deepEqual(run('auto/sync-upstream-human', { STUB_PR: '43', STUB_MERGEABLE: 'CONFLICTING', STUB_COMMITS: '2', STUB_AUTHOR: 'emirb' }),
      { push: 'false', pr: '43', reason: 'human-commit' });

    // 6b. Maintainer commit with unlinked git email (empty login) or unfetchable base commit still protects the branch
    assert.deepEqual(run('auto/sync-upstream-human', { STUB_PR: '43', STUB_MERGEABLE: 'CONFLICTING', STUB_COMMITS: '2', STUB_AUTHOR: '' }),
      { push: 'false', pr: '43', reason: 'human-commit' });
    assert.deepEqual(run('auto/sync-upstream-human', { STUB_PR: '43', STUB_MERGEABLE: 'CONFLICTING', STUB_COMMITS: '2', STUB_AUTHOR: 'emirb', STUB_FIRST_OID: 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef' }),
      { push: 'false', pr: '43', reason: 'human-commit' });

    // 6c. New untracked file under pkgbuilds/<pkg>/ counts as an update when absent on PR,
    // and as unchanged when the PR branch already committed that exact file.
    writeFileSync(join(work, 'pkgbuilds/demo/new.patch'), 'diff\n');
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync' }),
      { push: 'true', pr: '42', reason: 'updated' });
    git(work, ['checkout', '--', 'pkgbuilds/demo/PKGBUILD']);
    git(work, ['checkout', '-b', 'auto/sync-upstream-added', 'auto/sync-upstream-demo']);
    git(work, ['add', 'pkgbuilds/demo/new.patch']);
    git(work, ['commit', '-m', 'bot adds new.patch']);
    const addedOid = git(work, ['rev-parse', 'HEAD']);
    git(work, ['push', 'origin', 'auto/sync-upstream-added']);
    git(work, ['checkout', 'master']);
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=2.0\npkgrel=1\n_build=1\n');
    writeFileSync(join(work, 'pkgbuilds/demo/new.patch'), 'diff\n');
    assert.deepEqual(run('auto/sync-upstream-added', { STUB_PR: '44', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_FIRST_OID: addedOid, STUB_TIP_OID: addedOid, STUB_AUTHOR: 'omarchy-pkgs-sync' }),
      { push: 'false', pr: '44', reason: 'unchanged' });
    rmSync(join(work, 'pkgbuilds/demo/new.patch'));

    // 7. Same pkgver but revision (_build) changed -> diff vs bot's first commit -> push=true (updated)
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=2.0\npkgrel=1\n_build=2\n');
    assert.deepEqual(run('auto/sync-upstream-human', { STUB_PR: '43', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '2', STUB_AUTHOR: 'emirb' }),
      { push: 'true', pr: '43', reason: 'updated' });

    // 8. Master recipe fix changes pkgbuilds/demo/PKGBUILD -> diff vs FETCH_HEAD -> push=true (updated)
    writeFileSync(join(work, 'pkgbuilds/demo/PKGBUILD'), 'pkgname=demo\npkgver=2.0\npkgrel=1\n_build=1\ndepends=(gtk4-layer-shell)\n');
    assert.deepEqual(run('auto/sync-upstream-demo', { STUB_PR: '42', STUB_MERGEABLE: 'MERGEABLE', STUB_COMMITS: '1', STUB_AUTHOR: 'omarchy-pkgs-sync' }),
      { push: 'true', pr: '42', reason: 'updated' });
  } finally {
    rmSync(root, { recursive: true, force: true });
  }
});

test('package-prs.yml and callers grant checks/statuses read permissions for should-push-pr.sh', () => {
  const pprs = readFileSync(join(__dirname, '../.github/workflows/package-prs.yml'), 'utf8');
  assert.match(pprs, /name: Check whether the PR needs an update[\s\S]*?GH_TOKEN: \$\{\{ github\.token \}\}/);
  for (const file of ['package-prs.yml', 'sync-upstream.yml', 'sync-rebuilds.yml']) {
    const wf = readFileSync(join(__dirname, '../.github/workflows', file), 'utf8');
    assert.match(wf, /checks: read/);
    assert.match(wf, /statuses: read/);
    assert.match(wf, /pull-requests: read/);
  }
});
