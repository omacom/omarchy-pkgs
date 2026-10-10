"""Native readiness must not swallow failures or intercept remote/custom contexts."""
import io
import json
import subprocess
import unittest
from unittest.mock import patch
from helpers import load_script

module = load_script('nvwb-cli-spark')


class Delegated(Exception):
    pass


class NativeReadiness(unittest.TestCase):
    def test_running_local_service_needs_no_start(self):
        with patch.object(module, 'ready', return_value=True), patch.object(module.subprocess, 'run') as run:
            self.assertEqual(module.main(['internal', 'ensure-context-ready', 'local']), 0)
            run.assert_not_called()

    def test_start_failure_is_not_reported_ready(self):
        with patch.object(module, 'ready', return_value=False), patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 7)):
            self.assertEqual(module.main(['internal', 'ensure-context-ready', 'local']), 7)

    def test_other_contexts_and_directories_delegate_unchanged(self):
        cases = [
            ['internal', 'ensure-context-ready', 'remote'],
            ['--workbench-dir', '/tmp/other-context', 'internal', 'ensure-context-ready', 'local'],
            ['--workbench-dir=/tmp/other-context', 'internal', 'ensure-context-ready', 'local'],
            ['-c', 'local', 'build'],
        ]
        for args in cases:
            with self.subTest(args=args), patch.object(module.os, 'execv', side_effect=Delegated) as execute:
                with self.assertRaises(Delegated):
                    module.main(args)
                execute.assert_called_once_with(module.VENDOR, [module.VENDOR, *args])

    def test_readiness_requires_matching_user_and_version(self):
        for data, expected in [({'username': 'owner', 'version': '1'}, True), ({'username': 'someone-else', 'version': '1'}, False), ({'username': 'owner'}, False)]:
            with self.subTest(data=data), patch.object(module.getpass, 'getuser', return_value='owner'), patch.object(module.urllib.request, 'build_opener') as opener:
                opener.return_value.open.return_value = io.StringIO(json.dumps(data))
                self.assertEqual(module.ready(), expected)

    def test_unreachable_service_is_not_ready(self):
        with patch.object(module.urllib.request, 'build_opener') as opener:
            opener.return_value.open.side_effect = OSError('refused')
            self.assertFalse(module.ready())


if __name__ == '__main__':
    unittest.main()
