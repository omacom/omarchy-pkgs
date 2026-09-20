"""Authorization cannot select another account or grant arbitrary service control."""
import importlib.machinery
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

path = Path(__file__).resolve().parents[1] / 'nvwb-spark-authorize'
loader = importlib.machinery.SourceFileLoader('authorize', str(path))
spec = importlib.util.spec_from_loader(loader.name, loader)
module = importlib.util.module_from_spec(spec)
loader.exec_module(module)


class Authorization(unittest.TestCase):
    def test_bad_names_are_rejected_before_lookup(self):
        with patch.object(module.pwd, 'getpwnam') as lookup:
            for name in ('', 'root ALL', 'alice*', '../alice', 'alice,root', 'alice\\nroot'):
                with self.assertRaises(ValueError):
                    module.account({'SUDO_USER': name, 'SUDO_UID': '1000'})
            lookup.assert_not_called()

    def test_identity_and_home_must_match(self):
        for uid, home, sudo_uid in ((0, '/home/alice', '0'), (1000, '/srv/alice', '1000'), (1000, '/home/alice', '1001')):
            with patch.object(module.pwd, 'getpwnam', return_value=SimpleNamespace(pw_uid=uid, pw_dir=home)):
                with self.assertRaises(ValueError):
                    module.account({'SUDO_USER': 'alice', 'SUDO_UID': sudo_uid})

    def test_policy_is_limited_to_own_packaged_unit(self):
        rule = module.policy('alice')
        self.assertEqual(rule, 'alice ALL=(root) NOPASSWD: /usr/bin/systemctl enable nvwb-spark@alice.service, /usr/bin/systemctl start nvwb-spark@alice.service, /usr/bin/systemctl stop nvwb-spark@alice.service\n')
        self.assertNotIn('*', rule)


if __name__ == '__main__':
    unittest.main()
