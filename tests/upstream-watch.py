#!/usr/bin/env python3
"""Offline integration tests for owned-recipe updates and failure isolation."""
import importlib.util
import io
import json
import os
import re
from pathlib import Path
import shutil
import stat
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("upstream_watch", ROOT / "helpers/upstream-watch.py")
w = importlib.util.module_from_spec(spec)
spec.loader.exec_module(w)


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.work = tempfile.TemporaryDirectory()
        self.addCleanup(self.work.cleanup)
        self.root = Path(self.work.name)
        self.package = self.root / "package"
        (self.package / ".omarchy").mkdir(parents=True)
        self.fetch = w.Fetcher(self.root / "cache")
        self.write_watch({"github": "owner/tool", "pattern": r"v(?P<version>[0-9.]+)"})
        self.recipe = self.package / "PKGBUILD"
        self.recipe.write_text("""pkgname=tool
pkgver=1.0
pkgrel=3.1
arch=('x86_64' 'aarch64')
source_x86_64=("https://example.test/tool-$pkgver-x64")
source_aarch64=("https://example.test/tool-$pkgver-arm64")
sha256sums_x86_64=('old-x64')
sha256sums_aarch64=('old-arm64')
package() { touch SHOULD-NOT-RUN; }
""")

    def write_watch(self, watch):
        (self.package / ".omarchy/package.json").write_text(json.dumps({"source": "local", "upstream": {"watch": watch}}))

    def release(self, version="2.0", **values):
        return {"pkgver": version, "values": {"version": version, "tag": "v" + version, **values}, "revision": "", "published_at": "2026-01-01T00:00:00Z"}

    def fake_file(self, url):
        p = self.root / ("source-" + url.rsplit("/", 1)[-1])
        p.write_text(url)
        return p

    def sync_release(self, release, file=None):
        with patch.object(w, "discover", return_value=[release]), patch.object(self.fetch, "file", side_effect=file or self.fake_file):
            return w.sync(self.package, self.fetch)

    def test_fetches_stay_on_http1_and_send_the_token_only_to_the_api(self):
        calls = []

        def run(command, **kwargs):
            calls.append((command, kwargs.get("input")))
            Path(command[command.index("-o") + 1]).write_text("ok")

        with patch.dict(os.environ, {"UPSTREAM_GITHUB_TOKEN": "job-token"}), patch.object(w.subprocess, "run", side_effect=run):
            self.fetch.file("https://api.github.com/repos/owner/tool/releases?per_page=100")
            self.fetch.file("https://download.example.test/tool/")
        (api, api_input), (vendor, vendor_input) = calls
        self.assertIn("--http1.1", api)
        self.assertIn("--http1.1", vendor)
        self.assertEqual(api_input, 'header = "Authorization: Bearer job-token"\n')
        self.assertIsNone(vendor_input)
        self.assertNotIn("job-token", " ".join(api + vendor))

    def test_updates_both_arches_without_running_build_functions(self):
        result = self.sync_release(self.release())
        self.assertEqual(result["after"], "0:2.0-1")
        recipe = w.read_recipe(self.recipe)
        for arch, upstream in [("x86_64", "x64"), ("aarch64", "arm64")]:
            file = self.fake_file(f"https://example.test/tool-2.0-{upstream}")
            self.assertEqual(recipe["sha256sums_" + arch], [w.hash_file(file, "sha256")])
        self.assertFalse((self.package / "SHOULD-NOT-RUN").exists())

    def test_missing_arm_payload_preserves_original_recipe(self):
        original = self.recipe.read_bytes()
        def fetch(url):
            if url.endswith('arm64'):
                raise ValueError("ARM release not published")
            return self.fake_file(url)
        with self.assertRaisesRegex(ValueError, "ARM"):
            self.sync_release(self.release(), fetch)
        self.assertEqual(self.recipe.read_bytes(), original)
        self.assertFalse(self.recipe.with_name('PKGBUILD.sync-upstream').exists())

    def test_changed_checksum_override_is_detected_and_rolled_back(self):
        self.recipe.write_text(self.recipe.read_text() + "sha256sums_aarch64[0]='stale'\n")
        original = self.recipe.read_bytes()
        with self.assertRaisesRegex(ValueError, "differs"):
            self.sync_release(self.release())
        self.assertEqual(self.recipe.read_bytes(), original)

    def test_old_or_equal_versions_do_not_download_sources(self):
        for version in ['0.9', '1.0']:
            with patch.object(w, 'discover', return_value=[self.release(version)]), patch.object(self.fetch, 'file') as fetch:
                self.assertEqual(w.sync(self.package, self.fetch)['status'], 'skipped')
                fetch.assert_not_called()

    def test_manual_hold_prevents_release_discovery(self):
        path = self.package / '.omarchy/package.json'
        metadata = json.loads(path.read_text())
        metadata['sync'] = False
        path.write_text(json.dumps(metadata))
        with patch.object(w, 'discover') as discover:
            self.assertEqual(w.sync(self.package, self.fetch)['status'], 'skipped')
            discover.assert_not_called()

    def test_epoch_change_in_recipe_cannot_mask_downgrade(self):
        self.recipe.write_text(self.recipe.read_text() + "if [[ $pkgver == 1.0 ]]; then epoch=2; else epoch=1; fi\n")
        original = self.recipe.read_bytes()
        with self.assertRaisesRegex(ValueError, "complete package version"):
            self.sync_release(self.release())
        self.assertEqual(self.recipe.read_bytes(), original)

    def test_same_version_build_revision_advances_downstream_pkgrel(self):
        self.write_watch({'github': 'owner/tool', 'pattern': r'v(?P<version>[0-9.]+)-(?P<build>[0-9]+)', 'variables': {'_build': '{build}'}, 'revision': '{build}', 'revision_variable': '_build'})
        self.recipe.write_text(self.recipe.read_text().replace('pkgrel=3.1', 'pkgrel=3.1\n_build=8').replace('tool-$pkgver-', 'tool-$pkgver-$_build-'))
        release = self.release('1.0', build='9');release['revision'] = '9'
        self.assertEqual(self.sync_release(release)['after'], '0:1.0-3.2')
        self.assertEqual(w.scalar(w.read_recipe(self.recipe), '_build'), '9')
        release = self.release('1.0', build='7');release['revision'] = '7'
        original = self.recipe.read_bytes()
        with self.assertRaisesRegex(ValueError, 'without a newer'):
            self.sync_release(release)
        self.assertEqual(self.recipe.read_bytes(), original)

    def test_sha512_blake2_and_local_hashes_are_preserved(self):
        self.recipe.write_text("""pkgver=1.0
pkgrel=1
arch=('any')
source=("https://example.test/tool-$pkgver" 'fix.patch')
sha512sums=('old' 'local-sha512')
b2sums=('old' 'local-b2')
""")
        (self.package / 'fix.patch').write_text('local patch')
        self.sync_release(self.release())
        recipe = w.read_recipe(self.recipe)
        file = self.fake_file('https://example.test/tool-2.0')
        self.assertEqual(recipe['sha512sums'], [w.hash_file(file, 'sha512'), 'local-sha512'])
        self.assertEqual(recipe['b2sums'], [w.hash_file(file, 'b2'), 'local-b2'])

    def test_mutable_sources_are_rehashed_when_version_changes(self):
        self.write_watch({'regex': 'https://example.test/feed', 'pattern': r'(?P<version>[0-9.]+)', 'mutable_sources': ['source_x86_64:0']})
        self.recipe.write_text(self.recipe.read_text().replace('tool-$pkgver-x64','tool-current-x64'))
        self.sync_release(self.release())
        result = w.read_recipe(self.recipe)
        self.assertEqual(result['sha256sums_x86_64'], [w.hash_file(self.fake_file('https://example.test/tool-current-x64'), 'sha256')])

    def test_release_selection_and_age(self):
        a, b = self.release('1.9'), self.release('1.10')
        self.assertEqual(w.select_release([a, b])['pkgver'], '1.10')
        b['published_at'] = '2 days ago'
        with self.assertRaisesRegex(ValueError, 'age'):
            w.select_release([b], 86400)
        b['published_at'] = '2999-01-01T00:00:00Z'
        self.assertIsNone(w.select_release([b], 86400))
        self.assertEqual(w.select_release([b], 86400, bypass=True), b)

    def test_hostile_release_values_do_not_reach_shell(self):
        for value in ['1.0\ntouch bad', '$(touch bad)', '`id`', '1.0;id', '1.0"']:
            with self.assertRaises(ValueError):
                w.candidate({}, {'version': value})
        with self.assertRaises(ValueError):
            w.replace_scalar('pkgver=1.0\n', 'pkgver', '$(id)')
        for url in ['http://example.test', 'https://user:password@example.test/file', 'https://example.test/\nfile']:
            with self.assertRaises(ValueError):w.https(url)

    def test_array_writer_handles_comments_and_quoted_parentheses(self):
        text = "sha256sums=( # closing ) in a comment\n 'old(value)'\n) # trailing\npackage() { :; }\n"
        output = w.replace_array(text, 'sha256sums', ['abc'])
        self.assertEqual(output, "sha256sums=('abc') # trailing\npackage() { :; }\n")

    def test_redirect_probes_past_a_staged_rollout(self):
        watch = {"redirect": "https://example.test/download",
                 "pattern": r"tool-(?P<version>[0-9]+\.4\.[0-9]+)\.tar\.gz"}
        rollout = "https://cdn.example.test/tool-274.3.4801.tar.gz"
        stable = "https://cdn.example.test/tool-272.4.3798.tar.gz"
        with patch.object(w, 'run', side_effect=[rollout, rollout, stable]) as probe:
            releases = w.discover(watch, self.fetch)
        self.assertEqual([r["pkgver"] for r in releases], ["272.4.3798"])
        self.assertEqual(probe.call_count, 3)

    def test_redirect_gives_up_after_its_probes(self):
        watch = {"redirect": "https://example.test/download",
                 "pattern": r"tool-(?P<version>[0-9]+\.4\.[0-9]+)\.tar\.gz"}
        with patch.object(w, 'run', return_value="https://cdn.example.test/tool-274.3.4801.tar.gz") as probe, \
                self.assertRaisesRegex(ValueError, 'no matching releases'):
            w.discover(watch, self.fetch)
        self.assertEqual(probe.call_count, w.REDIRECT_PROBES)

    def test_git_hash_matches_makepkg(self):
        repo = self.root / 'git'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / 'source').write_text('upstream code')
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'release'], check=True)
        subprocess.run(['git', '-C', str(repo), 'tag', 'v1.0'], check=True)
        command = w.subprocess.run
        def redirect(args, **kwargs):
            if 'fetch' in args:
                args = [str(repo) if arg == 'https://example.test/tool.git' else arg for arg in args]
            return command(args, **kwargs)
        with patch.object(w.subprocess, 'run', side_effect=redirect):
            archive = w.git_source_file('git+https://example.test/tool.git#tag=v1.0', self.fetch.cache)
        expected = subprocess.check_output(['git', '-c', 'core.abbrev=no', '-C', str(repo), 'archive', '--format', 'tar', 'v1.0'])
        self.assertEqual(archive.read_bytes(), expected)

    def branch_fixture(self, fresh_tip=False):
        """An upstream with two release tags and commits past the newest one,
        all committed years ago; with fresh_tip, one more commit dated now."""
        repo = self.root / 'branch-upstream'
        repo.mkdir()
        git = ['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.test']
        old = {**os.environ, 'GIT_COMMITTER_DATE': '2020-01-01T00:00:00+00:00', 'GIT_AUTHOR_DATE': '2020-01-01T00:00:00+00:00'}
        subprocess.run(['git', 'init', '-q', '-b', 'main', str(repo)], check=True)
        shas = []
        def commit(index, env):
            (repo / 'source').write_text(f'revision {index}')
            subprocess.run([*git, 'add', '.'], check=True)
            subprocess.run([*git, 'commit', '-qm', f'commit {index}'], env=env, check=True)
            shas.append(subprocess.check_output([*git, 'rev-parse', 'HEAD'], text=True).strip())
        for index, tag in enumerate([None, 'v1.0.0', 'v1.1.0', None, None]):
            commit(index, old)
            if tag:
                subprocess.run([*git, 'tag', tag], check=True)
        # A newer release tagged on another branch is not something main is "past".
        subprocess.run([*git, 'checkout', '-q', '-b', 'hotfix', shas[1]], check=True)
        (repo / 'hotfix').write_text('x')
        subprocess.run([*git, 'add', '.'], check=True)
        subprocess.run([*git, 'commit', '-qm', 'hotfix'], env=old, check=True)
        subprocess.run([*git, 'tag', 'v9.9.9'], check=True)
        subprocess.run([*git, 'checkout', '-q', 'main'], check=True)
        if fresh_tip:
            commit(len(shas), os.environ)
        return repo, shas

    def redirect_clone(self, repo):
        command = w.subprocess.run
        def redirect(args, **kwargs):
            if 'clone' in args:
                args = [f'file://{repo}' if arg == 'https://example.test/tool.git' else arg for arg in args]
            return command(args, **kwargs)
        return patch.object(w.subprocess, 'run', side_effect=redirect)

    def test_git_branch_versions_from_reachable_tag_and_shares_one_clone(self):
        repo, shas = self.branch_fixture()
        with self.redirect_clone(repo):
            tip = w.git_branch_tip('https://example.test/tool.git', 'main', r'v(?P<version>[0-9.]+)', self.fetch.cache)
            again = w.git_branch_tip('https://example.test/tool.git', 'main', None, self.fetch.cache)
        self.assertEqual((tip['commit'], tip['tag'], tip['version'], tip['distance'], tip['count']), (shas[-1], 'v1.1.0', '1.1.0', '2', '5'))
        self.assertEqual(again['commit'], shas[-1])
        self.assertEqual(len(list(self.fetch.cache.glob('*.branch.git'))), 1, 'one clone per branch per run')
        watch = {'git_branch': 'https://example.test/tool.git', 'branch': 'main', 'tag_pattern': r'v(?P<version>[0-9.]+)',
                 'version': '{version}.r{distance}.g{commit:.7}', 'variables': {'_commit': '{commit}'}}
        pkgver = w.candidate(watch, tip)['pkgver']
        self.assertEqual(pkgver, f'1.1.0.r2.g{shas[-1][:7]}')
        self.assertEqual(w.vercmp(pkgver, '1.1.0'), 1)
        self.assertEqual(w.vercmp(pkgver, '1.1.1'), -1)
        with self.redirect_clone(repo), self.assertRaisesRegex(ValueError, 'no tag'):
            w.git_branch_tip('https://example.test/tool.git', 'main', r'release-(?P<version>[0-9.]+)', self.root / 'other-cache')

    def test_git_branch_min_age_falls_back_to_the_newest_old_enough_tip(self):
        repo, shas = self.branch_fixture(fresh_tip=True)
        watch = {'git_branch': 'https://example.test/tool.git', 'branch': 'main'}
        with self.redirect_clone(repo):
            releases = w.discover(watch, self.fetch)
            held = w.discover(watch, self.fetch, min_age=3600)
        self.assertEqual(w.select_release(releases)['values']['commit'], shas[-1])
        # The backstop still refuses the fresh tip itself...
        self.assertIsNone(w.select_release(releases, min_age=3600))
        self.assertEqual(w.select_release(releases, min_age=3600, bypass=True)['values']['commit'], shas[-1])
        # ...and the watch offers the commit before it instead of nothing.
        self.assertEqual(w.select_release(held, min_age=3600)['values']['commit'], shas[-2])
        self.assertEqual(held[0]['values']['count'], str(len(shas) - 1))

    def test_git_branch_min_age_never_falls_back_into_a_merged_side_branch(self):
        repo, shas = self.branch_fixture()
        git = ['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.test']
        old = {**os.environ, 'GIT_COMMITTER_DATE': '2020-01-02T00:00:00+00:00', 'GIT_AUTHOR_DATE': '2020-01-02T00:00:00+00:00'}
        subprocess.run([*git, 'checkout', '-q', '-b', 'side'], check=True)
        (repo / 'side').write_text('x')
        subprocess.run([*git, 'add', '.'], check=True)
        subprocess.run([*git, 'commit', '-qm', 'side'], env=old, check=True)
        subprocess.run([*git, 'checkout', '-q', 'main'], check=True)
        subprocess.run([*git, 'merge', '-q', '--no-ff', '-m', 'merge side', 'side'], check=True)
        watch = {'git_branch': 'https://example.test/tool.git', 'branch': 'main'}
        with self.redirect_clone(repo):
            held = w.discover(watch, self.fetch, min_age=3600)
        self.assertEqual(w.select_release(held, min_age=3600)['values']['commit'], shas[-1])

    def test_git_branch_min_age_holds_when_nothing_is_old_enough(self):
        repo, shas = self.branch_fixture(fresh_tip=True)
        watch = {'git_branch': 'https://example.test/tool.git', 'branch': 'main'}
        with self.redirect_clone(repo):
            held = w.discover(watch, self.fetch, min_age=10 ** 10)
        self.assertIsNone(w.select_release(held, min_age=10 ** 10))

    def branch_sync_fixture(self):
        repo, shas = self.branch_fixture()
        for directory in ['bin', 'helpers']:
            shutil.copytree(ROOT / directory, self.root / directory)
        for name in ['dev', 'settings-dev']:
            package = self.root / 'pkgbuilds' / name
            (package / '.omarchy').mkdir(parents=True)
            (package / '.omarchy/package.json').write_text(json.dumps({
                'source': 'local', 'auto_merge': True, 'upstream': {'watch': {
                    'git_branch': 'https://example.test/tool.git', 'branch': 'main',
                    'tag_pattern': r'v(?P<version>[0-9.]+)',
                    'version': '{version}.r{count}.g{commit:.7}',
                    'variables': {'_commit': '{commit}'}}}}))
            (package / 'PKGBUILD').write_text(f'''pkgname={name}
pkgver=1.0.0
pkgrel=1
_commit={shas[1]}
arch=('any')
source=("tool::git+https://example.test/tool.git#commit=${{_commit}}")
sha256sums=('old')
''')
        stub = self.root / 'stub'
        stub.mkdir()
        git = stub / 'git'
        git.write_text('''#!/usr/bin/env python3
import os, sys
args = [os.environ['BRANCH_FIXTURE'] if arg == 'https://example.test/tool.git' else arg for arg in sys.argv[1:]]
os.execv(os.environ['REAL_GIT'], ['git', *args])
''')
        git.chmod(0o755)
        env = {**os.environ, 'PATH': str(stub) + os.pathsep + os.environ['PATH'],
               'BRANCH_FIXTURE': f'file://{repo}', 'REAL_GIT': shutil.which('git')}
        def sync(*args):
            return subprocess.run([str(self.root / 'bin/sync-upstream'), *args],
                                  env=env, text=True, capture_output=True)
        return self.root / 'pkgbuilds', shas[-1], sync

    def test_targeted_branch_sync_updates_siblings_and_then_noops(self):
        packages, tip, sync = self.branch_sync_fixture()
        result = sync('--lane', 'auto-merge', 'dev')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for package in packages.iterdir():
            recipe = w.read_recipe(package / 'PKGBUILD')
            self.assertEqual(w.scalar(recipe, '_commit'), tip)
            self.assertEqual(w.scalar(recipe, 'pkgver'), f'1.1.0.r5.g{tip[:7]}')
            self.assertRegex(recipe['sha256sums'][0], r'^[0-9a-f]{64}$')
        self.assertIn('Updated: 2', result.stdout)
        result = sync('--lane', 'auto-merge', 'dev')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Updated: 0', result.stdout)

    def test_branch_sync_rolls_back_when_a_sibling_fails(self):
        packages, tip, sync = self.branch_sync_fixture()
        broken = packages / 'settings-dev/PKGBUILD'
        broken.write_text(broken.read_text().replace("sha256sums=('old')", 'sha256sums=()'))
        before = {p: p.read_bytes() for p in packages.glob('*/PKGBUILD')}
        result = sync('--lane', 'auto-merge', 'dev')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('Lockstep violation', result.stdout + result.stderr)
        self.assertIn('Updated: 0', result.stdout)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_reviewed_lane_leaves_auto_merge_packages_untouched(self):
        packages, tip, sync = self.branch_sync_fixture()
        before = {p: p.read_bytes() for p in packages.glob('*/PKGBUILD')}
        result = sync('--lane', 'reviewed')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn('Updated: 0', result.stdout)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_different_lanes_cannot_split_a_branch_pair(self):
        packages, tip, sync = self.branch_sync_fixture()
        metadata = packages / 'settings-dev/.omarchy/package.json'
        metadata.write_text(metadata.read_text().replace('"auto_merge": true', '"auto_merge": false'))
        before = {p: p.read_bytes() for p in packages.glob('*/PKGBUILD')}
        result = sync('--lane', 'auto-merge', 'dev')
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('Lockstep violation', result.stdout + result.stderr)
        self.assertEqual(before, {p: p.read_bytes() for p in before})

    def test_git_branch_tag_template_requires_tag_pattern(self):
        base = {'git_branch': 'https://example.test/tool.git', 'branch': 'main'}
        w.validate({**base, 'version': '{date}.r{count}'})
        w.validate({**base, 'tag_pattern': r'v(?P<version>[0-9.]+)', 'version': '{version}.r{distance}.g{commit:.7}'})
        for extra in [{'version': '{version}.r{distance}'}, {'version': '{tag}'}, {'tag_pattern': 'v[0-9.]+'},
                      {'tag_pattern': 7}, {'tag_pattern': ''}]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                w.validate({**base, **extra})
        with self.assertRaisesRegex(ValueError, 'only applies'):
            w.validate({'github': 'owner/tool', 'pattern': r'v(?P<version>[0-9.]+)', 'tag_pattern': r'v(?P<version>[0-9.]+)'})

    def test_invalid_optional_metadata_fails_validation(self):
        valid = {'github': 'owner/tool', 'pattern': r'v(?P<version>[0-9.]+)'}
        for extra in [{'variables': []}, {'fields': {'commit': 3}}, {'submodules': {'pkgver': 'libs/common'}},
                      {'allow_prerelease': 'false'}, {'sequence': 1}, {'mutable_sources': ['source:no']},
                      {'revision_variable': '_build'}, {'submodules': {'_commit': '../outside'}},
                      {'allow_prerelase': True}]:
            with self.subTest(extra=extra), self.assertRaises(ValueError):
                w.validate({**valid, **extra})
        with self.assertRaisesRegex(ValueError, 'numeric'):
            w.candidate({'revision': '{build}'}, {'version': '1.0', 'build': 'beta'})

    def test_github_selects_stable_matching_tag_and_resolves_gitlinks(self):
        watch = {'github': 'owner/tool', 'pattern': r'v(?P<version>[0-9.]+)',
                 'variables': {'_commit': '{commit}'}, 'submodules': {'_common': 'libs/common'}}
        def fetch(url):
            if '/releases?' in url:
                return [{'tag_name': tag, 'published_at': '2026-01-01T00:00:00Z', **flags}
                        for tag, flags in [('v1.0', {}), ('v2.0', {}), ('v3.0', {'prerelease': True}),
                                           ('v4.0', {'draft': True}), ('unrelated-v5.0', {})]]
            if '/git/ref/' in url: return {'object': {'type': 'tag', 'sha': 'a' * 40}}
            if '/git/tags/' in url: return {'object': {'type': 'commit', 'sha': 'b' * 40}}
            if '/contents/' in url:
                self.assertTrue(url.endswith('?ref=v2.0'))
                return {'sha': 'c' * 40, 'submodule_git_url': 'https://example.test/common'}
            self.fail(url)
        with patch.object(self.fetch, 'json', side_effect=fetch):
            release = w.select_release(w.discover(watch, self.fetch))
            self.assertEqual(release['pkgver'], '2.0')
            self.assertEqual(w.resolve_release_fields(watch, release, self.fetch)['variables'],
                             {'_commit': 'b' * 40, '_common': 'c' * 40})

    def test_vendor_feeds_preserve_version_schemes(self):
        cases = [
            ('1password-beta', 'Package: unrelated\nVersion: 99.0\n\nPackage: 1password\nVersion: 8.12.38~25.BETA\n', '8.12.38_25.BETA'),
            ('spotify', 'Package: spotify-client\nVersion: 1:1.2.96.518.g366879e1\n', '1.2.96.518'),
            ('typora', 'Package: typora\nVersion: 1.12.6-1\n\nPackage: typora\nVersion: 1.9.0-1\n', '1.12.6'),
            ('nvidia-580xx-utils', '<a href="580.159.04/">580.159.04/</a> <a href="590.1/">590.1/</a>', '580.159.04'),
        ]
        for name, feed, expected in cases:
            watch = json.loads((ROOT / 'pkgbuilds' / name / '.omarchy/package.json').read_text())['upstream']['watch']
            with self.subTest(package=name), patch.object(self.fetch, 'text', return_value=feed):
                self.assertEqual(w.select_release(w.discover(watch, self.fetch))['pkgver'], expected)
        with patch.object(self.fetch, 'json', return_value={'release': {'version': '2.0', 'commit': 'a' * 40}}):
            release = w.discover({'json': 'https://example.test/feed', 'path': 'release.version', 'fields': {'commit': 'release.commit'}}, self.fetch)[0]
            self.assertEqual(release['values']['commit'], 'a' * 40)

    def test_registry_releases_and_archive_filenames(self):
        with patch.object(self.fetch, 'json', return_value={'dist-tags': {'latest': '2.0'}, 'time': {'2.0': '2026-01-01T00:00:00Z'}}):
            self.assertEqual(w.discover({'npm': '@owner/tool'}, self.fetch)[0]['pkgver'], '2.0')
        with patch.object(self.fetch, 'json', return_value={'info': {'version': '2.0'}, 'releases': {'2.0': [{'yanked': True}]}}):
            with self.assertRaisesRegex(ValueError, 'unyanked'):
                w.discover({'pypi': 'tool'}, self.fetch)
        archive = self.root / 'vendor.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('driver/yt6801-1.0.34.tar.gz', 'not executed or extracted')
        watch = json.loads((ROOT / 'pkgbuilds/yt6801-dkms/.omarchy/package.json').read_text())['upstream']['watch']
        with patch.object(self.fetch, 'file', return_value=archive):
            self.assertEqual(w.discover(watch, self.fetch)[0]['pkgver'], '1.0.34')

    def build_deb(self, name, files):
        """A real .deb (ar: debian-binary, control.tar.xz, data.tar.zst)."""
        work = self.root / f"deb-{name}"
        tree = work / "tree"
        for path, text in files.items():
            (tree / path).parent.mkdir(parents=True, exist_ok=True)
            (tree / path).write_text(text)
        (work / "debian-binary").write_text("2.0\n")
        (work / "control").write_text("Package: app\nVersion: 2.0\n")
        subprocess.run(["bsdtar", "-C", str(work), "-cJf", str(work / "control.tar.xz"), "control"], check=True)
        subprocess.run(["bsdtar", "-C", str(tree), "--zstd", "-cf", str(work / "data.tar.zst"), "."], check=True)
        deb = self.root / f"{name}.deb"
        subprocess.run(["bsdtar", "-C", str(work), "--format", "ar", "-cf", str(deb),
                        "debian-binary", "control.tar.xz", "data.tar.zst"], check=True)
        return deb

    def source_variable_package(self):
        self.write_watch({"json": "https://example.test/feed", "path": "version", "source_variables": {
            "_runtimever": {"source": "source:0", "member": "usr/lib/app/version",
                            "pattern": r"(?P<value>[0-9]+(?:\.[0-9]+)+)"}}})
        self.recipe.write_text("""pkgname=app
pkgver=1.0
pkgrel=2
_runtimever=1.1.1
arch=('x86_64' 'aarch64')
source=("app-$pkgver.deb::https://example.test/app-$pkgver.deb")
source_aarch64=("https://example.test/runtime-v$_runtimever-arm64.zip")
sha256sums=('old-deb')
sha256sums_aarch64=('old-runtime')
""")

    def test_source_variable_follows_the_version_inside_the_new_deb(self):
        self.source_variable_package()
        deb = self.build_deb("app-2.0", {"usr/lib/app/version": "2.2.2\n", "usr/lib/app/app": "binary"})
        file = lambda url: deb if url.endswith("/app-2.0.deb") else self.fake_file(url)
        self.assertEqual(self.sync_release(self.release("2.0"), file)["status"], "updated")
        recipe = w.read_recipe(self.recipe, "aarch64")
        self.assertEqual((recipe["pkgver"], recipe["pkgrel"], recipe["_runtimever"]), (["2.0"], ["1"], ["2.2.2"]))
        self.assertEqual(recipe["sha256sums"], [w.hash_file(deb, "sha256")])
        runtime = self.fake_file("https://example.test/runtime-v2.2.2-arm64.zip")
        self.assertEqual(recipe["sha256sums_aarch64"], [w.hash_file(runtime, "sha256")])

    def test_source_variable_missing_from_the_deb_leaves_the_recipe_alone(self):
        self.source_variable_package()
        before = self.recipe.read_text()
        deb = self.build_deb("app-2.0", {"usr/lib/app/app": "binary"})
        file = lambda url: deb if url.endswith(".deb") else self.fake_file(url)
        with self.assertRaisesRegex(ValueError, "missing or ambiguous"):
            self.sync_release(self.release("2.0"), file)
        self.assertEqual(self.recipe.read_text(), before)
        self.assertFalse((self.package / "PKGBUILD.sync-upstream").exists())

    def test_source_variable_must_match_its_pattern(self):
        self.source_variable_package()
        deb = self.build_deb("app-2.0", {"usr/lib/app/version": "2.2.2; rm -rf /\n"})
        file = lambda url: deb if url.endswith(".deb") else self.fake_file(url)
        with self.assertRaisesRegex(ValueError, "does not match its pattern"):
            self.sync_release(self.release("2.0"), file)

    def deb_with_entries(self, name, entries):
        """A .deb whose data.tar.xz holds exactly these raw tar entries."""
        work = self.root / f"raw-{name}"
        work.mkdir()
        with tarfile.open(work / "data.tar.xz", "w:xz") as data:
            for path, body in entries:
                info = tarfile.TarInfo(path)
                if isinstance(body, tuple):
                    info.type, info.linkname = tarfile.SYMTYPE, body[1]
                    data.addfile(info)
                else:
                    info.size = len(body)
                    data.addfile(info, io.BytesIO(body))
        (work / "debian-binary").write_text("2.0\n")
        deb = self.root / f"{name}.deb"
        subprocess.run(["bsdtar", "-C", str(work), "--format", "ar", "-cf", str(deb), "debian-binary", "data.tar.xz"], check=True)
        return deb

    def test_archive_member_rejects_ambiguous_large_and_linked_entries(self):
        member = "usr/lib/app/version"
        self.assertEqual(w.archive_member(self.deb_with_entries("plain", [("./" + member, b"2.2.2\n")]), member), b"2.2.2\n")
        # libarchive would match both spellings and concatenate them into 45.1.0.
        dup = self.deb_with_entries("dup", [(member, b"45.1."), ("././" + member, b"0")])
        with self.assertRaisesRegex(ValueError, "ambiguous"):
            w.archive_member(dup, member)
        big = self.deb_with_entries("big", [(member, b"1" * 65537)])
        with self.assertRaisesRegex(ValueError, "at most 65536 bytes"):
            w.archive_member(big, member)
        link = self.deb_with_entries("link", [(member, ("link", "/etc/hostname"))])
        with self.assertRaisesRegex(ValueError, "regular file"):
            w.archive_member(link, member)

    def test_archive_member_never_reads_files_an_mtree_names(self):
        # libarchive reads an mtree manifest as an archive and fills
        # contents= from the local disk; only real tar and zip are accepted.
        secret = self.root / "secret"
        secret.write_text("45.1.0")
        manifest = f"#mtree\nusr/lib/app/version type=file contents={secret}\n".encode()
        plain = self.root / "manifest.tar"
        plain.write_bytes(manifest)
        work = self.root / "mtree-deb"
        work.mkdir()
        (work / "debian-binary").write_text("2.0\n")
        (work / "data.tar").write_bytes(manifest)
        deb = self.root / "mtree.deb"
        subprocess.run(["bsdtar", "-C", str(work), "--format", "ar", "-cf", str(deb), "debian-binary", "data.tar"], check=True)
        for archive in (plain, deb):
            with self.subTest(archive=archive.name), self.assertRaisesRegex(ValueError, "cannot read"):
                w.archive_member(archive, "usr/lib/app/version")

    def test_archive_member_reads_zip_files_but_not_zip_symlinks(self):
        archive = self.root / "runtime.zip"
        with zipfile.ZipFile(archive, "w") as z:
            z.writestr("./usr/lib/app/version", "2.2.2\n")
            link = zipfile.ZipInfo("usr/lib/app/link")
            link.create_system, link.external_attr = 3, (stat.S_IFLNK | 0o777) << 16
            z.writestr(link, "45.1.0")
        self.assertEqual(w.archive_member(archive, "usr/lib/app/version"), b"2.2.2\n")
        with self.assertRaisesRegex(ValueError, "regular file"):
            w.archive_member(archive, "usr/lib/app/link")

    def test_invalid_source_variables_fail_validation(self):
        good = {"source": "source:0", "member": "usr/lib/app/version", "pattern": "(?P<value>.+)"}
        for bad in ({"_x": {**good, "pattern": "(.+)"}}, {"_x": {**good, "source": "sources:0"}},
                    {"_x": {**good, "member": "../etc/passwd"}}, {"_x": {**good, "member": "./usr/lib/app/version"}},
                    {"_x": {**good, "member": "usr//lib/app/version"}}, {"_x": {**good, "member": "/usr/lib/app/version"}},
                    {"x": good}, {"_x": {**good, "extra": "1"}}):
            with self.subTest(bad=bad), self.assertRaises(ValueError):
                w.validate({"json": "https://example.test/feed", "path": "version", "source_variables": bad})
        with self.assertRaisesRegex(ValueError, "cannot also be"):
            w.validate({"json": "https://example.test/feed", "path": "version",
                        "variables": {"_x": "{version}"}, "source_variables": {"_x": good}})

    def test_slack_reads_its_electron_version_from_its_deb(self):
        watch = json.loads((ROOT / "pkgbuilds/slack-desktop/.omarchy/package.json").read_text())["upstream"]["watch"]
        w.validate(watch)
        spec = watch["source_variables"]["_electronver"]
        deb = self.build_deb("slack", {"usr/lib/slack/version": "45.1.0"})
        self.assertEqual(re.fullmatch(spec["pattern"], w.archive_member(deb, spec["member"]).decode().strip())["value"], "45.1.0")

    def test_cursor_same_day_hash_uses_counter_not_hash_order(self):
        self.write_watch({'regex': 'https://example.test/feed', 'pattern': r'(?P<version>[0-9.]+)-(?P<hash>[a-f0-9]+)',
                          'version': '{version}.1.{hash}', 'sequence': True})
        self.recipe.write_text(self.recipe.read_text().replace('pkgver=1.0', 'pkgver=2026.09.14.1.ffff'))
        release = w.candidate({'version': '{version}.1.{hash}'}, {'version': '2026.09.14', 'hash': 'aaaa'})
        self.assertEqual(self.sync_release(release)['after'], '0:2026.09.14.2.aaaa-1')
        self.assertEqual(self.sync_release(release)['status'], 'skipped')

    def test_existing_signed_metadata_skips_are_retained(self):
        self.recipe.write_text(self.recipe.read_text().replace("'old-arm64'", "'SKIP'") + "sha256sums_aarch64[0]='SKIP'\n")
        self.sync_release(self.release())
        self.assertEqual(w.read_recipe(self.recipe)['sha256sums_aarch64'], ['SKIP'])
        self.assertTrue((self.root / 'source-tool-2.0-arm64').exists())

    def test_conditional_arm_source_cannot_use_x86_hash(self):
        self.recipe.write_text(self.recipe.read_text() + 'if [[ $CARCH == aarch64 ]]; then source_aarch64=("https://example.test/different-$pkgver"); fi\n')
        original = self.recipe.read_bytes()
        with self.assertRaisesRegex(ValueError, 'conditional source'):
            self.sync_release(self.release())
        self.assertEqual(self.recipe.read_bytes(), original)

    def test_cli_continues_after_one_package_fails(self):
        for directory in ['bin', 'helpers']:
            shutil.copytree(ROOT / directory, self.root / directory)
        for name in ['bad', 'good', 'held']:
            pkg = self.root / 'pkgbuilds' / name
            shutil.copytree(self.package, pkg)
            (pkg / '.omarchy/package.json').write_text(json.dumps({'source': 'local', 'sync': name != 'held', 'upstream': {'watch': {
                'regex': 'https://example.test/feed', 'pattern': '(?P<version>[0-9.]+)'}}}))
            path = pkg / 'PKGBUILD'
            path.write_text(path.read_text().replace('example.test/tool-', f'example.test/{name}-'))
        stub = self.root / 'stub'
        stub.mkdir()
        curl = stub / 'curl'
        curl.write_text('''#!/usr/bin/env python3
import sys
from pathlib import Path
url = sys.argv[-1]
if 'bad-2.0-arm64' in url: sys.exit(22)
Path(sys.argv[sys.argv.index('-o') + 1]).write_text('2.0' if url.endswith('/feed') else url)
''')
        curl.chmod(0o755)
        bad = self.root / 'pkgbuilds/bad/PKGBUILD'
        original = bad.read_bytes()
        result = subprocess.run([str(self.root / 'bin/sync-upstream'), 'bad', 'good', 'held'],
                                env={**os.environ, 'PATH': str(stub) + os.pathsep + os.environ['PATH']},
                                text=True, capture_output=True)
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(bad.read_bytes(), original)
        self.assertEqual(w.scalar(w.read_recipe(self.root / 'pkgbuilds/good/PKGBUILD'), 'pkgver'), '2.0')
        self.assertEqual(w.scalar(w.read_recipe(self.root / 'pkgbuilds/held/PKGBUILD'), 'pkgver'), '1.0')
        self.assertIn('Updated: 1', result.stdout)
        self.assertIn('Failed: 1', result.stdout)

    def test_aur_import_is_once_only_and_records_local_ownership(self):
        for directory in ['bin', 'helpers']:
            shutil.copytree(ROOT / directory, self.root / directory)
        repo = self.root / 'aur'
        repo.mkdir()
        subprocess.run(['git', 'init', '-q', str(repo)], check=True)
        (repo / 'PKGBUILD').write_text('pkgver=1.0\npkgrel=1\ntouch SHOULD-NOT-RUN\n')
        (repo / '.SRCINFO').write_text('AUR only')
        subprocess.run(['git', '-C', str(repo), 'add', '.'], check=True)
        subprocess.run(['git', '-C', str(repo), '-c', 'user.name=Test', '-c', 'user.email=test@example.test', 'commit', '-qm', 'recipe'], check=True)
        stub = self.root / 'stub'
        stub.mkdir()
        git = stub / 'git'
        git.write_text('''#!/usr/bin/env python3
import os, sys
args = [os.environ['AUR_FIXTURE'] if v == 'https://aur.archlinux.org/upstream-name.git' else v for v in sys.argv[1:]]
os.execv(os.environ['REAL_GIT'], ['git', *args])
''')
        git.chmod(0o755)
        env = {**os.environ, 'PATH': str(stub) + os.pathsep + os.environ['PATH'], 'AUR_FIXTURE': str(repo), 'REAL_GIT': shutil.which('git')}
        command = [str(self.root / 'bin/add-package'), 'local-name', '--source', 'aur', '--aur', 'upstream-name', '--no-sync', '--fast']
        result = subprocess.run(command, env=env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        package = self.root / 'pkgbuilds/local-name'
        metadata_file = package / '.omarchy/package.json'
        metadata = json.loads(metadata_file.read_text())
        self.assertEqual(metadata['source'], 'local')
        self.assertEqual(metadata['origin']['aur'], 'upstream-name')
        self.assertEqual(metadata['origin']['commit'], subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip())
        self.assertFalse(metadata['sync'])
        self.assertEqual(metadata['release_ring'], 'fast')
        self.assertFalse((package / '.SRCINFO').exists())
        self.assertFalse((package / 'SHOULD-NOT-RUN').exists())
        original = metadata_file.read_bytes()
        result = subprocess.run([*command, '--force'], env=env, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(metadata_file.read_bytes(), original)


class T3CodeHookTest(unittest.TestCase):
    """Keep both desktop architectures on the same complete upstream release."""

    def setUp(self):
        work = tempfile.TemporaryDirectory()
        self.addCleanup(work.cleanup)
        self.root = Path(work.name)
        self.recipe = self.root / "PKGBUILD"
        self.recipe.write_text("pkgver=0.0.41\n")
        self.feed = self.root / "latest-linux.yml"
        self.feed.write_text("version: 0.0.42\npath: T3-Code-0.0.42-x86_64.AppImage\n")
        self.arm_feed = self.root / "latest-linux-arm64.yml"
        self.arm_feed.write_text("version: 0.0.42\npath: T3-Code-0.0.42-arm64.AppImage\n")
        for arch in ("x86_64", "arm64"):
            (self.root / f"T3-Code-0.0.42-{arch}.AppImage").write_text(arch)
        # Serve only fixture assets, and record the requested release URLs.
        curl = self.root / "curl"
        curl.write_text('#!/bin/bash\nurl="${@: -1}"\nprintf "%s\\n" "$url" >> requests\ncat "${url##*/}"\n')
        curl.chmod(0o755)
        self.env = dict(os.environ, PATH=f"{self.root}:{os.environ['PATH']}")

    def run_hook(self):
        return subprocess.run(
            ['bash', str(ROOT / 'pkgbuilds/t3code-bin/.omarchy/upstream.sh')],
            cwd=self.root, env=self.env, text=True, capture_output=True,
        )

    def test_hashes_both_architectures_from_one_release(self):
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {
            'pkgver': '0.0.42',
            'sha256sums': {
                arch: [w.hash_file(self.root / f'T3-Code-0.0.42-{asset_arch}.AppImage', 'sha256')]
                for arch, asset_arch in [('x86_64', 'x86_64'), ('aarch64', 'arm64')]
            },
        })
        self.assertIn('/download/v0.0.42/latest-linux-arm64.yml', (self.root / 'requests').read_text())

    def test_current_version_does_not_download_assets(self):
        self.recipe.write_text('pkgver=0.0.42\n')
        result = self.run_hook()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(json.loads(result.stdout), {})
        self.assertEqual(len((self.root / 'requests').read_text().splitlines()), 1)

    def test_incomplete_or_mismatched_arm_release_reports_no_update(self):
        for bad_feed in ('', 'version: 0.0.43\npath: T3-Code-0.0.42-arm64.AppImage\n',
                         'version: 0.0.42\npath: renamed.AppImage\n'):
            with self.subTest(feed=bad_feed):
                self.arm_feed.write_text(bad_feed)
                result = self.run_hook()
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, '')
        self.arm_feed.unlink()
        result = self.run_hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')

    def test_missing_arm_asset_reports_no_update(self):
        (self.root / 'T3-Code-0.0.42-arm64.AppImage').unlink()
        result = self.run_hook()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, '')


if __name__ == '__main__':
    unittest.main(verbosity=2)
