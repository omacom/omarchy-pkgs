"""Verify shipped POSIX rules and managed-rule upgrades without audio access."""
from pathlib import Path
import hashlib
import os
import re
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parent

class RulesTests(unittest.TestCase):
    def test_config_patterns(self):
        counts = {}
        for filename in ('speakers.conf', 'headphones.conf', '80-p16-internal-sinks.conf'):
            patterns = re.findall(r'node.name = "~([^"\n]+)"', (ROOT / filename).read_text())
            counts[filename] = len(patterns)
            for pattern in patterns:
                kind = 'Headphones' if 'Headphones' in pattern else 'Speaker'
                names = [(f'alsa_output.platform-mtk_sdw_mc{s}.HiFi__{e}__sink', kind == e)
                         for s in ('', '.3', '.10') for e in ('Speaker', 'Headphones')]
                names += [(n, False) for n in ('bluez_output.test',
                    'alsa_output.platform-other.3.HiFi__Speaker__sink',
                    'alsa_output.platform-mtk_sdw_mcX3.HiFi__Speaker__sink',
                    'alsa_output.platform-mtk_sdw_mc.3junk.HiFi__Speaker__sink',
                    'alsa_output.platform-mtk_sdw_mc.3.HiFi__Mic__source')]
                for name, match in names:
                    result = subprocess.run(['grep', '-E', '-x', pattern], input=name+'\n', text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0 if match else 1, (filename, name))
        self.assertEqual(counts, {'speakers.conf': 2, 'headphones.conf': 1, '80-p16-internal-sinks.conf': 2})

    def test_managed_upgrade_and_custom_symlink_preservation(self):
        with tempfile.TemporaryDirectory() as temp:
            home = Path(temp)
            rules = home/'wireplumber/wireplumber.conf.d/80-p16-internal-sinks.conf'
            rules.parent.mkdir(parents=True)
            config = ROOT/'80-p16-internal-sinks.conf'
            legacy = config.read_text()
            for endpoint in ('Speaker', 'Headphones'):
                legacy = legacy.replace('~^alsa_output[.]platform-mtk_sdw_mc([.][0-9]+)?[.]HiFi__'+endpoint+'__sink$', 'alsa_output.platform-mtk_sdw_mc.HiFi__'+endpoint+'__sink')
            self.assertEqual(hashlib.sha256(legacy.encode()).hexdigest(), '904c5d19be12d0277785c59cbd339854672652c4c0478a98215cdc600e9acac7')
            env = os.environ | {'XDG_CONFIG_HOME': str(home), 'P16_AUDIO_CONFIG_SOURCE': str(config), 'P16_AUDIO_SERVICE_SOURCE': '/test/jack.service'}
            def install():
                subprocess.run(['bash', str(ROOT/'install-user-config')], env=env, capture_output=True, check=True)
            rules.write_text(legacy)
            install()
            self.assertEqual(rules.read_bytes(), config.read_bytes())
            rules.write_text('custom\n')
            install()
            self.assertEqual(rules.read_text(), 'custom\n')
            rules.unlink()
            target = home/'other'
            target.write_text(legacy)
            rules.symlink_to(target)
            install()
            self.assertTrue(rules.is_symlink())
            self.assertEqual(target.read_text(), legacy)

if __name__ == '__main__':
    unittest.main()
