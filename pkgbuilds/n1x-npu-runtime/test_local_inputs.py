#!/usr/bin/python
import importlib.util,tempfile
from pathlib import Path
p=Path(__file__).with_name('prepare-compiler.py');spec=importlib.util.spec_from_file_location('prepare',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp);(p/'bad').write_bytes(b'not a compiler')
 try:m.stage(p/'bad',p/'bad',p/'out')
 except ValueError:pass
 else:raise AssertionError('unknown binary accepted')
 assert not (p/'out').exists()
print('Unknown local compiler input refused before writes; no vendor input or hardware')
