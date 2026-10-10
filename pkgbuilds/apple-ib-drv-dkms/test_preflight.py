# SPDX-License-Identifier: GPL-2.0-only
"""Synthetic sysfs only; never invoke a real device operation."""

import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import patch

HERE = Path(__file__).resolve().parent
loader = importlib.machinery.SourceFileLoader("preflight", str(HERE / "apple-ib-drv-preflight"))
spec = importlib.util.spec_from_loader(loader.name, loader)
preflight = importlib.util.module_from_spec(spec)
loader.exec_module(preflight)


class PreflightTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="t1-preflight-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        for name in ("bus/usb/devices", "bus/hid/devices", "bus/hid/drivers", "module"):
            (self.root / name).mkdir(parents=True)
        self.put("class/dmi/id/product_name", "MacBookPro14,3")
        self.usb = self.root / "devices/usb1/1-3"
        for name, value in (("idVendor", "05ac"), ("idProduct", "8600"),
                            ("devnum", "7"), ("bConfigurationValue", "1")):
            self.put(self.usb / name, value)
        (self.root / "bus/usb/devices/1-3").symlink_to(self.usb)
        self.physical = self.usb / "1-3:1.2/0003:05AC:8600.0001"
        self.virtual = self.physical / "0003:1D6B:0301.0002"
        for path in (self.physical, self.virtual):
            path.mkdir(parents=True, exist_ok=True)
            (self.root / "bus/hid/devices" / path.name).symlink_to(path)
            self.bind(path, "hid-generic")

    def put(self, name, value):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value + "\n")

    def bind(self, node, name):
        driver = self.root / "bus/hid/drivers" / name
        driver.mkdir(exist_ok=True)
        (node / "driver").unlink(missing_ok=True)
        (node / "driver").symlink_to(driver)

    def check(self, status, reason=None):
        report = preflight.inspect(self.root)
        self.assertEqual(report["status"], status, report)
        if reason:
            self.assertIn(reason, " ".join(report["reasons"]))
        return report

    def test_models_are_informational(self):
        for model in ("MacBookPro13,3", "MacBookPro14,3", "unknown-model"):
            with self.subTest(model=model):
                self.put("class/dmi/id/product_name", model)
                self.assertEqual(self.check("checks-passed")["model"], model)

    def test_absent_dmi_does_not_claim_a_model(self):
        (self.root / "class/dmi/id/product_name").unlink()
        report = self.check("checks-passed")
        self.assertIsNone(report["model"])
        self.assertEqual(report["model_observation"], "FileNotFoundError")

    def test_no_matching_device_including_other_apple_product(self):
        self.put(self.usb / "idProduct", "8302")
        self.check("not-applicable")

    def test_malformed_identity_is_unavailable(self):
        self.put(self.usb / "idProduct", "unknown")
        self.check("unavailable", "Invalid USB product")

    def test_preferences_do_not_affect_checks(self):
        for name, value in (("fnmode", "1"), ("idle_timeout", "300"), ("dim_timeout", "30")):
            self.put(self.virtual / name, value)
        self.put(self.usb / "power/wakeup", "enabled")
        self.put(self.usb / "power/control", "auto")
        self.check("checks-passed")

    def test_second_unrelated_usb_is_excluded(self):
        other = self.root / "devices/usb1/1-4"
        self.put(other / "idVendor", "05ac")
        self.put(other / "idProduct", "8302")
        (self.root / "bus/usb/devices/1-4").symlink_to(other)
        self.assertEqual(len(self.check("checks-passed")["usb"]), 1)

    def test_disappearing_target_is_unavailable(self):
        original = preflight.snapshot
        count = 0
        def disappearing(root):
            nonlocal count
            count += 1
            if count == 2:
                (self.usb / "devnum").unlink()
            return original(root)
        with patch.object(preflight, "snapshot", side_effect=disappearing):
            self.check("unavailable", "FileNotFoundError")

    def test_recovery_is_not_healthy_production(self):
        self.put(self.usb / "idProduct", "1281")
        self.check("refused", "recovery candidate")

    def test_multiple_candidates_are_ambiguous(self):
        (self.root / "bus/usb/devices/1-4").symlink_to(self.usb)
        self.check("refused", "ambiguous")

    def test_configuration_zero_two_empty_and_invalid_are_refused(self):
        for value in ("0", "2", "", "other"):
            with self.subTest(value=value):
                self.put(self.usb / "bConfigurationValue", value)
                self.check("refused", "configuration")

    def test_missing_attribute_is_unavailable_not_configuration_zero(self):
        (self.usb / "bConfigurationValue").unlink()
        self.check("unavailable", "FileNotFoundError")

    def test_permission_error_is_unavailable(self):
        original = preflight.read
        def denied(path):
            if path.name == "devnum":
                raise PermissionError("fixture denied devnum")
            return original(path)
        with patch.object(preflight, "read", side_effect=denied):
            self.check("unavailable", "PermissionError")

    def test_unknown_owners_refused_for_both_levels(self):
        for node in (self.physical, self.virtual):
            with self.subTest(node=node.name):
                self.bind(node, "custom-panel")
                self.check("refused", "unexpected owner")
                self.bind(node, "hid-generic")

    def test_unbound_and_expected_owners_are_observed(self):
        (self.physical / "driver").unlink()
        self.bind(self.virtual, "apple-touchbar")
        self.check("checks-passed")

    def test_shared_sensor_interface_is_allowed(self):
        self.bind(self.physical, "apple-ibridge-hid")
        self.bind(self.virtual, "apple-touchbar")
        sensor = self.usb / "1-3:1.3/0003:05AC:8600.0003"
        sensor.mkdir(parents=True)
        (self.root / "bus/hid/devices" / sensor.name).symlink_to(sensor)
        self.bind(sensor, "hid-sensor-hub")
        report = self.check("checks-passed")
        self.assertIn("hid-sensor-hub", [node["owner"] for node in report["hid"]])

    def test_fully_loaded_expected_stack_is_allowed(self):
        self.bind(self.physical, "apple-ibridge-hid")
        self.bind(self.virtual, "apple-touchbar")
        self.put("module/apple_ibridge/parameters/skip_acpi_power", "1")
        (self.root / "module/apple_touchbar").mkdir()
        report = self.check("checks-passed")
        self.assertEqual(report["loaded_modules"], ["apple_ibridge", "apple_touchbar"])

    def test_unrelated_hid_is_not_a_descendant(self):
        unrelated = self.root / "devices/other/0003:1D6B:0301.0009"
        unrelated.mkdir(parents=True)
        self.bind(unrelated, "custom-panel")
        (self.root / "bus/hid/devices" / unrelated.name).symlink_to(unrelated)
        self.assertEqual(len(self.check("checks-passed")["hid"]), 2)

    def test_virtual_must_descend_from_physical_t1_hid(self):
        (self.root / "bus/hid/devices" / self.virtual.name).unlink()
        misplaced = self.usb / "0003:1D6B:0301.0003"
        misplaced.mkdir()
        (self.root / "bus/hid/devices" / misplaced.name).symlink_to(misplaced)
        self.check("refused", "not below a physical")

    def test_missing_physical_hid_refused(self):
        (self.root / "bus/hid/devices" / self.physical.name).unlink()
        self.check("refused", "No physical")

    def test_broken_owner_link_is_unavailable(self):
        (self.physical / "driver").unlink()
        (self.physical / "driver").symlink_to(self.root / "missing")
        self.check("unavailable")

    def test_other_stack_and_unsafe_loaded_bridge_refused(self):
        legacy = self.root / "module/apple_ib_tb"
        legacy.mkdir()
        self.check("refused", "Another T1")
        legacy.rmdir()
        self.put("module/apple_ibridge/parameters/skip_acpi_power", "0")
        self.check("refused", "skip_acpi_power")
        self.put("module/apple_ibridge/parameters/skip_acpi_power", "1")
        self.check("checks-passed")

    def test_missing_loaded_parameter_is_not_disabled(self):
        (self.root / "module/apple_ibridge").mkdir()
        self.check("unavailable")

    def test_reenumeration_and_owner_race_are_unavailable(self):
        original = preflight.snapshot
        for change in (lambda: self.put(self.usb / "devnum", "8"),
                       lambda: self.bind(self.physical, "apple-ibridge-hid")):
            with self.subTest(change=change):
                count = 0
                def racing(root):
                    nonlocal count
                    count += 1
                    if count == 2:
                        change()
                    return original(root)
                with patch.object(preflight, "snapshot", side_effect=racing):
                    self.check("unavailable", "changed during inspection")

    def test_missing_bus_is_not_no_hardware(self):
        (self.root / "bus/hid/devices" / self.physical.name).unlink()
        (self.root / "bus/hid/devices" / self.virtual.name).unlink()
        (self.root / "bus/hid/devices").rmdir()
        self.check("unavailable")

    def test_cli_exit_codes_and_json(self):
        import contextlib
        import json
        for status, expected in preflight.EXIT_STATUS.items():
            with self.subTest(status=status), patch.object(preflight, "inspect", return_value={"status": status}):
                output = io.StringIO()
                with contextlib.redirect_stdout(output):
                    self.assertEqual(preflight.main([]), expected)
                self.assertEqual(json.loads(output.getvalue())["status"], status)

    def test_inspection_never_writes_or_spawns(self):
        # Reject write opens and process execution on success and refusal paths.
        real_open = io.open
        def readonly(file, mode="r", *args, **kwargs):
            self.assertFalse(any(c in mode for c in "wax+"), (file, mode))
            return real_open(file, mode, *args, **kwargs)
        for configuration, expected in (("1", "checks-passed"), ("2", "refused")):
            self.put(self.usb / "bConfigurationValue", configuration)
            with patch("io.open", side_effect=readonly), patch("builtins.open", side_effect=readonly), \
                    patch.object(subprocess, "Popen", side_effect=AssertionError("spawn")), \
                    patch.object(os, "system", side_effect=AssertionError("shell")):
                self.check(expected)


if __name__ == "__main__":
    unittest.main()
