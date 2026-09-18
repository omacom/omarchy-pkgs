#!/usr/bin/env python3
"""Offline integration tests for owned-recipe updates and failure isolation."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
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
