"""Offline release-track tests. Run with python3 on an Arch host (vercmp)."""

import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

PACKAGE = Path(__file__).resolve().parents[1]


def release(tag, preview, *, draft=False, recent=False):
    asset = f"VibeCAD-{tag[1:]}-Linux-x86_64.AppImage"
    url = f"https://github.com/10-X-eng/vibecad/releases/download/{tag}/{asset}"
    return {
        "tag_name": tag, "prerelease": preview, "draft": draft,
        "published_at": datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
        if recent else '2025-01-01T00:00:00Z',
        "assets": [{"name": asset, "browser_download_url": url},
                   {"name": asset + '-SHA256.txt', "browser_download_url": url + '-SHA256.txt'}],
    }


class Tracks(unittest.TestCase):
    def run_hook(self, package, releases, *, age=0, invalid_hash=False):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for filename in ('vibecad', 'vibecad.desktop', 'update-policy.json'):
                shutil.copy2(PACKAGE / filename, root / filename)
            (root / 'PKGBUILD').write_text(f'pkgname={package}\npkgver=0\n')
            stub = root / 'bin'
            stub.mkdir()
            curl = stub / 'curl'
            curl.write_text('''#!/bin/bash
url="${@: -1}"
case "$url" in
  *'/releases?per_page=100') printf '%s' "$RELEASE_FIXTURE" ;;
  *'-SHA256.txt') name=${url##*/}; printf '%s  %s\\n' "$TEST_HASH" "${name%-SHA256.txt}" ;;
  *'/LICENSE') printf 'license' ;;
  *'/vibecad-mark.svg') printf '<svg/>' ;;
  *) exit 99 ;;
esac
''')
            curl.chmod(0o755)
            env = dict(os.environ, PATH=f"{stub}:{os.environ['PATH']}",
                       RELEASE_FIXTURE=json.dumps(releases), TEST_HASH='bad' if invalid_hash else 'a' * 64,
                       MIN_RELEASE_AGE_SECONDS=str(age), BYPASS_MIN_RELEASE_AGE='')
            return subprocess.run(['bash', str(PACKAGE / '.omarchy/upstream.sh')],
                                  cwd=root, env=env, capture_output=True, text=True)

    def version(self, package, releases, **kwargs):
        proc = self.run_hook(package, releases, **kwargs)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return json.loads(proc.stdout).get('pkgver')

    def test_stable_excludes_rc_even_when_mislabeled(self):
        rows = [release('v26.3.1-build2', False), release('v27.0.0-RC1-build1', False),
                release('v27.0.0-RC2-build1', True)]
        self.assertEqual(self.version('vibecad-bin', rows), '26.3.1.build2')

    def test_preview_excludes_stable_drafts_and_other_prereleases(self):
        rows = [release('v26.3.1-RC6-build1', True), release('v27.0.0-build1', False),
                release('v27.0.0-RC1-build1', True, draft=True), release('v27.0.0-beta1-build1', True)]
        self.assertEqual(self.version('vibecad-preview-bin', rows), '26.3.1rc6.build1')

    def test_rc_numbers_use_pacman_order(self):
        rows = [release('v26.3.1-RC9-build1', True), release('v26.3.1-RC10-build1', True)]
        self.assertEqual(self.version('vibecad-preview-bin', rows), '26.3.1rc10.build1')

    def test_no_stable_does_not_promote_rc(self):
        self.assertIsNone(self.version('vibecad-bin', [release('v26.3.1-RC6-build1', True)]))

    def test_quarantine_selects_older_eligible_rc(self):
        rows = [release('v26.3.1-RC7-build1', True, recent=True), release('v26.3.1-RC6-build1', True)]
        self.assertEqual(self.version('vibecad-preview-bin', rows, age=86400), '26.3.1rc6.build1')

    def test_invalid_checksum_fails(self):
        proc = self.run_hook('vibecad-preview-bin', [release('v26.3.1-RC6-build1', True)], invalid_hash=True)
        self.assertNotEqual(proc.returncode, 0)

    def test_incorrect_asset_location_fails(self):
        row = release('v26.3.1-RC6-build1', True)
        row['assets'][0]['browser_download_url'] = 'https://example.org/wrong.AppImage'
        self.assertNotEqual(self.run_hook('vibecad-preview-bin', [row]).returncode, 0)


if __name__ == '__main__':
    unittest.main()
