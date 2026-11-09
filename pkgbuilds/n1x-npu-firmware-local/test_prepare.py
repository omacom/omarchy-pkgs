#!/usr/bin/python
import importlib.util,struct,tempfile
from pathlib import Path
p=Path(__file__).with_name('prepare-firmware.py')
spec=importlib.util.spec_from_file_location('firmware',p);m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m)
data=bytearray(512);struct.pack_into('<I',data,0x3c,64);data[64:68]=b'PE\0\0';struct.pack_into('<HH',data,68,0xaa64,1);struct.pack_into('<IIII',data,96,16,0x1000,16,256);data[256:272]=bytes(range(16))
assert m.pe_slice(data,0x1004,4)==bytes(range(4,8))
for rva,size in ((0x100f,2),(0x2000,4)):
 try:m.pe_slice(data,rva,size)
 except ValueError:pass
 else:raise AssertionError('accepted invalid section bounds')
with tempfile.TemporaryDirectory() as tmp:
 p=Path(tmp);(p/'bad.sys').write_bytes(data)
 try:m.prepare(p/'bad.sys',p/'out')
 except ValueError:pass
 else:raise AssertionError('accepted unpinned KMD')
 assert not (p/'out').exists()
print('PE bounds and unpinned KMD rejection passed; no vendor input or hardware')
