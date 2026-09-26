"""Keep genuine driver/CUDA values while accommodating the vendor's old parser."""
import contextlib
import io
import subprocess
import unittest
from unittest.mock import patch
from helpers import load_script

module = load_script('nvidia-smi')


class VersionCompatibility(unittest.TestCase):
    def test_annotation_removed_without_changing_versions(self):
        original = 'Driver Version : 610.57.04 [Deprecated; will be removed]\nCUDA Version : 13.3 [Deprecated; use CUDA UMD Version instead]\nKMD Version : 610.57.04\nCUDA UMD Version : 13.3\nGPU 0000000F:01:00.0\n'
        expected = 'Driver Version : 610.57.04\nCUDA Version : 13.3\nKMD Version : 610.57.04\nCUDA UMD Version : 13.3\nGPU 0000000F:01:00.0\n'
        self.assertEqual(module.normalize(original), expected)
        self.assertEqual(module.normalize('CUDA Version : 12.8\n'), 'CUDA Version : 12.8\n')

    def test_driver_error_is_preserved(self):
        with patch.object(module.subprocess, 'run', return_value=subprocess.CompletedProcess([], 9, 'failed\n')), contextlib.redirect_stdout(io.StringIO()) as out:
            self.assertEqual(module.main(['-q', '--display=COMPUTE']), 9)
            self.assertEqual(out.getvalue(), 'failed\n')

    def test_other_operations_delegate(self):
        args = ['--query-gpu=name', '--format=csv,noheader']
        with patch.object(module.os, 'execv', side_effect=RuntimeError('delegated')) as execute:
            with self.assertRaises(RuntimeError):
                module.main(args)
            execute.assert_called_once_with('/usr/bin/nvidia-smi', ['/usr/bin/nvidia-smi', *args])


if __name__ == '__main__':
    unittest.main()
