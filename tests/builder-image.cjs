const assert = require('node:assert/strict');
const { spawnSync } = require('node:child_process');
const { chmodSync, cpSync, mkdirSync, mkdtempSync, readdirSync, readFileSync, rmSync, statSync, symlinkSync, utimesSync, writeFileSync } = require('node:fs');
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

test('image keys are stable across checkout location, timestamps and umask', t => {
  // The modes a umask 022 checkout gives, set explicitly: the fixtures are
  // created under this process's umask, and under 002 every fixture would
  // be group-writable and the umask check below would compare like with like.
  const umask022 = f => {
    chmodSync(join(f.directory, 'build'), 0o755);
    chmodSync(join(f.directory, 'build/Dockerfile'), 0o644);
    chmodSync(join(f.directory, 'build/input'), 0o644);
    return f;
  };
  const a = umask022(fixture(t));
  const b = umask022(fixture(t));
  const key = a.key();
  assert.match(key, /^v1-x86_64-edge-[a-f0-9]{64}$/);
  utimesSync(join(b.directory, 'build/input'), new Date(0), new Date(0));
  assert.equal(b.key(), key);
  // A umask 002 checkout (the droplet runners') makes files and directories
  // group-writable; only the executable bits belong in the key.
  const c = fixture(t);
  chmodSync(join(c.directory, 'build'), 0o775);
  chmodSync(join(c.directory, 'build/Dockerfile'), 0o664);
  chmodSync(join(c.directory, 'build/input'), 0o664);
  assert.equal(c.key(), key);
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

const KNOWN_SIG_TOKENS = new Set([
  'Required', 'PackageRequired', 'Optional', 'PackageOptional', 'Never', 'PackageNever',
  'TrustedOnly', 'PackageTrustedOnly', 'TrustAll', 'PackageTrustAll',
  'DatabaseRequired', 'DatabaseOptional', 'DatabaseNever', 'DatabaseTrustedOnly', 'DatabaseTrustAll',
]);

function isStrictPackageSigLevel(value) {
  let required = false;
  let trustAll = false;
  for (const tok of value.trim().split(/\s+/).filter(Boolean)) {
    if (!KNOWN_SIG_TOKENS.has(tok)) return false;
    if (tok === 'Required' || tok === 'PackageRequired') required = true;
    else if (tok === 'Optional' || tok === 'PackageOptional' || tok === 'Never' || tok === 'PackageNever') required = false;
    if (tok === 'TrustAll' || tok === 'PackageTrustAll') trustAll = true;
    else if (tok === 'TrustedOnly' || tok === 'PackageTrustedOnly') trustAll = false;
  }
  return required && !trustAll;
}

function parsePacmanSigLevels(text) {
  const logical = [];
  for (const [idx, raw] of text.split('\n').entries()) {
    if (/^\s*#/.test(raw)) continue;
    for (const part of raw.split('\\n')) logical.push({ line: idx + 1, text: part });
  }
  const entries = [];
  let section = null;
  for (let i = 0; i < logical.length; i++) {
    const sec = logical[i].text.match(/\[([A-Za-z0-9._-]+)\]\s*(?:#.*)?$/);
    if (sec) { section = sec[1]; continue; }
    const sig = logical[i].text.match(/(?<![A-Za-z0-9_])SigLevel\s*=\s*([^\n'"\\;#]+)/i);
    if (!sig) continue;
    const servers = [];
    for (const dir of [-1, 1]) {
      for (let j = i + dir; j >= 0 && j < logical.length; j += dir) {
        const line = logical[j].text.trim();
        if (!line) continue;
        if (!/^[A-Za-z]+\s*=/.test(line)) break;
        const srv = line.match(/^(?:Server|CacheServer|Include)\s*=\s*([^\s'"\\;#]+)/);
        if (srv) servers.push(srv[1]);
      }
    }
    entries.push({ line: logical[i].line, section, value: sig[1].trim(), servers });
  }
  return entries;
}

function findWeakSigLevels(text, { allowFileRepos = false } = {}) {
  return parsePacmanSigLevels(text)
    .filter(e => !isStrictPackageSigLevel(e.value))
    .filter(e => !(allowFileRepos && e.servers.length > 0 && e.servers.every(u => u.startsWith('file://'))))
    .map(e => `line ${e.line} ([${e.section || 'unknown'}]): SigLevel = ${e.value}`);
}

test('SigLevel policy rejects Optional, Never, TrustAll, and overrides on remote repos', () => {
  for (const ok of ['Required DatabaseOptional', 'Required', 'PackageRequired DatabaseOptional']) {
    assert.equal(isStrictPackageSigLevel(ok), true, ok);
  }
  for (const weak of [
    'Optional', 'Never', 'TrustAll', 'Optional TrustAll', 'Required TrustAll',
    'Required PackageOptional', 'Required PackageNever', 'Required PackageTrustAll',
    'Required DatabaseOptional Optional', '$SIGLEVEL',
  ]) {
    assert.equal(isStrictPackageSigLevel(weak), false, weak);
  }

  const remoteWeak = "printf '\\n[omarchy]\\nSigLevel = Optional\\nServer = https://pkgs.omarchy.org/%s/x86_64\\n'";
  assert.equal(findWeakSigLevels(remoteWeak).length, 1);
  assert.equal(findWeakSigLevels(remoteWeak, { allowFileRepos: true }).length, 1);

  const localUnsigned = 'sed -i "/^\\[core\\]$/i [omarchy-build]\\nSigLevel = Never\\nServer = file://$BUILD_OUTPUT_DIR\\n"';
  assert.equal(findWeakSigLevels(localUnsigned).length, 1);
  assert.equal(findWeakSigLevels(localUnsigned, { allowFileRepos: true }).length, 0);

  const mixed = "[omarchy]\nSigLevel = Optional\nServer = file:///local\n\nServer = https://pkgs.omarchy.org/edge/x86_64\n";
  assert.equal(findWeakSigLevels(mixed, { allowFileRepos: true }).length, 1);

  const cacheRemote = "[omarchy]\nSigLevel = Never\nServer = file:///local\nCacheServer = https://pkgs.omarchy.org/edge/x86_64\n";
  assert.equal(findWeakSigLevels(cacheRemote, { allowFileRepos: true }).length, 1);

  const includeMirror = "[omarchy]\nSigLevel = Never\nServer = file:///local\nInclude = /etc/pacman.d/mirrorlist\n";
  assert.equal(findWeakSigLevels(includeMirror, { allowFileRepos: true }).length, 1);
});

test('build/Dockerfile and build/ scripts enforce strict package SigLevel for remote repos', () => {
  const buildDir = join(root, 'build');
  const dockerfile = readFileSync(join(buildDir, 'Dockerfile'), 'utf8');
  const omarchyLine = dockerfile.split('\n').find(l => l.includes('[omarchy]') && l.includes('>> /etc/pacman.conf'));
  assert.ok(omarchyLine, 'build/Dockerfile must append [omarchy] to /etc/pacman.conf');
  const omarchy = parsePacmanSigLevels(omarchyLine).find(e => e.section === 'omarchy');
  assert.equal(omarchy && omarchy.value, 'Required DatabaseOptional',
    `build/Dockerfile [omarchy] must set SigLevel = Required DatabaseOptional, got: ${omarchy && omarchy.value}`);

  for (const name of readdirSync(buildDir, { recursive: true }).sort()) {
    const fullPath = join(buildDir, name);
    if (!statSync(fullPath).isFile()) continue;
    const problems = findWeakSigLevels(readFileSync(fullPath, 'utf8'), { allowFileRepos: name !== 'Dockerfile' });
    assert.deepEqual(problems, [], `build/${name} has weak SigLevel for a non-file:// repo:\n  ${problems.join('\n  ')}`);
  }
});
