#!/usr/bin/python3
"""Report the newest stable ARM desktop installer, ignoring mobile-only tags."""
import json
import re
import subprocess


def select(releases):
    if not isinstance(releases, list):
        raise ValueError('Expected a GitHub release list')
    candidates = []
    for release in releases:
        if release.get('draft') or release.get('prerelease'):
            continue
        match = re.fullmatch(r'v([0-9]+(?:\.[0-9]+)*)', release.get('tag_name', ''))
        if not match:
            continue
        version = match[1]
        assets = [a for a in release.get('assets', [])
                  if a.get('name') == f'obsidian-{version}-arm64.tar.gz']
        if not assets:
            continue
        if len(assets) != 1:
            raise ValueError('Duplicate desktop installer')
        candidates.append((tuple(map(int, version.split('.'))), version, release, assets[0]))
    if not candidates:
        raise ValueError('No stable ARM desktop installer found')
    _, version, release, asset = max(candidates, key=lambda row: row[0])
    digest = asset.get('digest') or ''
    if not re.fullmatch(r'sha256:[0-9a-f]{64}', digest):
        raise ValueError('Selected desktop installer lacks its SHA256 digest')
    expected = f'https://github.com/obsidianmd/obsidian-releases/releases/download/v{version}/obsidian-{version}-arm64.tar.gz'
    if asset.get('browser_download_url') != expected:
        raise ValueError('Unexpected desktop installer URL')
    return {'pkgver': version, 'published_at': release['published_at'],
            'sha256sums': {'aarch64': [digest[7:]]}}


if __name__ == '__main__':
    response = subprocess.check_output([
        'curl', '--proto', '=https', '--proto-redir', '=https', '-fsSL',
        '--retry', '3', '--max-time', '60',
        'https://api.github.com/repos/obsidianmd/obsidian-releases/releases?per_page=100'
    ], text=True)
    print(json.dumps(select(json.loads(response))))
