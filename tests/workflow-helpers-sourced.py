#!/usr/bin/env python3
# Workflow structural invariants:
# 1. A workflow step that calls a function from helpers/ sources that helper in
#    the same step. Each run: block is a fresh shell, so a function sourced in an
#    earlier step is gone: the Publish step of 3673f54c called plan_slots without
#    sourcing helpers/artifact-helpers.sh, and every publish failed.
# 2. release-rc.yml resolves refs/heads/rc once in a non-matrix pins job before
#    the multi-arch build matrix starts, archives the pinned recipe trees so
#    both arches unpack the exact same commit even if rc moves mid-run, and
#    propagates pin metadata and artifact names from pins rather than build.
# 3. build-pr.yml and publish.yml run: blocks bind github/inputs/matrix/env via env:, not ${{ }}.
import os, pathlib, re, shutil, subprocess, sys, tempfile, yaml

root = pathlib.Path(__file__).resolve().parent.parent
defined = {}
for helper in sorted((root / 'helpers').glob('*.sh')):
    # An executable helper is a script steps run, not a library they source.
    if helper.stat().st_mode & 0o111:
        continue
    for name in re.findall(r'^([a-z_][a-z0-9_]*)\(\) *\{', helper.read_text(), re.M):
        defined.setdefault(name, set()).add(f'helpers/{helper.name}')


def code(run):
    # Comment lines name functions without calling them.
    return '\n'.join(line for line in run.splitlines() if not line.lstrip().startswith('#'))


def as_list(val):
    return [] if val is None else ([val] if isinstance(val, str) else list(val))


def fetches_moving_rc(step):
    ref = str((step.get('with') or {}).get('ref') or '').strip()
    if ref in ('rc', 'refs/heads/rc', 'origin/rc'):
        return True
    return bool(re.search(r'\bgit\s+fetch\b[^\n]*\b(?:refs/heads/|origin/)?rc\b', code(step.get('run') or '')))


def tree_bytes(base, subdir):
    d = base / subdir
    return {p.relative_to(base).as_posix(): p.read_bytes() for p in sorted(d.rglob('*')) if p.is_file()} if d.is_dir() else {}


def check_release_rc_pins(repo_root):
    errs = []
    doc = yaml.safe_load((repo_root / '.github/workflows/release-rc.yml').read_text()) or {}
    jobs = doc.get('jobs') or {}
    pins, build, publish = jobs.get('pins') or {}, jobs.get('build') or {}, jobs.get('publish') or {}
    rc_expr, ver_expr = '${{ needs.pins.outputs.rc_commit }}', '${{ needs.pins.outputs.pkgver }}'

    # 1. Non-matrix pins job resolves refs/heads/rc once and exports commit + pkgver.
    if (pins.get('strategy') or {}).get('matrix'):
        errs.append('release-rc.yml: pins job must not use a matrix')
    pin_steps = pins.get('steps') or []
    co = next((s for s in pin_steps if (s.get('uses') or '').startswith('actions/checkout@') and (s.get('with') or {}).get('ref') == 'refs/heads/rc'), None)
    co_id = (co or {}).get('id')
    resolve = next((s for s in pin_steps if s.get('run') and 'git archive' in code(s['run'])), None)
    res_id = (resolve or {}).get('id')
    if not co_id or not res_id:
        errs.append('release-rc.yml: pins job must have an id-tagged refs/heads/rc checkout and an id-tagged archive resolver step')
    else:
        outs = pins.get('outputs') or {}
        if outs.get('rc_commit') != f'${{{{ steps.{co_id}.outputs.commit }}}}' or outs.get('pkgver') != f'${{{{ steps.{res_id}.outputs.pkgver }}}}':
            errs.append('release-rc.yml: pins.outputs must map rc_commit and pkgver from checkout/resolver steps')

    pin_up = next((s for s in pin_steps if (s.get('uses') or '').startswith('actions/upload-artifact@')), None)
    pin_up_with = (pin_up or {}).get('with') or {}
    pin_archive = str(pin_up_with.get('path') or '').strip()

    # 2. Multi-arch build matrix consumes the archived snapshot and never fetches moving rc.
    if 'pins' not in as_list(build.get('needs')):
        errs.append('release-rc.yml: build must need pins')
    if build.get('outputs'):
        errs.append('release-rc.yml: matrix job build must not export outputs')
    build_steps = build.get('steps') or []
    for i, step in enumerate(build_steps):
        if fetches_moving_rc(step):
            errs.append(f'release-rc.yml: build: "{step.get("name") or f"step {i + 1}"}" fetches moving rc ref inside matrix')
    pin_dl = next((s for s in build_steps if (s.get('uses') or '').startswith('actions/download-artifact@')), None)
    pin_dl_with = (pin_dl or {}).get('with') or {}
    pin_dl_dir = str(pin_dl_with.get('path') or '').strip()
    if not co_id or pin_up_with.get('name') != f'rc-pins-${{{{ steps.{co_id}.outputs.commit }}}}' or pin_dl_with.get('name') != f'rc-pins-{rc_expr}' or not pin_archive or not pin_dl_dir:
        errs.append('release-rc.yml: pins upload and build download must share matching rc-pins-<sha> artifact names and paths')

    pin_take = next((s for s in build_steps if (s.get('env') or {}).get('RC_COMMIT') == rc_expr and s.get('run')), None)
    if not pin_take or re.search(r'\bgit\s+fetch\b', code(pin_take['run'])):
        errs.append('release-rc.yml: build must unpack the pinned recipe archive via RC_COMMIT without git fetch')

    # 3. Publish needs [pins, build], reads pins outputs, and matches build's commit-scoped artifact names.
    if not {'pins', 'build'} <= set(as_list(publish.get('needs'))):
        errs.append('release-rc.yml: publish must need both pins and build')
    build_step = next((s for s in build_steps if s.get('id') == 'build'), None)
    if ((build_step or {}).get('env') or {}).get('PKGVER') != ver_expr:
        errs.append(f'release-rc.yml: build step must bind PKGVER={ver_expr}')
    pub_steps = publish.get('steps') or []
    if 'needs.build.outputs.' in yaml.safe_dump(pub_steps):
        errs.append('release-rc.yml: publish must not read needs.build.outputs')
    edge_step = next((s for s in pub_steps if s.get('id') == 'edge'), None)
    record_step = next((s for s in pub_steps if s.get('name') == 'Write the record'), None)
    if ((edge_step or {}).get('env') or {}).get('PKGVER') != ver_expr:
        errs.append(f'release-rc.yml: publish edge step must bind PKGVER={ver_expr}')
    rec_env = (record_step or {}).get('env') or {}
    if rec_env.get('PKGVER') != ver_expr or rec_env.get('RC_COMMIT') != rc_expr:
        errs.append(f'release-rc.yml: publish record step must bind PKGVER={ver_expr} and RC_COMMIT={rc_expr}')
    build_up = next((s for s in build_steps if (s.get('uses') or '').startswith('actions/upload-artifact@')), None)
    pub_dl = next((s for s in pub_steps if (s.get('uses') or '').startswith('actions/download-artifact@')), None)
    if ((build_up or {}).get('with') or {}).get('name') != f'release-rc-${{{{ matrix.arch }}}}-{rc_expr}-${{{{ github.run_id }}}}' or ((pub_dl or {}).get('with') or {}).get('pattern') != f'release-rc-*-{rc_expr}-${{{{ github.run_id }}}}':
        errs.append('release-rc.yml: build upload and publish download must share matching rc_commit-scoped artifact patterns')

    # 4. Round-trip check: pins archives both recipe trees cleanly and build restores them without stale files.
    if not (resolve and pin_take and pin_archive and pin_dl_dir):
        errs.append('release-rc.yml: missing archive/restore steps required for round-trip check')
        return errs
    base_env = {'PATH': os.environ.get('PATH', '/usr/bin:/bin')}
    git_env = {**base_env, 'GIT_AUTHOR_NAME': 'T', 'GIT_AUTHOR_EMAIL': 't@e', 'GIT_COMMITTER_NAME': 'T', 'GIT_COMMITTER_EMAIL': 't@e'}
    with tempfile.TemporaryDirectory() as td:
        td_path = pathlib.Path(td)
        rc_repo, build_repo = td_path / 'rc', td_path / 'build'
        expected = {
            'pkgbuilds/omarchy/PKGBUILD': b'pkgver=4.6.0rc1\npkgrel=1\n',
            'pkgbuilds/omarchy/.omarchy/package.json': b'{"name":"omarchy"}\n',
            'pkgbuilds/omarchy-settings/PKGBUILD': b'pkgver=4.6.0rc1\npkgrel=1\n',
            'pkgbuilds/omarchy-settings/.omarchy/package.json': b'{"name":"omarchy-settings"}\n',
        }
        for repo, files in (
            (rc_repo, {**expected, 'pkgbuilds/other/PKGBUILD': b'pkgver=rc\n'}),
            (build_repo, {'pkgbuilds/omarchy/PKGBUILD': b'pkgver=4.5.0\n', 'pkgbuilds/omarchy/stale': b'x\n', 'pkgbuilds/omarchy-settings/PKGBUILD': b'pkgver=4.5.0\n', 'pkgbuilds/omarchy-settings/stale': b'x\n', 'pkgbuilds/other/PKGBUILD': b'pkgver=master\n'}),
        ):
            for rel, data in files.items():
                f = repo / rel
                f.parent.mkdir(parents=True, exist_ok=True)
                f.write_bytes(data)
            subprocess.run(['git', 'init', '-q'], cwd=repo, env=git_env, check=True)
            subprocess.run(['git', 'add', '.'], cwd=repo, env=git_env, check=True)
            subprocess.run(['git', 'commit', '-q', '-m', 'init'], cwd=repo, env=git_env, check=True)
        rc_sha = subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=rc_repo, env=git_env, text=True).strip()
        gh_out = td_path / 'gh_out'
        gh_out.touch()
        res_pin = subprocess.run(['bash', '-c', resolve['run']], cwd=rc_repo, env={**base_env, 'RC_COMMIT': rc_sha, 'GITHUB_OUTPUT': str(gh_out)}, capture_output=True, text=True)
        archive_file = rc_repo / pin_archive
        if res_pin.returncode != 0 or not archive_file.is_file() or gh_out.read_text().splitlines() != ['pkgver=4.6.0rc1']:
            errs.append(f'release-rc.yml: pins archive step failed (rc={res_pin.returncode}, out={gh_out.read_text()!r})')
            return errs
        dl_target = build_repo / pin_dl_dir
        dl_target.mkdir(parents=True, exist_ok=True)
        shutil.copy2(archive_file, dl_target / pathlib.Path(pin_archive).name)
        res_take = subprocess.run(['bash', '-c', pin_take['run']], cwd=build_repo, env={**base_env, 'RC_COMMIT': rc_sha, 'PKGVER': '4.6.0rc1'}, capture_output=True, text=True)
        restored = {**tree_bytes(build_repo, 'pkgbuilds/omarchy'), **tree_bytes(build_repo, 'pkgbuilds/omarchy-settings')}
        if res_take.returncode != 0 or restored != expected or (build_repo / 'pkgbuilds/other/PKGBUILD').read_bytes() != b'pkgver=master\n' or dl_target.exists():
            errs.append(f'release-rc.yml: build restore mismatch (rc={res_take.returncode}, restored={sorted(restored)})')

    return errs


failures = []
gha_expr = re.compile(r"\$\{\{(?:'[^']*'|[^'])*?\}\}")
forbidden_ctx = re.compile(r'\b(?:github|inputs|matrix|env)\b', re.I)
workflows_dir = root / '.github/workflows'
for workflow in sorted(workflows_dir.glob('*.yml')):
    doc = yaml.safe_load(workflow.read_text())
    for job_id, job in (doc.get('jobs') or {}).items():
        for i, step in enumerate(job.get('steps') or []):
            run = step.get('run')
            if not run:
                continue
            label = step.get('name') or f'step {i + 1}'
            if workflow.name in ('build-pr.yml', 'publish.yml'):
                for expr in gha_expr.findall(run):
                    if forbidden_ctx.search(expr):
                        failures.append(f'{workflow.name}: {job_id}: "{label}" interpolates {expr} in run:')
            body = code(run)
            for name, files in defined.items():
                if not re.search(rf'(?<![\w.-]){name}(?![\w.-])', body):
                    continue
                if not any(re.search(rf'(source|\.)\s+(\S*/)?{re.escape(f)}\b', body) for f in files):
                    failures.append(f'{workflow.name}: {job_id}: "{label}" calls {name} without sourcing {" or ".join(sorted(files))}')

failures.extend(check_release_rc_pins(root))

for failure in failures:
    print(f'FAIL: {failure}')
if failures:
    sys.exit(1)
print('PASS: workflow helper sourcing, release-rc pin, and run-expression invariants hold')
