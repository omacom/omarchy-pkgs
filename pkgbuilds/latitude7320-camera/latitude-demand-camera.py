#!/usr/bin/python
"""Keep virtual devices discoverable; capture only while clients stream them."""
import ctypes
import errno
import fcntl
import logging
import os
import signal
import struct
import sys

import gi

gi.require_version('Gst', '1.0')
from gi.repository import GLib, GLibUnix, Gst

Gst.init(None)
logging.basicConfig(level=logging.INFO, format='%(asctime)s %(message)s')
EVENT_USAGE = 0x08000000 + 0x08E00000 + 1


class EventData(ctypes.Union):
    _fields_ = [('data', ctypes.c_ubyte * 64), ('align', ctypes.c_uint64)]


class Timespec(ctypes.Structure):
    _fields_ = [('sec', ctypes.c_long), ('nsec', ctypes.c_long)]


class Event(ctypes.Structure):
    _fields_ = [('type', ctypes.c_uint32), ('u', EventData),
                ('pending', ctypes.c_uint32), ('sequence', ctypes.c_uint32),
                ('timestamp', Timespec), ('id', ctypes.c_uint32),
                ('reserved', ctypes.c_uint32 * 8)]


DQEVENT = 0x80000000 | (ctypes.sizeof(Event) << 16) | (ord('V') << 8) | 89
SUBSCRIBE = 0x40000000 | (32 << 16) | (ord('V') << 8) | 90
CAPS = 'video/x-raw,format=YUY2,width=1280,height=720,framerate=30/1'
BLACK = bytes((16, 128, 16, 128)) * (1280 * 720 // 2)


class Camera:
    def __init__(self, name, node, camera_id, fatal):
        self.name, self.node, self.camera_id = name, node, camera_id
        self.fatal = fatal
        self.capture = None
        self.latest = None
        self.demand = False
        self.stopping = False
        self.retry = 0
        self.watch = 0
        self.fd = -1
        # write() avoids the loopback/GStreamer mmap allocator issue at idle.
        self.writer_fd = os.open(node, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
        fmt = bytearray(208)  # v4l2_format, union aligned to 8 on x86_64.
        struct.pack_into('I', fmt, 0, 2)  # VIDEO_OUTPUT
        struct.pack_into('12I', fmt, 8, 1280, 720,
                         int.from_bytes(b'YUYV', 'little'), 1, 2560, len(BLACK),
                         3, 0, 0, 1, 2, 2)
        fcntl.ioctl(self.writer_fd, 0xc0d05605, fmt, True)  # VIDIOC_S_FMT
        parm = bytearray(204)
        struct.pack_into('I', parm, 0, 2)
        struct.pack_into('2I', parm, 12, 1, 30)
        fcntl.ioctl(self.writer_fd, 0xc0cc5616, parm, True)  # VIDIOC_S_PARM
        # Claim the virtual output stream so exclusive_caps advertises CAPTURE.
        os.write(self.writer_fd, BLACK)
        # Open event fd only, never read() or STREAMON on this observer.
        self.fd = os.open(node, os.O_RDWR | os.O_NONBLOCK | os.O_CLOEXEC)
        fcntl.ioctl(self.fd, SUBSCRIBE, struct.pack('8I', EVENT_USAGE, 0, 1, 0, 0, 0, 0, 0))
        self.watch = GLib.io_add_watch(self.fd, GLib.IOCondition.PRI | GLib.IOCondition.ERR,
                                      self.events)
        self.timer = GLib.timeout_add(33, self.publish)
        # SEND_INITIAL also accounts for applications already streaming at startup.
        self.events(self.fd, GLib.IOCondition.PRI)
        logging.info('%s virtual device ready; physical capture starts on demand', name)

    def events(self, fd, condition):
        try:
            while True:
                data = bytearray(ctypes.sizeof(Event))
                try:
                    fcntl.ioctl(fd, DQEVENT, data, True)
                except OSError as error:
                    if error.errno in (errno.EAGAIN, errno.ENOENT):
                        break
                    raise
                event = Event.from_buffer_copy(data)
                if event.type == EVENT_USAGE:
                    wanted = bool(struct.unpack_from('I', bytes(event.u.data))[0])
                    if wanted != self.demand:
                        self.demand = wanted
                        if wanted:
                            self.start_capture()
                        else:
                            self.stop_capture()
        except Exception:
            logging.exception('%s demand monitor failed', self.name)
            self.fatal()
            return False
        return True

    def sample(self, sink):
        sample = sink.emit('pull-sample')
        if sample is None:
            return Gst.FlowReturn.EOS
        self.latest = sample.get_buffer().copy_deep()
        return Gst.FlowReturn.OK

    def start_capture(self):
        if self.capture is not None or not self.demand or self.stopping:
            return
        logging.info('%s capture ON: application requested video', self.name)
        self.capture = Gst.parse_launch(
            'libcamerasrc name=sensor saturation=1.0 gamma=2.2 '
            '! video/x-raw,width=1280,height=720 '
            '! queue max-size-buffers=1 max-size-bytes=0 max-size-time=0 leaky=downstream '
            '! videoconvert ! video/x-raw,format=YUY2 '
            '! appsink name=capture emit-signals=true max-buffers=1 drop=true sync=false')
        self.capture.get_by_name('sensor').set_property('camera-name', self.camera_id)
        self.capture.get_by_name('capture').connect('new-sample', self.sample)
        bus = self.capture.get_bus()
        bus.add_signal_watch()
        bus.connect('message::error', self.capture_error)
        if self.capture.set_state(Gst.State.PLAYING) == Gst.StateChangeReturn.FAILURE:
            self.capture_error(bus, None)

    def capture_error(self, bus, message):
        if self.capture is None or self.capture.get_bus() != bus:
            return
        if message is not None:
            error, debug = message.parse_error()
            logging.error('%s capture failed: %s (%s)', self.name, error, debug)
        self.stop_capture()
        if self.demand and not self.stopping and not self.retry:
            self.retry = GLib.timeout_add_seconds(3, self.retry_capture)

    def retry_capture(self):
        self.retry = 0
        self.start_capture()
        return False

    def stop_capture(self):
        if self.retry:
            GLib.source_remove(self.retry)
            self.retry = 0
        if self.capture is not None:
            logging.info('%s capture OFF: sensor stopped', self.name)
            self.capture.set_state(Gst.State.NULL)
            self.capture.get_bus().remove_signal_watch()
            self.capture = None
        # Never keep a previous user's image as the idle virtual frame.
        self.latest = None

    def publish(self):
        frame = self.latest if self.demand else None
        data = frame.extract_dup(0, frame.get_size()) if frame is not None else BLACK
        try:
            if os.write(self.writer_fd, data) != len(data):
                raise RuntimeError('Short write to virtual camera')
        except Exception:
            logging.exception('%s virtual writer failed', self.name)
            self.fatal()
            return False
        return not self.stopping

    def close(self):
        self.stopping = True
        self.demand = False
        self.stop_capture()
        if self.watch:
            GLib.source_remove(self.watch)
        GLib.source_remove(self.timer)
        if self.fd >= 0:
            os.close(self.fd)
        os.close(self.writer_fd)


def main():
    if (open('/sys/class/dmi/id/sys_vendor').read().strip() != 'Dell Inc.' or
            open('/sys/class/dmi/id/product_name').read().strip() != 'Latitude 7320 Detachable'):
        raise RuntimeError('This camera service supports only the Latitude 7320 Detachable')
    for number, label in [(0, 'Latitude Front Camera'), (1, 'Latitude Rear Camera')]:
        with open(f'/sys/class/video4linux/video{number}/name') as name:
            if name.read().strip() != label:
                raise RuntimeError(f'/dev/video{number} is not the configured virtual camera')
    loop = GLib.MainLoop()
    cameras = []
    failed = False

    def fatal():
        nonlocal failed
        failed = True
        loop.quit()

    try:
        for name, node, camera_id in [
                ('front', '/dev/video0', r'\_SB_.PC00.LNK0'),
                ('rear', '/dev/video1', r'\_SB_.PC00.LNK1')]:
            cameras.append(Camera(name, node, camera_id, fatal))
        for signum in (signal.SIGTERM, signal.SIGINT):
            GLibUnix.signal_add(GLib.PRIORITY_DEFAULT, signum, lambda: (loop.quit(), False)[1])
        loop.run()
    finally:
        for camera in cameras:
            camera.close()
    return 1 if failed else 0


if __name__ == '__main__':
    sys.exit(main())
