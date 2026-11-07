#!/usr/bin/python
"""Exercise reader-driven capture and verify physical sensor power states."""
import time
from pathlib import Path
import cv2

NODES = {'front': '/dev/video0', 'rear': '/dev/video1'}
SENSORS = {'front': 'i2c-OVTI5678:00', 'rear': 'i2c-OVTI8856:00'}


def states():
    return {k: Path('/sys/bus/i2c/devices', v, 'power/runtime_status').read_text().strip()
            for k, v in SENSORS.items()}


def expect(front, rear):
    wanted = {'front': front, 'rear': rear}
    deadline = time.monotonic() + 2
    while time.monotonic() < deadline:
        actual = states()
        if actual == wanted:
            print('PASS power', actual, flush=True)
            return
        time.sleep(.05)
    raise AssertionError((wanted, states()))


def open_camera(name):
    capture = cv2.VideoCapture(NODES[name], cv2.CAP_V4L2)
    if not capture.isOpened():
        raise RuntimeError(f'{name} cannot be opened')
    capture.set(cv2.CAP_PROP_FRAME_WIDTH, 1280)
    capture.set(cv2.CAP_PROP_FRAME_HEIGHT, 720)
    return capture


def live(capture, name):
    start = time.monotonic()
    deadline = start + 3
    while time.monotonic() < deadline:
        ok, frame = capture.read()
        if not ok:
            raise RuntimeError(f'{name}: no frame')
        if frame.max() > 10 and frame.std() > .5:
            print(f'PASS {name} live frame after {time.monotonic()-start:.3f}s', flush=True)
            return
    raise AssertionError(f'{name}: only idle black frames')


front = rear = None
try:
    expect('suspended', 'suspended')
    rear = open_camera('rear')
    live(rear, 'rear only')
    expect('suspended', 'active')
    rear.release(); rear = None
    expect('suspended', 'suspended')
    front = open_camera('front')
    live(front, 'front only')
    expect('active', 'suspended')
    rear = open_camera('rear')
    live(rear, 'rear alongside front')
    live(front, 'front alongside rear')
    expect('active', 'active')
    front.release(); front = None
    live(rear, 'rear after front closes')
    expect('suspended', 'active')
    front = open_camera('front')
    live(front, 'front reopened alongside rear')
    expect('active', 'active')
    rear.release(); rear = None
    live(front, 'front after rear closes')
    expect('active', 'suspended')
finally:
    if front is not None: front.release()
    if rear is not None: rear.release()
expect('suspended', 'suspended')
