import importlib.machinery
import importlib.util
import io
import gzip
import json
import lzma
import os
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest

HERE = Path(__file__).resolve().parent
TOOL = HERE / 'p16-platform-tools'


def cpio(files):
    out = bytearray()
    for name, content in [*files.items(), ('TRAILER!!!', b'')]:
        mode = 0o100644
        if isinstance(content, tuple):
            mode, content = content
        name = name.encode() + b'\0'
        fields = [0, mode, 0, 0, 1, 0, len(content), 0, 0, 0, 0, len(name), 0]
        out += b'070701' + ''.join(f'{n:08x}' for n in fields).encode() + name
        out += b'\0' * (-len(out) % 4)
        out += content
        out += b'\0' * (-len(out) % 4)
    return bytes(out)


def pe(sections):
    # Minimal real PE32+ EFI application with aligned raw section payloads.
    image = bytearray(0x400)
    image[:2] = b'MZ'
    struct.pack_into('<I', image, 0x3c, 0x80)
    image[0x80:0x84] = b'PE\0\0'
    struct.pack_into('<HHIIIHH', image, 0x84, 0xaa64, len(sections), 0, 0, 0, 240, 0x22)
    struct.pack_into('<H', image, 0x98, 0x20b)
    struct.pack_into('<II', image, 0x98 + 32, 0x1000, 0x200)
    struct.pack_into('<II', image, 0x98 + 56, 0x10000, 0x400)
    struct.pack_into('<H', image, 0x98 + 68, 10)
    struct.pack_into('<I', image, 0x98 + 108, 16)
    for i, (name, content) in enumerate(sections):
        offset = len(image)
        raw_size = (len(content) + 511) // 512 * 512
        struct.pack_into('<8sIIIIIIHHI', image, 0x188 + 40*i,
                         name.encode(), len(content), 0x1000*(i+1), raw_size,
                         offset, 0, 0, 0, 0, 0x40000040)
        image += content + bytes(raw_size-len(content))
    return image


class ToolsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.modules = self.root / 'modules'
        self.release = '7.3-test'
        self.base = self.modules / self.release
        (self.base / 'build/include/config').mkdir(parents=True)
        (self.base / 'build/include/config/kernel.release').write_text(self.release+'\n')
        (self.base / 'build/Makefile').write_text('all:\n')
        (self.base / 'vmlinuz').write_bytes(b'kernel-exact\0')
        for name in ['spi_hid', 'spi_hid_acpi', 'asus_wmi', 'nvidia']:
            (self.base / (name + '.ko')).write_bytes(name.encode())
        self.bin = self.root / 'bin'
        self.bin.mkdir()
        mock = '''#!/usr/bin/env python3
import os, sys
from pathlib import Path
args = sys.argv[1:]
name = Path(sys.argv[0]).name
if os.environ.get('FAIL_COMMAND') == name:
 print('fixture command failure', file=sys.stderr); sys.exit(3)
if name == 'modinfo':
 field = args[args.index('-F')+1]; module = args[-1]
 if module == os.environ.get('MISSING_MODULE'): sys.exit(1)
 if field == 'vermagic' and module == os.environ.get('STALE_DEPENDENCY'):
  print('stale-kernel SMP'); sys.exit(0)
 print({'filename': str(Path(os.environ['MODULES'])/'7.3-test'/(module+'.ko')),
        'vermagic': os.environ.get('VERMAGIC', '7.3-test SMP'),
        'signer': '' if os.environ.get('UNSIGNED') else 'fixture signer',
        'version': '615.78.08'}[field])
elif name == 'modprobe':
 print('insmod '+os.environ.get('DEPENDENCY', str(Path(os.environ['MODULES'])/'7.3-test'/(args[-1]+'.ko'))))
elif name == 'pacman':
 assert args == ['-Q', 'nvidia-utils'], args
 print('nvidia-utils '+os.environ.get('NVIDIA_VERSION', '615.78.08-1'))
'''
        for cmd in ['modinfo', 'modprobe', 'pacman']:
            p = self.bin / cmd
            p.write_text(mock)
            p.chmod(0o755)
        self.env = dict(os.environ, PATH=str(self.bin)+':'+os.environ['PATH'], MODULES=str(self.modules))

    def run_cli(self, *args, **env):
        return subprocess.run([sys.executable, str(TOOL), *args], env=self.env | env,
                              capture_output=True, text=True)

    def audit(self, *args, **env):
        return self.run_cli('audit', '--release', self.release, '--modules-dir', str(self.modules), *args, **env)

    def test_audit_real_cli_and_faults(self):
        self.assertEqual(self.audit().returncode, 0)
        for env in [dict(FAIL_COMMAND='modprobe'), dict(MISSING_MODULE='spi_hid'),
                    dict(VERMAGIC='wrong SMP')]:
            with self.subTest(env=env):
                result = self.audit(**env)
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn('signature', self.audit(UNSIGNED='1').stdout)
        self.assertEqual(self.audit('--require-signatures', UNSIGNED='1').returncode, 1)
        self.assertEqual(self.audit('--module', 'nvidia').returncode, 0)
        self.assertEqual(self.audit('--module', 'nvidia', NVIDIA_VERSION='999-1').returncode, 1)
        self.assertEqual(self.audit(DEPENDENCY='/etc/passwd').returncode, 1)
        (self.base / 'build/include/config/kernel.release').write_text('stale')
        self.assertEqual(self.audit().returncode, 1)

    def make_uki(self, files=None, kernel=b'kernel-exact\0', release=b'7.3-test\0', extra=()):
        if files is None:
            files = {f'usr/lib/modules/{self.release}/{name.replace("_", "-")}.ko': name.encode()
                     for name in ['spi_hid', 'spi_hid_acpi']}
        p = self.root / 'fixture.efi'
        p.write_bytes(pe([('.uname', release), ('.linux', kernel),
                          ('.initrd', gzip.compress(cpio(files))), *extra]))
        return p

    def test_audit_checks_dependency_vermagic_by_exact_file_path(self):
        dependency = self.base / 'extra' / 'spi_hid.ko'
        dependency.parent.mkdir()
        dependency.write_bytes(b'stale copy with same module name')
        good = self.audit(DEPENDENCY=str(dependency))
        self.assertEqual(good.returncode, 0, good.stdout + good.stderr)
        bad = self.audit(DEPENDENCY=str(dependency), STALE_DEPENDENCY=str(dependency))
        self.assertEqual(bad.returncode, 1, bad.stdout + bad.stderr)
        self.assertIn(str(dependency), bad.stderr)
        self.assertNotIn('Kernel audit passed', bad.stdout)

    def test_usb4_rewrites_quoted_pci_values(self):
        for source in ['pci="nomsi,hpmmiosize=16M"',
                       '"pci=nomsi,hpmmiosize=16M"',
                       'pci="nomsi,other=two words,hpmmiosize=16M"']:
            with self.subTest(source=source):
                result = self.run_cli('usb4', '--cmdline', source)
                self.assertEqual(result.returncode, 0, result.stderr)
                expected = 'pci=nomsi,hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G'
                if 'other=' in source:
                    expected = 'pci="nomsi,other=two words,hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G"'
                self.assertEqual(result.stdout, expected + ' power_wrap_drv.usb4_release=0\n')
                self.assertEqual(self.run_cli('usb4', '--cmdline', result.stdout.rstrip('\n')).stdout,
                                 result.stdout)

    def test_usb4_preserves_init_suffix_exactly(self):
        suffix = '  --  pci="init,unchanged"  power_wrap_drv.usb4_release=1 "two words" single\'quote  '
        result = self.run_cli('usb4', '--cmdline', 'quiet pci=nomsi' + suffix)
        self.assertEqual(result.returncode, 0, result.stderr)
        expected = ('quiet pci=nomsi,hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G '
                    'power_wrap_drv.usb4_release=0' + suffix + '\n')
        self.assertEqual(result.stdout, expected)
        self.assertEqual(self.run_cli('usb4', '--cmdline', result.stdout.rstrip('\n')).stdout,
                         expected)
        for suffix in ['--', '--  arg="unfinished', '"--" pci=init']:
            with self.subTest(suffix=suffix):
                result = self.run_cli('usb4', '--cmdline=' + suffix)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(result.stdout,
                                 'pci=hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G '
                                 'power_wrap_drv.usb4_release=0 ' + suffix + '\n')

    def test_usb4_treats_single_quotes_as_literal_kernel_characters(self):
        result = self.run_cli('usb4', '--cmdline', "label=owner's pci=nomsi")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("label=owner's pci=nomsi,", result.stdout)

    def test_uki_exact_kernel_release_modules_and_early_dsp(self):
        self.assertEqual(self.audit('--uki', str(self.make_uki())).returncode, 0)
        compressed = {f'usr/lib/modules/{self.release}/spi_hid.ko.xz': lzma.compress(b'spi_hid'),
                      f'usr/lib/modules/{self.release}/spi_hid_acpi.ko.gz': gzip.compress(b'spi_hid_acpi')}
        self.assertEqual(self.audit('--uki', str(self.make_uki(files=compressed))).returncode, 0)
        for kwargs in [dict(kernel=b'kernel-exact\0extra'), dict(release=b'other\0'),
                       dict(extra=[('.uname', b'7.3-test\0')]),
                       dict(files={'usr/lib/modules/7.3-test/n1x_adsp.ko': b'dsp'}),
                       dict(files={'usr/lib/modules/7.3-test/n1x_npu_bootstrap.ko': b'npu'}),
                       dict(files={'usr/lib/modules/7.3-test/spi_hid.ko': b'stale'})]:
            with self.subTest(kwargs=kwargs):
                self.assertEqual(self.audit('--uki', str(self.make_uki(**kwargs))).returncode, 1)

    def test_kernel_authenticode_does_not_hide_content_changes(self):
        kernel = pe([('.text', b'actual kernel code')])
        (self.base / 'vmlinuz').write_bytes(kernel)
        signed = bytearray(kernel)
        cert = struct.pack('<IHH', 16, 0x200, 2) + b'fixture!'
        struct.pack_into('<II', signed, 0x98+112+4*8, len(signed), len(cert))
        struct.pack_into('<I', signed, 0x98+64, 12345)
        signed += cert
        self.assertEqual(self.audit('--uki', str(self.make_uki(kernel=signed))).returncode, 0)
        signed[0x400] ^= 1
        self.assertEqual(self.audit('--uki', str(self.make_uki(kernel=signed))).returncode, 1)

    def test_initrd_no_extraction_traversal_truncation_and_compression(self):
        loader = importlib.machinery.SourceFileLoader('tools_under_test', str(TOOL))
        spec = importlib.util.spec_from_loader(loader.name, loader)
        module = importlib.util.module_from_spec(spec)
        loader.exec_module(module)
        for data in [cpio({'../../escape': b'x'}), cpio({'safe': b'x'})[:-20], b'unknown']:
            with self.subTest(data=data[:10]):
                with self.assertRaises(ValueError): module.initrd_files(data)
        combined = cpio({'early_cpio': b'1'})
        combined += b'\0' * (-len(combined) % 512)
        combined += gzip.compress(cpio({'usr/file': b'value'}))
        self.assertEqual(module.initrd_files(combined)['usr/file'], b'value')
        early = cpio({'bin': (0o120777, b'usr/bin'), 'usr': (0o40755, b'')})
        overlay = early + gzip.compress(cpio({'bin': (0o120777, b'usr/bin'),
                                             'usr': (0o40700, b''), 'usr/file': b'ok'}))
        self.assertEqual(module.initrd_files(overlay)['usr/file'], b'ok')
        for tail in [{'bin': (0o120777, b'evil')},
                     {'bin': b'regular replacement'}]:
            with self.assertRaises(ValueError):
                module.initrd_files(early + cpio(tail))
        name = 'usr/lib/modules/7.3-test/spi-hid.ko'
        for content in [b'original', b'changed', (0o120777, b'elsewhere')]:
            with self.assertRaises(ValueError):
                module.initrd_files(cpio({name: b'original'}) + cpio({name: content}))
        data = cpio({'usr/file': b'value'})
        self.assertEqual(module.initrd_files(lzma.compress(data))['usr/file'], b'value')
        compressed = subprocess.check_output(['zstd', '-q', '-c'], input=data)
        self.assertEqual(module.initrd_files(compressed)['usr/file'], b'value')
        module.LIMIT = 8
        for compressed in [gzip.compress(data), lzma.compress(data), compressed]:
            with self.assertRaises(ValueError):
                module.decompress(compressed)

    def test_usb4_preserves_other_parameters_and_is_idempotent(self):
        source = 'root=UUID=abc quiet pci=nomsi,hpbussize=0x20,hpmemsize=8M,hpmmiosize=16M pci=hpmmioprefsize=1G power_wrap_drv.usb4_release=1 acpi_osi="!Windows 2022"'
        result = self.run_cli('usb4', '--cmdline', source)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('root=UUID=abc', result.stdout)
        self.assertIn('pci=nomsi,hpbussize=0x80,hpmmiosize=32M,hpmmioprefsize=32G', result.stdout)
        self.assertIn('acpi_osi="!Windows 2022"', result.stdout)
        self.assertIn('power_wrap_drv.usb4_release=0', result.stdout)
        self.assertNotIn('hpmemsize=', result.stdout)
        self.assertEqual(result.stdout.count('hpmmiosize='), 1)
        self.assertEqual(self.run_cli('usb4', '--cmdline', result.stdout.strip()).stdout, result.stdout)
        self.assertNotEqual(self.run_cli('usb4', '--cmdline', 'quiet\noptions: evil').returncode, 0)
        self.assertNotEqual(self.run_cli('usb4', '--cmdline', 'root="unclosed').returncode, 0)


if __name__ == '__main__':
    unittest.main()
