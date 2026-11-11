#!/usr/bin/python
"""Exercise the packaged lifecycle controller with a private sysfs tree."""
from contextlib import redirect_stderr
import io
from pathlib import Path
import sys
import tempfile
import types
import unittest
from unittest.mock import patch


CONTROL_SOURCE = Path(__file__).with_name("n1x-npu-control").read_text()


class ControlTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)

        def hardware_path(*parts):
            path = Path(*parts)
            if path.is_absolute() and path.parts[1] in ("sys", "dev"):
                return self.root / path.relative_to("/")
            raise AssertionError(f"Unexpected hardware path: {path}")

        # Redirect both default arguments and explicit absolute paths at import.
        self.control = types.ModuleType("n1x_control_under_test")
        with patch("pathlib.Path", hardware_path):
            exec(compile(CONTROL_SOURCE, "n1x-npu-control", "exec"), self.control.__dict__)
        self.run = self.enterContext(patch.object(self.control.subprocess, "run", autospec=True))
        self.enterContext(patch.object(self.control.os, "uname", return_value=types.SimpleNamespace(machine="aarch64")))
        self.dla = self.endpoint("dla", "NVDA200A", "1")
        self.sroot = self.endpoint("sroot", "NVDA8600", "2")
        self.controls = [self.root / f"sys/kernel/iommu_groups/{number}/type" for number in (1, 2)]

    def endpoint(self, name, hid, group_number):
        device = self.root / "sys/bus/platform/devices" / name
        (device / "firmware_node").mkdir(parents=True)
        (device / "firmware_node/hid").write_text(hid)
        (device / "iommu").mkdir()
        group = self.root / "sys/kernel/iommu_groups" / group_number
        (group / "devices").mkdir(parents=True)
        (group / "devices" / name).symlink_to(device, target_is_directory=True)
        (group / "type").write_text("identity\n")
        (device / "iommu_group").symlink_to(group, target_is_directory=True)
        return device

    def invoke(self, action):
        with patch.object(self.control.sys, "argv", ["n1x-npu-control", action]), redirect_stderr(io.StringIO()):
            return self.control.main()

    def assert_unmodified(self):
        self.assertEqual([path.read_text() for path in self.controls], ["identity\n", "identity\n"])
        self.run.assert_not_called()

    def bind(self, device, driver="n1x-npu-bootstrap"):
        target = self.root / "sys/bus/platform/drivers" / driver
        target.mkdir(parents=True, exist_ok=True)
        (device / "driver").symlink_to(target, target_is_directory=True)

    def shutdown_state(self, text):
        (self.root / "sys/module/n1x_npu_bootstrap").mkdir(parents=True)
        self.bind(self.dla)
        (self.dla / "shutdown").write_text("")
        status = self.root / "sys/kernel/debug/n1x-npu-bootstrap/shutdown_status"
        status.parent.mkdir(parents=True)
        status.write_text(text)

    def test_prepare_selects_dma_for_two_isolated_groups(self):
        self.assertEqual(self.invoke("--prepare"), 0)
        self.assertEqual([path.read_text() for path in self.controls], ["DMA\n", "DMA\n"])
        self.run.assert_not_called()

    def test_prepare_preserves_existing_dma_domains(self):
        for path, domain in zip(self.controls, ("DMA\n", "DMA-FQ\n")):
            path.write_text(domain)
        self.assertEqual(self.invoke("--prepare"), 0)
        self.assertEqual([path.read_text() for path in self.controls], ["DMA\n", "DMA-FQ\n"])
        self.run.assert_not_called()

    def test_shared_iommu_group_refuses_prepare(self):
        group = (self.dla / "iommu_group").resolve()
        (group / "devices/sroot").symlink_to(self.sroot, target_is_directory=True)
        (self.sroot / "iommu_group").unlink()
        (self.sroot / "iommu_group").symlink_to(group, target_is_directory=True)
        self.assertEqual(self.invoke("--prepare"), 1)
        self.assert_unmodified()

    def test_invalid_second_group_never_writes_either_domain(self):
        self.controls[1].write_text("blocked\n")
        # Admission succeeds, then the second group changes before preparation.
        # This tests main's second validation, independently of the admission gate.
        original_read = Path.read_text
        original_write = Path.write_text
        reads = 0
        writes = []

        def read(path, *args, **kwargs):
            nonlocal reads
            if path == self.controls[1]:
                reads += 1
                if reads == 1:
                    return "identity\n"
            return original_read(path, *args, **kwargs)

        def write(path, *args, **kwargs):
            writes.append(path)
            return original_write(path, *args, **kwargs)

        with patch.object(Path, "read_text", read), patch.object(Path, "write_text", write):
            with self.assertRaises(RuntimeError):
                self.invoke("--prepare")
        self.assertEqual(writes, [])
        self.assertEqual(self.controls[0].read_text(), "identity\n")
        self.assertEqual(self.controls[1].read_text(), "blocked\n")
        self.run.assert_not_called()

    def test_partial_binding_refuses_domain_changes(self):
        for device in (self.dla, self.sroot):
            with self.subTest(bound=device.name):
                self.bind(device)
                try:
                    with self.assertRaisesRegex(RuntimeError, "Partially bound"):
                        self.invoke("--prepare")
                    self.assert_unmodified()
                finally:
                    (device / "driver").unlink()

    def test_refused_shutdown_never_unloads_module(self):
        safe = dict(hardware_off="1", released="1", error="0", hfrp_held="0", upload_held="0")
        self.shutdown_state("")
        status = self.root / "sys/kernel/debug/n1x-npu-bootstrap/shutdown_status"
        for field in safe:
            for replacement in (None, "0" if safe[field] == "1" else "1"):
                with self.subTest(field=field, value=replacement):
                    state = dict(safe)
                    if replacement is None:
                        del state[field]
                    else:
                        state[field] = replacement
                    status.write_text(" ".join(f"{key}={value}" for key, value in state.items()))
                    with self.assertRaises(RuntimeError):
                        self.invoke("--stop")
                    self.assertEqual((self.dla / "shutdown").read_text(), "stop\n")
                    self.run.assert_not_called()

    def test_safe_shutdown_unloads_after_stop(self):
        self.shutdown_state("hardware_off=1 released=1 error=0 hfrp_held=0 upload_held=0\n")

        def unload(command, *, check):
            self.assertEqual((self.dla / "shutdown").read_text(), "stop\n")
            self.assertEqual(command, ["/usr/bin/modprobe", "-r", "n1x_npu_bootstrap"])
            self.assertTrue(check)

        self.run.side_effect = unload
        self.assertEqual(self.invoke("--stop"), 0)
        self.run.assert_called_once()

    def test_wrong_driver_refuses_shutdown_without_request(self):
        self.shutdown_state("hardware_off=1 released=1 error=0 hfrp_held=0 upload_held=0\n")
        (self.dla / "driver").unlink()
        self.bind(self.dla, "other-driver")
        with self.assertRaisesRegex(RuntimeError, "Wrong driver"):
            self.invoke("--stop")
        self.assertEqual((self.dla / "shutdown").read_text(), "")
        self.run.assert_not_called()


def check_mutations():
    """Prove each safety regression fails its focused behavioral test."""
    global CONTROL_SOURCE
    original = CONTROL_SOURCE
    mutations = (
        ("shared group admitted", "test_shared_iommu_group_refuses_prepare",
         'if len(members) != 1 or members[0].resolve(strict=True) != device.resolve(strict=True):',
         'if False:'),
        ("lazy group validation writes first domain", "test_invalid_second_group_never_writes_either_domain",
         'controls.append(control)', 'yield control'),
        ("partial binding accepted", "test_partial_binding_refuses_domain_changes",
         'elif bound:', 'elif False:'),
        ("shutdown safety check skipped", "test_refused_shutdown_never_unloads_module",
         '        require_fields(Path("/sys/kernel/debug/n1x-npu-bootstrap/shutdown_status"),\n'
         '                       ("hardware_off", "released"), ("error", "hfrp_held", "upload_held"))',
         '        pass'),
    )
    try:
        for description, method, before, after in mutations:
            if original.count(before) != 1:
                raise AssertionError(f"Mutation target changed: {description}")
            CONTROL_SOURCE = original.replace(before, after)
            output = io.StringIO()
            result = unittest.TextTestRunner(stream=output).run(ControlTests(method))
            if not result.failures or result.errors:
                raise AssertionError(f"Mutation not caught by assertion: {description}\n{output.getvalue()}")
            print(f"Detected mutation: {description}")
    finally:
        CONTROL_SOURCE = original


if __name__ == "__main__":
    if sys.argv[1:] == ["--mutations"]:
        check_mutations()
    else:
        unittest.main()
