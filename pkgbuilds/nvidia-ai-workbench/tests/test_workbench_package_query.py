"""The Workbench compatibility query must reflect installed Arch packages only."""
import contextlib
import io
import subprocess
import sys
import unittest
from unittest.mock import patch
from helpers import load_script


class PackageQuery(unittest.TestCase):
    def invoke(self, args, result):
        out = io.StringIO()
        with patch.object(sys, 'argv', ['dpkg-query', *args]), patch('subprocess.run', return_value=result) as run, contextlib.redirect_stdout(out):
            load_script('dpkg-query')
        return out.getvalue(), run

    def test_installed_status_comes_from_pacman(self):
        out, run = self.invoke(['-Wf', '${db:Status-Status}\\n', 'nvidia-container-toolkit'], subprocess.CompletedProcess([], 0, 'nvidia-container-toolkit 1.20.0-1\n', ''))
        self.assertEqual(out, 'installed\n')
        self.assertEqual(run.call_args.args[0], ['/usr/bin/pacman', '-Q', 'nvidia-container-toolkit'])

    def test_missing_package_is_not_claimed_installed(self):
        with self.assertRaises(SystemExit) as error:
            self.invoke(['-Wf', '${db:Status-Status}\\n', 'nvidia-container-toolkit'], subprocess.CompletedProcess([], 1, '', 'missing'))
        self.assertEqual(error.exception.code, 1)

    def test_unrecognized_packages_and_options_fail(self):
        for args in [['--list'], ['-Wf', '${Version}', 'nvidia-driver-999'], ['--install', 'anything']]:
            with self.subTest(args=args), self.assertRaises(SystemExit):
                self.invoke(args, None)


if __name__ == '__main__':
    unittest.main()
