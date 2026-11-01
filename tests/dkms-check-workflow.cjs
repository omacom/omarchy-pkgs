// The DKMS check's shape on a pull request: one check written through the
// Checks API, never a job per kernel and module in the pull request's own
// workflows, and no job that can write running anything from the repository.
// workflow_run runs master's copy of dkms-check.yml after a pull request's
// build, and GitHub's guidance for it is that a job holding a write token
// must not check out or download what a pull request controls.
const assert = require('node:assert/strict');
const { readFileSync, readdirSync } = require('node:fs');
const { test } = require('node:test');

const dir = '.github/workflows';
const read = name => readFileSync(`${dir}/${name}`, 'utf8');

// Top-level trigger names under `on:`.
function triggers(workflow) {
  const on = workflow.split(/^on:\n/m)[1].split(/^\S/m)[0];
  return [...on.matchAll(/^  ([a-z_]+):/gm)].map(match => match[1]);
}

// Each job's text, by id.
function jobs(workflow) {
  const body = workflow.split(/^jobs:\n/m)[1];
  const parts = body.split(/^  (?=[a-z][a-z0-9_-]*:\n)/m).filter(Boolean);
  return Object.fromEntries(parts.map(part => [part.slice(0, part.indexOf(':')), part]));
}

test('no workflow a pull request triggers fans the DKMS check out into its checks', () => {
  for (const name of readdirSync(dir).filter(file => file.endsWith('.yml'))) {
    const workflow = read(name);
    if (!triggers(workflow).some(on => on === 'pull_request' || on === 'pull_request_target')) continue;
    assert.doesNotMatch(workflow, /uses: \.\/\.github\/workflows\/dkms-/, `${name} must not call the DKMS matrix`);
  }
  for (const name of ['dkms-check.yml', 'dkms-matrix.yml']) {
    assert.ok(!triggers(read(name)).some(on => on.startsWith('pull_request')), `${name} must not run on pull requests`);
  }
});

test('the pull request check is written by jobs that run nothing from the repository', () => {
  const all = jobs(read('dkms-check.yml'));
  const writers = Object.entries(all).filter(([, job]) => /^\s+(checks|contents|pull-requests|actions|packages|statuses): write$/m.test(job));
  assert.deepEqual(writers.map(([id]) => id).sort(), ['report', 'target']);
  for (const [id, job] of writers) {
    assert.doesNotMatch(job, /actions\/checkout|download-artifact|upload-artifact|actions\/cache/, `${id} must not check out or move artifacts`);
    assert.doesNotMatch(job, /\bbin\/|\bhelpers\/|\.\/|source /, `${id} must not run repository code`);
    // Values reach the script through env, never ${{ }} inside run:.
    const script = job.split(/^\s+run: \|\n/m)[1] ?? '';
    assert.doesNotMatch(script, /\$\{\{/, `${id}'s script must take its values from env`);
    assert.doesNotMatch(job, /secrets\./, `${id} must not use secrets`);
  }
  assert.match(all.target, /checks: write/);
  assert.match(all.report, /checks: write/);
});

test('the matrix only reads, and holds no secret', () => {
  const workflow = read('dkms-matrix.yml');
  assert.doesNotMatch(workflow, /: write$/m);
  assert.doesNotMatch(workflow, /secrets\./);
  for (const [id, job] of Object.entries(jobs(workflow))) {
    assert.match(job, /persist-credentials: false/, `${id} must not keep the token in its checkout`);
  }
});

test('a pull request build records what the DKMS check reads', () => {
  const build = read('build-pr.yml');
  const changes = jobs(build).changes;
  assert.match(changes, /name: dkms-request/);
  assert.match(changes, /trusted: \(\$trusted == "true"\), matrix: \$matrix, reused: \$reused/);
  assert.doesNotMatch(jobs(build).result, /dkms/, '`result` no longer waits for the DKMS check');
});

test('a build the check ignores, or one of an older commit, cannot cancel the head\'s check', () => {
  const workflow = read('dkms-check.yml');
  const group = workflow.split(/^concurrency:\n/m)[1].split(/^\S/m)[0];
  assert.match(group, /format\('sha-\{0\}', github\.event\.workflow_run\.head_sha\)/, 'pull request builds are keyed by commit');
  assert.match(group, /format\('ignored-\{0\}', github\.run_id\)/, 'ignored builds get a group of their own');
  assert.match(group, /github\.event\.workflow_run\.path == '\.github\/workflows\/build-pr\.yml'/,
    'a same-named workflow is ignored here as it is in target');
  assert.doesNotMatch(group, /head_branch/, 'never by branch, which an older commit shares');
});

test('a fork that changes build-pr.yml is refused, not checked on its own word', () => {
  const all = jobs(read('dkms-check.yml'));
  // Provenance from the build run, in every mode, through checked commands:
  // no pipeline whose failure reads as "not changed".
  assert.match(all.target, /build=\$\(gh api "repos\/\$GITHUB_REPOSITORY\/actions\/runs\/\$run"\)/);
  assert.match(all.target, /ours=\$\(blob "\$base"\)/);
  assert.match(all.target, /theirs=\$\(blob "\$sha"\)/);
  assert.match(all.target, /\$theirs != "\$ours"/);
  // Only a 404 means "missing"; any other error fails the job.
  assert.match(all.target, /elif \[\[ \$out == \*"\(HTTP 404\)"\* \]\]; then\n\s+echo missing\n\s+else\n[^\n]*\n\s+return 1/);
  assert.doesNotMatch(all.target, /\| *grep -q/, 'grep -q in a pipeline fails open under pipefail');
  assert.match(all.target, /refused: \$\{\{ steps\.open\.outputs\.refused \}\}/);
  assert.match(all.dkms, /needs\.target\.outputs\.refused == ''/, 'a refused pull request runs no legs');
  assert.match(all.report, /CONCLUSION=failure TITLE="Not checked"/, 'and its check fails');
});
