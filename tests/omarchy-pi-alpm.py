"""Real makepkg/libalpm contract test; run as root in a disposable Arch container.

No host package database is used. PI_ALPM_OUTPUT retains packages and logs.
"""
import hashlib
import os
import pwd
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[1]
BUILDER = os.environ.get('PI_ALPM_BUILDER', 'builder')
if pwd.getpwnam(BUILDER).pw_uid == 0:
  raise RuntimeError('makepkg fixture builder must be unprivileged')


class PiAlpm(unittest.TestCase):
  def run_command(self, args, success=True, **kwargs):
    result = subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, **kwargs)
    print('$', ' '.join(map(str, args)), '\n', result.stdout, flush=True)
    self.assertEqual(result.returncode == 0, success, result.stdout)
    return result.stdout

  def build(self, name, version, depends=(), provides=()):
    directory = self.work / (name + '-' + version)
    directory.mkdir()
    def array(items):
      return '(' + ' '.join("'" + item + "'" for item in items) + ')'
    (directory / 'PKGBUILD').write_text(f'''pkgname={name}
pkgver={version}
pkgrel=1
pkgdesc='Disposable ALPM transaction fixture'
arch=(aarch64)
license=(MIT)
depends={array(depends)}
provides={array(provides)}
package() {{
  install -d "$pkgdir/usr/share/pi-contract"
  printf '%s\\n' '{version}' >"$pkgdir/usr/share/pi-contract/{name}"
}}
''')
    return self.makepkg(directory)

  def makepkg(self, directory):
    shutil.chown(directory, user=BUILDER, group=pwd.getpwnam(BUILDER).pw_gid)
    for path in directory.rglob('*'):
      shutil.chown(path, user=BUILDER, group=pwd.getpwnam(BUILDER).pw_gid)
    self.run_command(['runuser', '-u', BUILDER, '--', 'bash', '-c', 'cd "$1"; makepkg --nodeps --noconfirm', '_', str(directory)])
    return sorted(p for p in directory.glob('*.pkg.tar.*') if not p.name.endswith('.sig'))

  def pacman(self, args, success=True):
    return self.run_command(['pacman', '--root', str(self.root), '--config', str(self.config), '--noconfirm', *map(str, args)], success)

  def snapshot(self):
    return {str(p.relative_to(self.root)): hashlib.sha256(os.readlink(p).encode() if p.is_symlink() else p.read_bytes()).hexdigest()
            for p in self.root.rglob('*') if (p.is_file() or p.is_symlink()) and p.name != 'db.lck' and 'var/lib/pacman/sync/' not in str(p.relative_to(self.root))}

  def test_upgrade_rejection_and_rollback(self):
    self.work = Path(os.environ.get('PI_ALPM_OUTPUT', tempfile.mkdtemp(prefix='pi-alpm-')))
    self.work.mkdir(parents=True, exist_ok=True)
    self.work.chmod(0o777)
    self.root = self.work / 'root'
    (self.root / 'var/lib/pacman').mkdir(parents=True)
    (self.root / 'var/log').mkdir(parents=True)
    self.config = self.work / 'pacman.conf'
    self.config.write_text('[options]\nArchitecture = aarch64\nSigLevel = Never\nLogFile = /dev/null\n')
    supportdir = self.work / 'support'
    shutil.copytree(REPO / 'pkgbuilds/raspberrypi-4-support', supportdir, ignore=shutil.ignore_patterns('__pycache__'))
    support = self.makepkg(supportdir)
    info = self.run_command(['bsdtar', '-xOf', str(next(p for p in support if p.name.startswith('raspberrypi-4-support-'))), '.PKGINFO'])
    dependencies = [line.removeprefix('depend = ') for line in info.splitlines() if line.startswith('depend = ')]
    # Supply only unrelated dependencies with a real empty fixture package.
    external = [d for d in dependencies if d not in ('linux-omarchy', 'linux-omarchy-pi4=1')]
    deps = self.build('pi-external-dependencies', '1', provides=external)
    def pair(version, capability=True):
      kernel = self.build('linux-omarchy', version, provides=['linux-omarchy-pi4=1'] if capability else [])
      headers = self.build('linux-omarchy-headers', version, depends=[f'linux-omarchy={version}-1'])
      nvidia = self.build('linux-omarchy-nvidia-open', version, depends=[f'linux-omarchy={version}-1'])
      settings = self.build('omarchy-settings', version)
      runtime = self.build('omarchy', version, depends=[f'omarchy-settings={version}-1'], provides=['omarchy-pi-runtime=1'] if capability else [])
      return kernel + headers + nvidia + settings + runtime
    old, new, bad = pair('1'), pair('2'), pair('3', False)
    self.pacman(['-U', *deps, *old, *support])
    # Exercise the normal repository sysupgrade path with actual repo metadata.
    repository = self.work / 'repository'
    repository.mkdir()
    for archive in new:
      shutil.copy2(archive, repository)
    self.run_command(['repo-add', str(repository / 'pi-contract.db.tar.gz'), *map(str, repository.glob('*.pkg.tar.*'))])
    with self.config.open('a') as config:
      config.write(f'\n[pi-contract]\nServer = file://{repository}\n')
    self.pacman(['-Syu', '--disable-sandbox'])
    self.assertEqual((self.root / 'usr/share/pi-contract/linux-omarchy').read_text(), '2\n')
    for candidates in ([bad[0], bad[1], bad[2]], [bad[3], bad[4]], [new[0], old[1]], [old[3], new[4]]):
      before = self.snapshot()
      output = self.pacman(['-U', *candidates], success=False)
      self.assertIn('could not satisfy dependencies', output)
      self.assertEqual(before, self.snapshot(), 'Rejected transaction changed installed files or database')
    for archive in bad:
      shutil.copy2(archive, repository)
    self.run_command(['repo-add', str(repository / 'pi-contract.db.tar.gz'), *map(str, (repository / p.name for p in bad))])
    before = self.snapshot()
    self.pacman(['-Syyu', '--disable-sandbox'], success=False)
    self.assertEqual(before, self.snapshot(), 'Rejected repository upgrade changed installed state')
    self.pacman(['-U', *old])
    self.assertEqual((self.root / 'usr/share/pi-contract/linux-omarchy').read_text(), '1\n')
    self.assertEqual((self.root / 'usr/share/pi-contract/omarchy').read_text(), '1\n')
    self.pacman(['-Q'])


if __name__ == '__main__':
  unittest.main()
