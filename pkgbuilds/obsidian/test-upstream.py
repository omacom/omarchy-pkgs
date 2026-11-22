#!/usr/bin/python3
import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).with_name('upstream.py')
spec = importlib.util.spec_from_file_location('obsidian_upstream', path)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


def release(version, **extra):
    return dict(tag_name='v' + version, draft=False, prerelease=False,
                published_at='2026-09-23T00:00:00Z', assets=[{
                    'name': f'obsidian-{version}-arm64.tar.gz',
                    'digest': 'sha256:' + 'a' * 64,
                    'browser_download_url': f'https://github.com/obsidianmd/obsidian-releases/releases/download/v{version}/obsidian-{version}-arm64.tar.gz'
                }], **extra)


class DesktopReleaseTests(unittest.TestCase):
    def test_mobile_only_and_preview_ignored(self):
        mobile = release('2.0.0'); mobile['assets'] = [{'name': 'Obsidian.apk'}]
        preview = release('3.0.0'); preview['prerelease'] = True
        draft = release('4.0.0'); draft['draft'] = True
        self.assertEqual(module.select([mobile, preview, draft, release('1.13.7')])['pkgver'], '1.13.7')

    def test_numeric_version_order(self):
        self.assertEqual(module.select([release('1.9.0'), release('1.13.7')])['pkgver'], '1.13.7')

    def test_bad_newest_digest_fails_without_falling_back(self):
        newest = release('2.0.0'); newest['assets'][0]['digest'] = None
        with self.assertRaises(ValueError):
            module.select([release('1.13.7'), newest])

    def test_changed_url_rejected(self):
        row = release('1.13.7'); row['assets'][0]['browser_download_url'] = 'https://example.org/foreign'
        with self.assertRaises(ValueError): module.select([row])

    def test_missing_or_duplicate_installer_rejected(self):
        with self.assertRaises(ValueError): module.select([])
        row = release('1.13.7'); row['assets'] *= 2
        with self.assertRaises(ValueError): module.select([row])


if __name__ == '__main__':
    unittest.main()
