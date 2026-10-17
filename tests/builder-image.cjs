const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { chmodSync, cpSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, utimesSync, writeFileSync } = require('node:fs');
const { tmpdir } = require('node:os');
const { join } = require('node:path');
const { test } = require('node:test');

const root = join(__dirname, '..');
const workflow = readFileSync(join(root, '.github/workflows/builder-images.yml'), 'utf8');

function fixture(t) {
  const directory = mkdtempSync(join(tmpdir(), 'builder-image-test-'));
  t.after(() => rmSync(directory, { recursive: true, force: true }));
  mkdirSync(join(directory, 'bin'));
  mkdirSync(join(directory, 'build'));
  cpSync(join(root, 'helpers'), join(directory, 'helpers'), { recursive: true });
  cpSync(join(root, 'bin/builder-image'), join(directory, 'bin/builder-image'));
  writeFileSync(join(directory, 'build/Dockerfile'), 'FROM scratch\nCOPY input /input\n');
  writeFileSync(join(directory, 'build/input'), 'original input\n');
  const engine = join(directory, 'engine');
  mkdirSync(engine);
  const log = join(directory, 'engine.jsonl');
  writeFileSync(join(engine, 'docker'), `#!/usr/bin/env node
const fs = require('node:fs');
const args = process.argv.slice(2);
fs.appendFileSync(process.env.ENGINE_LOG, JSON.stringify(args) + '\\n');
if (args[0] === 'manifest' && process.env.PRIVATE_IMAGE === '1') process.exit(1);
if (args[0] === 'push' && process.env.PUSH_FAIL === '1') process.exit(1);
if (args[0] === 'image' && args[1] === 'inspect') console.log('ghcr.io/omacom/omarchy-pkg-builder@sha256:' + 'a'.repeat(64));
`);
  chmodSync(join(engine, 'docker'), 0o755);
  const env = {
    ...process.env, PATH: `${engine}:${process.env.PATH}`, CONTAINER_ENGINE: 'docker',
    ENGINE_LOG: log, ARCH: 'x86_64', MIRROR: 'edge',
  };
  const run = (args, extraEnv = {}) => spawnSync(join(directory, 'bin/builder-image'), args, {
    cwd: directory, env: { ...env, ...extraEnv }, encoding: 'utf8',
  });
  const key = (...args) => {
    const result = run(['key', ...args]);
    assert.equal(result.status, 0, result.stderr);
    return result.stdout.trim();
  };
  const calls = () => readFileSync(log, 'utf8').trim().split('\n').filter(Boolean).map(JSON.parse);
  return { directory, env, run, key, calls };
}

test('image keys are stable across checkout location and timestamp changes', t => {
  const a = fixture(t);
  const b = fixture(t);
  const key = a.key();
  assert.match(key, /^v1-x86_64-edge-[a-f0-9]{64}$/);
  utimesSync(join(b.directory, 'build/input'), new Date(0), new Date(0));
  assert.equal(b.key(), key);
});

test('image keys separate architectures, mirrors, content, modes and symlink targets', t => {
  const f = fixture(t);
  const keys = new Set([f.key(), f.key('--arch', 'aarch64'), f.key('--mirror', 'rc'), f.key('--mirror', 'stable')]);
  writeFileSync(join(f.directory, 'build/input'), 'new input\n');
  keys.add(f.key());
  chmodSync(join(f.directory, 'build/input'), 0o755);
  keys.add(f.key());
  symlinkSync('input', join(f.directory, 'build/link'));
  keys.add(f.key());
  rmSync(join(f.directory, 'build/link'));
  symlinkSync('Dockerfile', join(f.directory, 'build/link'));
  keys.add(f.key());
  assert.equal(keys.size, 8);
  mkdirSync(join(f.directory, 'pkgbuilds/example'), { recursive: true });
  const key = f.key();
  writeFileSync(join(f.directory, 'pkgbuilds/example/PKGBUILD'), 'pkgver=2\n');
  assert.equal(f.key(), key, 'package changes must not invalidate the build environment');
});

test('fresh builds refresh package layers and record their compatibility key', t => {
  const f = fixture(t);
  const key = f.key('--arch', 'aarch64');
  const result = f.run(['build', '--arch', 'aarch64', '--tag', 'candidate:test', '--fresh']);
  assert.equal(result.status, 0, result.stderr);
  const build = f.calls().find(args => args[0] === 'buildx');
  assert.ok(build.includes('--no-cache'));
  assert.ok(build.includes('--pull'));
  assert.ok(build.includes('--load'));
  assert.ok(build.includes('--platform=linux/arm64'));
  assert.ok(build.includes(`org.omarchy.builder.key=${key}`));
  assert.ok(build.includes('candidate:test'));
});

test('invalid targets fail before starting an image build', t => {
  const f = fixture(t);
  for (const args of [['key', '--arch', 'invalid'], ['build', '--mirror', 'invalid'], ['key', '--fresh']]) {
    assert.notEqual(f.run(args).status, 0);
  }
});

function publish(f, extraEnv = {}) {
  const script = workflow.split('      - name: Publish tested image\n')[1].split('        run: |\n')[1]
    .replaceAll('${{ matrix.arch }}', 'x86_64');
  return spawnSync('bash', ['-e', '-o', 'pipefail', '-c', script], {
    cwd: f.directory, encoding: 'utf8', env: {
      ...f.env, REGISTRY_IMAGE: 'ghcr.io/omacom/omarchy-pkg-builder', CANDIDATE_IMAGE: 'candidate:test',
      GH_TOKEN: 'fixture', GH_ACTOR: 'fixture', DOCKER_CONFIG: join(f.directory, 'auth'),
      RUNNER_TEMP: f.directory, GITHUB_RUN_ID: '123', GITHUB_RUN_ATTEMPT: '1',
      GITHUB_STEP_SUMMARY: join(f.directory, 'summary'), ...extraEnv,
    },
  });
}

test('a public tested image gets a version tag before the compatible-image tag advances', t => {
  const f = fixture(t);
  const key = f.key();
  const result = publish(f);
  assert.equal(result.status, 0, result.stderr);
  const calls = f.calls();
  assert.deepEqual(calls.filter(args => args[0] === 'push').map(args => args[1]), [
    `ghcr.io/omacom/omarchy-pkg-builder:${key}-123-1`, `ghcr.io/omacom/omarchy-pkg-builder:${key}`,
  ]);
  assert.ok(calls.findIndex(args => args[0] === 'manifest') < calls.findLastIndex(args => args[0] === 'push'));
});

test('a private image or failed push never replaces the previous compatible-image tag', t => {
  for (const extraEnv of [{ PRIVATE_IMAGE: '1' }, { PUSH_FAIL: '1' }]) {
    const f = fixture(t);
    const key = f.key();
    const result = publish(f, extraEnv);
    assert.notEqual(result.status, 0);
    assert.equal(f.calls().some(args => args[0] === 'push' && args[1] === `ghcr.io/omacom/omarchy-pkg-builder:${key}`), false);
  }
});
