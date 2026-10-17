#!/usr/bin/python
"""Check camera visibility using ordinary user permissions and VIDIOC_QUERYCAP."""
import errno, fcntl, os, re
from pathlib import Path
names=[]
blocked=[]
for path in sorted(Path('/dev').glob('video[0-9]*'),key=lambda p:int(re.search(r'\d+$',p.name)[0])):
    try: fd=os.open(path,os.O_RDWR|os.O_NONBLOCK)
    except PermissionError:
        blocked.append(path.name)
        continue
    try:
        cap=bytearray(104)
        fcntl.ioctl(fd,0x80685600,cap,True)
        driver=bytes(cap[:16]).split(b'\0')[0].decode()
        name=bytes(cap[16:48]).split(b'\0')[0].decode()
        names.append(name)
        print('Accessible:',str(path),name,driver)
    finally: os.close(fd)
assert names == ['Latitude Front Camera','Latitude Rear Camera'], names
assert len(blocked)==64, blocked
assert not os.access('/dev/media0',os.R_OK|os.W_OK)
print('PASS: only front and rear cameras accessible; 64 raw nodes and media controller private')
