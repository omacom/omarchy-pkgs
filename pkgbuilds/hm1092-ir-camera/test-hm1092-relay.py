#!/usr/bin/python3
"""Unit tests for hm1092-relay: everything that does not need the hardware.

The relay is loaded straight from its file (it has no .py suffix). numpy is
optional here: the conversion tests are skipped without it, and the shell
suite says so.
"""

import contextlib
import importlib.machinery
import importlib.util
import io
import os
import signal
import socket
import struct
import sys
import tempfile
import time
import unittest
from unittest import mock

HERE = os.path.dirname(os.path.abspath(__file__))
sys.dont_write_bytecode = True  # keep __pycache__ out of the package directory
_loader = importlib.machinery.SourceFileLoader("relay", os.path.join(HERE, "hm1092-relay"))
_spec = importlib.util.spec_from_loader("relay", _loader)
relay = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(relay)

try:
    import numpy as np
except ImportError:  # pragma: no cover - depends on the machine
    np = None

TOPOLOGY = """Media controller API version 7.2.5

Media device information
------------------------
driver          intel-ipu7-isys
model           ipu7
bus info        PCI:0000:00:05.0

Device topology
- entity 1: Intel IPU7 CSI2 1 (2 pads, 5 links, 0 routes)
            type V4L2 subdev subtype Unknown flags 0
            device node name /dev/v4l-subdev0
\tpad0: Sink
\t\t<- "ov08x40 17-0036":0 [ENABLED,IMMUTABLE]
\tpad1: Source
\t\t-> "Intel IPU7 ISYS Capture 0":0 [ENABLED]
\t\t-> "Intel IPU7 ISYS Capture 1":0 []

- entity 4: Intel IPU7 CSI2 2 (2 pads, 5 links, 0 routes)
            type V4L2 subdev subtype Unknown flags 0
            device node name /dev/v4l-subdev1
\tpad0: Sink
\t\t[stream:0 fmt:SGRBG10_1X10/648x368 field:none colorspace:raw]
\t\t<- "hm1092 17-0024":0 [ENABLED,IMMUTABLE]
\tpad1: Source
\t\t-> "Intel IPU7 ISYS Capture 8":0 []
\t\t-> "Intel IPU7 ISYS Capture 9":0 []

- entity 40: ov08x40 17-0036 (1 pad, 1 link, 0 routes)
            type V4L2 subdev subtype Sensor flags 0
            device node name /dev/v4l-subdev7
\tpad0: Source
\t\t-> "Intel IPU7 CSI2 1":0 [ENABLED,IMMUTABLE]

- entity 43: hm1092 17-0024 (1 pad, 1 link, 0 routes)
            type V4L2 subdev subtype Sensor flags 0
            device node name /dev/v4l-subdev8
\tpad0: Source
\t\t[stream:0 fmt:SGRBG10_1X10/648x368 field:none colorspace:raw]
\t\t-> "Intel IPU7 CSI2 2":0 [ENABLED,IMMUTABLE]

- entity 50: Intel IPU7 ISYS Capture 8 (1 pad, 1 link)
            type Node subtype V4L flags 0
            device node name /dev/video8
\tpad0: Sink
\t\t<- "Intel IPU7 CSI2 2":1 []
"""


class FakeResult:
    def __init__(self, returncode=0, stdout="", stderr=""):
        self.returncode, self.stdout, self.stderr = returncode, stdout, stderr


class StructLayouts(unittest.TestCase):
    def test_sizes_match_the_kernel_headers(self):
        self.assertEqual(ctypes_size(relay.Format), 208)
        self.assertEqual(ctypes_size(relay.RequestBuffers), 20)
        self.assertEqual(ctypes_size(relay.Buffer), 88)
        self.assertEqual(ctypes_size(relay.EventSubscription), 32)
        self.assertEqual(ctypes_size(relay.Event), 136)

    def test_offsets_match_the_kernel_headers(self):
        self.assertEqual(relay.Format.fmt.offset, 8)
        self.assertEqual(relay.Buffer.m.offset, 64)
        self.assertEqual(relay.Buffer.length.offset, 72)
        self.assertEqual(relay.Event.u.offset, 8)
        self.assertEqual(relay.Event.pending.offset, 72)

    def test_client_usage_event_carries_the_consumer_count(self):
        event = relay.Event(type=relay.EVENT_CLIENT_USAGE)
        payload = struct.pack("<I", 3) + bytes(60)
        event.u = (relay.u8 * 64).from_buffer_copy(payload)
        self.assertEqual(relay.event_consumer_count(event), 3)


def ctypes_size(t):
    import ctypes
    return ctypes.sizeof(t)


class GraphParsing(unittest.TestCase):
    def setUp(self):
        self.graph = relay.Graph("/dev/media0", TOPOLOGY)

    def test_follows_the_sensor_to_its_capture_node(self):
        self.assertEqual(self.graph.sensor, "hm1092 17-0024")
        self.assertEqual(self.graph.sensor_subdev, "/dev/v4l-subdev8")
        self.assertEqual(self.graph.csi, "Intel IPU7 CSI2 2")
        self.assertEqual(self.graph.capture, "Intel IPU7 ISYS Capture 8")
        self.assertEqual(self.graph.capture_node, "/dev/video8")
        self.assertTrue(self.graph.complete)

    def test_ignores_the_rgb_sensor_on_the_other_port(self):
        self.assertNotEqual(self.graph.csi, "Intel IPU7 CSI2 1")

    def test_incomplete_without_the_sensor(self):
        graph = relay.Graph("/dev/media0", TOPOLOGY.replace("hm1092", "hm9999"))
        self.assertIsNone(graph.sensor)
        self.assertFalse(graph.complete)

    def test_configure_links_then_sets_formats_by_name(self):
        commands = self.graph.configure_commands(648, 368, "SGRBG10_1X10")
        self.assertEqual(commands[0], ["media-ctl", "-d", "/dev/media0", "-l",
                                       '"Intel IPU7 CSI2 2":1 -> "Intel IPU7 ISYS Capture 8":0 [1]'])
        self.assertEqual([c[4] for c in commands[1:]], [
            '"hm1092 17-0024":0 [fmt:SGRBG10_1X10/648x368]',
            '"Intel IPU7 CSI2 2":0 [fmt:SGRBG10_1X10/648x368]',
            '"Intel IPU7 CSI2 2":1 [fmt:SGRBG10_1X10/648x368]',
        ])

    def test_configure_stops_at_the_first_failing_command(self):
        calls = []

        def runner(argv):
            calls.append(argv)
            return FakeResult(1, stderr="Unable to setup formats: Invalid argument") if len(calls) == 2 else FakeResult()

        with self.assertRaises(RuntimeError) as ctx:
            self.graph.configure(648, 368, "SGRBG10_1X10", runner=runner)
        self.assertIn("Invalid argument", str(ctx.exception))
        self.assertEqual(len(calls), 2)

    def test_discover_picks_the_media_device_with_the_sensor(self):
        with tempfile.TemporaryDirectory() as dev:
            for name in ("media0", "media1", "video0"):
                open(os.path.join(dev, name), "w").close()
            graphs = {os.path.join(dev, "media0"): TOPOLOGY.replace("hm1092", "none"),
                      os.path.join(dev, "media1"): TOPOLOGY}

            def runner(argv):
                return FakeResult(0, graphs[argv[2]])

            graph = relay.Graph.discover(dev, runner=runner)
            self.assertEqual(graph.mdev, os.path.join(dev, "media1"))
            self.assertEqual(graph.sensor, "hm1092 17-0024")


class LoopbackLookup(unittest.TestCase):
    def setUp(self):
        self._log, relay.log = relay.log, lambda _m: None

    def tearDown(self):
        relay.log = self._log

    def make_sysfs(self, root, names):
        for node, name in names.items():
            d = os.path.join(root, "class", "video4linux", node)
            os.makedirs(d)
            with open(os.path.join(d, "name"), "w") as f:
                f.write(name + "\n")

    def test_finds_the_loopback_by_exact_name(self):
        with tempfile.TemporaryDirectory() as root:
            self.make_sysfs(root, {"video0": "Intel IPU7 ISYS Capture 0",
                                   "video50": "Hardware ISP Camera",
                                   "video51": "HM1092 IR Camera"})
            self.assertEqual(relay.find_video_by_name("HM1092 IR Camera", root, "/dev"), "/dev/video51")
            self.assertIsNone(relay.find_video_by_name("hm1092 ir camera", root, "/dev"))

    def test_ensure_creates_the_loopback_with_the_preferred_number(self):
        with tempfile.TemporaryDirectory() as root:
            dev = os.path.join(root, "dev")
            os.makedirs(dev)
            self.make_sysfs(root, {"video50": "Hardware ISP Camera"})
            cfg = relay.Config({"HM1092_SYS_ROOT": root, "HM1092_DEV_ROOT": dev})
            calls = []

            def runner(argv):
                calls.append(argv)
                self.make_sysfs(root, {"video51": "HM1092 IR Camera"})
                open(os.path.join(dev, "video51"), "w").close()
                return FakeResult()

            path = relay.ensure_loopback(cfg, runner=runner, sleep=lambda _s: None)
            self.assertEqual(path, os.path.join(dev, "video51"))
            self.assertEqual(calls, [["v4l2loopback-ctl", "add", "-n", "HM1092 IR Camera",
                                      "-x", "1", "-o", "10", os.path.join(dev, "video51")]])

    def test_ensure_falls_back_to_any_free_number(self):
        with tempfile.TemporaryDirectory() as root:
            dev = os.path.join(root, "dev")
            os.makedirs(dev)
            self.make_sysfs(root, {})
            cfg = relay.Config({"HM1092_SYS_ROOT": root, "HM1092_DEV_ROOT": dev})
            calls = []

            def runner(argv):
                calls.append(argv)
                if len(argv) == 9:
                    return FakeResult(1, stderr="busy")
                self.make_sysfs(root, {"video52": "HM1092 IR Camera"})
                open(os.path.join(dev, "video52"), "w").close()
                return FakeResult()

            path = relay.ensure_loopback(cfg, runner=runner, sleep=lambda _s: None)
            self.assertEqual(path, os.path.join(dev, "video52"))
            self.assertEqual(len(calls), 2)
            self.assertEqual(len(calls[1]), 8)

    def test_ensure_reports_a_loopback_that_never_appears(self):
        with tempfile.TemporaryDirectory() as root:
            dev = os.path.join(root, "dev")
            os.makedirs(dev)
            self.make_sysfs(root, {})
            cfg = relay.Config({"HM1092_SYS_ROOT": root, "HM1092_DEV_ROOT": dev})
            with self.assertRaises(RuntimeError):
                relay.ensure_loopback(cfg, runner=lambda argv: FakeResult(), sleep=lambda _s: None)


class FloodLedBudget(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.led = os.path.join(self.tmp.name, "HIMX1092_00::ir_flood_led")
        os.makedirs(self.led)
        with open(os.path.join(self.led, "brightness"), "w") as f:
            f.write("0\n")
        self.now = 1000.0
        self.messages = []
        self.lamp = relay.FloodLed(self.led, max_burst_s=8.0, duty_window_s=60.0,
                                   duty_fraction=0.5, clock=lambda: self.now, log=self.messages.append)

    def tearDown(self):
        self.tmp.cleanup()

    def brightness(self):
        with open(os.path.join(self.led, "brightness")) as f:
            return f.read()

    def test_on_and_off_write_the_sysfs_attribute(self):
        self.assertTrue(self.lamp.assert_on())
        self.assertEqual(self.brightness(), "1")
        self.lamp.set(False)
        self.assertEqual(self.brightness(), "0")

    def test_a_burst_ends_at_the_cap(self):
        self.lamp.assert_on()
        self.now += 7.9
        self.assertTrue(self.lamp.tick())
        self.now += 0.2
        self.assertFalse(self.lamp.tick())
        self.assertEqual(self.brightness(), "0")

    def test_a_capped_consumer_stays_dark_until_it_leaves(self):
        self.assertTrue(self.lamp.assert_on())
        self.now += 8.1
        self.assertFalse(self.lamp.tick())
        self.now += 0.2
        self.assertFalse(self.lamp.assert_on())
        self.assertEqual(self.brightness(), "0")
        self.lamp.end_session()
        self.assertTrue(self.lamp.assert_on())

    def test_a_rebuilt_source_does_not_restart_the_burst(self):
        self.lamp.assert_on()
        self.now += 5.0
        self.lamp.set(False)  # the stall path drops the source and darkens
        self.now += 0.1
        self.assertTrue(self.lamp.assert_on())
        self.now += 3.0
        self.assertFalse(self.lamp.tick())
        self.assertEqual(self.brightness(), "0")

    def test_holding_dark_is_logged_once(self):
        self.lamp.assert_on()
        self.now += 8.1
        self.lamp.tick()
        for _ in range(25):
            self.now += 0.2
            self.lamp.assert_on()
            self.lamp.tick()
        self.assertEqual(sum("held dark" in m for m in self.messages), 1, self.messages)

    def test_the_rolling_duty_budget_blocks_relighting(self):
        for _ in range(4):
            self.lamp.assert_on()
            self.now += 7.5
            self.lamp.end_session()
            self.now += 0.5
        self.assertFalse(self.lamp.assert_on())
        self.assertEqual(self.brightness(), "0")
        self.now += 40
        self.assertTrue(self.lamp.assert_on())

    def test_rejects_limits_that_would_disable_the_safeguards(self):
        for limits in ({"duty_fraction": 5}, {"duty_fraction": 0}, {"duty_fraction": float("nan")},
                       {"max_burst_s": 0}, {"max_burst_s": -1}, {"max_burst_s": float("inf")},
                       {"duty_window_s": 0}, {"duty_window_s": float("inf")}):
            with self.subTest(**limits), self.assertRaises(ValueError):
                relay.FloodLed(self.led, **limits)

    def test_off_is_tolerated_when_the_attribute_vanished(self):
        self.lamp.assert_on()
        os.remove(os.path.join(self.led, "brightness"))
        self.assertFalse(self.lamp.set(False))
        self.assertFalse(self.lamp.on)

    def test_find_flood_led_matches_the_int3472_name(self):
        root = os.path.join(self.tmp.name, "sys")
        os.makedirs(os.path.join(root, "class", "leds", "input3::capslock"))
        os.makedirs(os.path.join(root, "class", "leds", "HIMX1092_00::ir_flood_led"))
        self.assertEqual(relay.find_flood_led(root),
                         os.path.join(root, "class", "leds", "HIMX1092_00::ir_flood_led"))
        self.assertIsNone(relay.find_flood_led(os.path.join(root, "nowhere")))


class ConfigFromEnvironment(unittest.TestCase):
    def test_defaults_match_the_shipped_conf(self):
        cfg = relay.Config({})
        self.assertEqual((cfg.card_label, cfg.width, cfg.height, cfg.video_nr),
                         ("HM1092 IR Camera", 648, 368, 51))
        self.assertFalse(cfg.rotate180)
        self.assertFalse(cfg.fixed_scale)
        self.assertEqual(cfg.max_burst_s, 8.0)
        self.assertEqual((cfg.sys_root, cfg.dev_root), ("/sys", "/dev"))

    def test_shipped_conf_parses_to_the_same_values(self):
        env = {}
        with open(os.path.join(HERE, "hm1092-ir-camera.conf")) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#"):
                    key, _, value = line.partition("=")
                    env[key] = value.strip('"')
        cfg = relay.Config(env)
        defaults = relay.Config({})
        for attr in ("card_label", "width", "height", "video_nr", "rotate180", "fixed_scale",
                     "ir_led", "max_burst_s", "duty_window_s", "duty_fraction"):
            self.assertEqual(getattr(cfg, attr), getattr(defaults, attr), attr)

    def test_overrides_and_empty_values(self):
        cfg = relay.Config({"ROTATE180": "1", "WIDTH": "1296", "HEIGHT": "736", "IR_LED": ""})
        self.assertTrue(cfg.rotate180)
        self.assertEqual((cfg.width, cfg.height), (1296, 736))
        self.assertEqual(cfg.ir_led, "")


class FakeSink:
    """The loopback, driven by a script of (seconds since start, consumer count)
    events. Its fd is always readable, so main() never sleeps in select()."""

    def __init__(self, script, stop_after):
        self.script, self.stop_after = list(script), stop_after
        self.r, self.w = os.pipe()
        os.write(self.w, b"x")
        self.start = None
        self.writes = []

    def fileno(self):
        return self.r

    def elapsed(self):
        return time.monotonic() - self.start

    def pending_events(self):
        if self.start is None:
            self.start = time.monotonic()
        if self.elapsed() >= self.stop_after:
            os.kill(os.getpid(), signal.SIGTERM)
        due = [count for at, count in self.script if at <= self.elapsed()]
        self.script = [(at, count) for at, count in self.script if at > self.elapsed()]
        return due

    def write(self, frame):
        data = bytes(frame)
        at = None if self.start is None else self.elapsed()  # None: the priming frame
        self.writes.append((at, data.count(0) == len(data)))

    def close(self):
        os.close(self.r)
        os.close(self.w)


class FakeCapture:
    stride = 1344

    def __init__(self, _path, width, height):
        self.r, self.w = os.pipe()
        os.write(self.w, b"x")
        self.frame = bytes([0x90, 0x01]) * (self.stride // 2 * height)

    def fileno(self):
        return self.r

    def read(self):
        return self.frame

    def close(self):
        os.close(self.r)
        os.close(self.w)


@unittest.skipUnless(np is not None, "python-numpy is not installed")
class RelayLoop(unittest.TestCase):
    """main() against a fake loopback and capture, with a 50 ms burst."""

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        led = os.path.join(self.tmp.name, "class", "leds", "HIMX1092_00::ir_flood_led")
        os.makedirs(led)
        with open(os.path.join(led, "brightness"), "w") as f:
            f.write("0")
        self.env = {"HM1092_SYS_ROOT": self.tmp.name, "MAX_ILLUMINATION_MS": "50"}

    def tearDown(self):
        signal.signal(signal.SIGTERM, signal.SIG_DFL)
        signal.signal(signal.SIGINT, signal.default_int_handler)
        self.tmp.cleanup()

    def run_relay(self, sink):
        graph = mock.Mock(complete=True, capture_node="/dev/video8", sensor="hm1092",
                          csi="Intel IPU7 CSI2 2", capture="Intel IPU7 ISYS Capture 8")
        with mock.patch.dict(os.environ, self.env, clear=True), \
                mock.patch.object(relay.Graph, "discover", return_value=graph), \
                mock.patch.object(relay, "ensure_loopback", return_value="/dev/video51"), \
                mock.patch.object(relay, "Loopback", return_value=sink), \
                mock.patch.object(relay, "Capture", FakeCapture), \
                mock.patch.object(relay, "TICK_S", 0.01), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(relay.main([]), 0)
        return [(at, black) for at, black in sink.writes if at is not None]

    def test_a_consumer_held_dark_keeps_receiving_frames(self):
        writes = self.run_relay(FakeSink([(0, 1)], stop_after=0.3))
        last_live = max(at for at, black in writes if not black)
        self.assertLess(last_live, 0.2)
        dark_after_cap = [at for at, black in writes if black and at > last_live]
        self.assertGreater(len(dark_after_cap), 5)
        self.assertGreater(max(dark_after_cap), 0.25)

    def test_the_burst_starts_over_for_the_next_consumer(self):
        writes = self.run_relay(FakeSink([(0, 1), (0.15, 0), (0.2, 1)], stop_after=0.35))
        self.assertTrue(any(not black and at < 0.1 for at, black in writes))
        self.assertTrue(any(not black and at >= 0.2 for at, black in writes))


class Readiness(unittest.TestCase):
    def notify(self, notify_socket):
        env = {} if notify_socket is None else {"NOTIFY_SOCKET": notify_socket}
        with mock.patch.dict(os.environ, env, clear=True), \
                mock.patch.object(relay.socket, "socket") as factory:
            relay.sd_notify("READY=1")
        return factory, factory.return_value.__enter__.return_value

    def test_sd_notify_sends_a_datagram_to_the_notify_socket(self):
        factory, sk = self.notify("/run/systemd/notify")
        factory.assert_called_once_with(socket.AF_UNIX, socket.SOCK_DGRAM)
        sk.connect.assert_called_once_with("/run/systemd/notify")
        sk.sendall.assert_called_once_with(b"READY=1")

    def test_sd_notify_maps_an_abstract_address(self):
        _factory, sk = self.notify("@/org/freedesktop/systemd1/notify")
        sk.connect.assert_called_once_with("\0/org/freedesktop/systemd1/notify")

    def test_sd_notify_is_silent_outside_systemd(self):
        factory, _sk = self.notify(None)
        factory.assert_not_called()


class ScaleCadence(unittest.TestCase):
    def test_skips_unsettled_frames_then_slows_down(self):
        self.assertEqual([relay.scale_due(f) for f in (0, 1, 2)], [False] * 3)
        self.assertTrue(all(relay.scale_due(f) for f in range(3, 13)))
        self.assertTrue(relay.scale_due(30))
        self.assertFalse(relay.scale_due(31))


@unittest.skipUnless(np is not None, "python-numpy is not installed")
class Conversion(unittest.TestCase):
    W, H, STRIDE = 648, 368, 1344

    def frame(self, value):
        rows = np.full((self.H, self.STRIDE // 2), value, dtype="<u2")
        return rows.tobytes() + bytes(self.STRIDE)  # the IPU appends a spare line

    def test_plain_shift_honours_the_padded_stride(self):
        raw = np.zeros((self.H, self.STRIDE // 2), dtype="<u2")
        raw[:, :self.W] = np.arange(self.W, dtype="<u2") % 1024
        raw[:, self.W:] = 1023  # padding must never leak into the image
        gray = relay.to_gray8(raw.tobytes() + bytes(self.STRIDE), self.W, self.H, self.STRIDE, None, False)
        self.assertEqual(gray.shape, (self.H, self.W))
        self.assertEqual(int(gray[0, 400]), 400 >> 2)
        self.assertEqual(int(gray[5, 647]), 647 >> 2)

    def test_rotation_turns_the_frame_upside_down(self):
        raw = np.zeros((self.H, self.STRIDE // 2), dtype="<u2")
        raw[0, 0] = 1020
        gray = relay.to_gray8(raw.tobytes(), self.W, self.H, self.STRIDE, None, True)
        self.assertEqual(int(gray[self.H - 1, self.W - 1]), 255)
        self.assertEqual(int(gray[0, 0]), 0)

    def test_autoscale_maps_the_bright_percentile_near_235(self):
        raw = relay.as_u16(self.frame(280), self.W, self.H, self.STRIDE)
        scale = relay.compute_scale(raw)
        gray = relay.to_gray8(self.frame(280), self.W, self.H, self.STRIDE, scale, False)
        self.assertEqual(int(gray[10, 10]), 235)

    def test_autoscale_ignores_a_saturated_region(self):
        raw = relay.as_u16(self.frame(280), self.W, self.H, self.STRIDE).copy()
        raw[:40, :] = 1023  # a window in frame
        self.assertAlmostEqual(relay.compute_scale(raw), 235.0 / 280.0, places=5)

    def test_autoscale_declines_a_black_frame(self):
        raw = relay.as_u16(self.frame(0), self.W, self.H, self.STRIDE)
        self.assertIsNone(relay.compute_scale(raw))


if __name__ == "__main__":
    unittest.main()
