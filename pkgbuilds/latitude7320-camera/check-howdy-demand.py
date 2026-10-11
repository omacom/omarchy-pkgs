#!/usr/bin/python
"""Verify Howdy's actual recorder can wake the front camera from idle."""
import sys, time
from pathlib import Path
sys.path.insert(0, '/usr/local/lib/howdy')
from recorders.video_capture import VideoCapture
sensor = Path('/sys/bus/i2c/devices/i2c-OVTI5678:00/power/runtime_status')
rear = Path('/sys/bus/i2c/devices/i2c-OVTI8856:00/power/runtime_status')
assert sensor.read_text().strip() == 'suspended'
start = time.monotonic()
camera = VideoCapture('/etc/howdy/config.ini')
try:
    while time.monotonic()-start < 4:
        frame, gray = camera.read_frame()
        if frame.max()>10 and frame.std()>.5:
            print(f'PASS Howdy recorder live in {time.monotonic()-start:.3f}s')
            assert rear.read_text().strip() == 'suspended'
            break
    else: raise AssertionError('Howdy did not receive live frames within its timeout')
finally:
    camera.release()
deadline = time.monotonic()+2
while sensor.read_text().strip() != 'suspended' and time.monotonic()<deadline:
    time.sleep(.05)
assert sensor.read_text().strip() == 'suspended'
assert rear.read_text().strip() == 'suspended'
print('PASS Howdy release leaves both sensors suspended')
