#!/usr/bin/python
"""Refresh udev after the virtual writers advertise capture capabilities."""
import fcntl, os, struct, subprocess, time
for node in ('/dev/video0','/dev/video1'):
    deadline=time.monotonic()+5
    while True:
        fd=os.open(node,os.O_RDWR|os.O_NONBLOCK)
        try:
            cap=bytearray(104)
            fcntl.ioctl(fd,0x80685600,cap,True)
            if struct.unpack_from('I',cap,88)[0] & 1: break
        finally: os.close(fd)
        if time.monotonic()>deadline: raise RuntimeError(node+' did not advertise capture')
        time.sleep(.05)
# Re-announce the virtual feeds: multimedia monitors cache initial output-only caps.
for action in ('remove','add'):
    subprocess.run(['/usr/bin/udevadm','trigger','--action='+action,'--subsystem-match=video4linux','--sysname-match=video[01]'],check=True)
    subprocess.run(['/usr/bin/udevadm','settle'],check=True)
