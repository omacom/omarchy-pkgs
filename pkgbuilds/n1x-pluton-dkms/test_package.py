from pathlib import Path
import unittest
ROOT=Path(__file__).resolve().parent
class PackagingTests(unittest.TestCase):
 def test_manual_only(self):
  source=next(ROOT.glob('n1x_*.c')).read_text()
  self.assertNotIn('MODULE_DEVICE_TABLE(',source)
  for forbidden in ('*.service','*.install','*.modules'):
   self.assertFalse(list(ROOT.glob(forbidden)))
  self.assertIn('BUILD_EXCLUSIVE_ARCH="^aarch64$"',(ROOT/'dkms.conf').read_text())
 def test_typed_only(self):
  source=(ROOT/'n1x_pluton.c').read_text()
  self.assertIn('if (command == N1X_PLUTON_CHANNELS)\n\t\treturn -ENOTTY;',source)
  self.assertIn('p->misc.mode = 0600;',source)
if __name__=='__main__': unittest.main()
