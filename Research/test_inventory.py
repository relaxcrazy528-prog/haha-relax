"""Privacy and failure-path checks; never invokes a power-policy writer."""

import contextlib
import importlib.util
import io
import json
from pathlib import Path
import plistlib
import subprocess
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("inventory", Path(__file__).with_name("inventory.py"))
inventory = importlib.util.module_from_spec(spec)
spec.loader.exec_module(inventory)


class InventoryPrivacyTests(unittest.TestCase):
    def test_ioreg_omits_identifiers_children_and_non_boolean_values(self):
        payload = [{
            "AppleClamshellState": False,
            "AppleClamshellCausesSleep": "private-user-value",
            "SleepDisabled": True,
            "IOPlatformSerialNumber": "private-serial-value",
            "IOMACAddress": b"abcdef",
            "IORegistryEntryChildren": [{"AppleClamshellState": True}],
        }]
        errors = []
        value = inventory.select_ioreg_properties(plistlib.dumps(payload), errors)
        self.assertEqual(value["properties"], {"AppleClamshellState": False, "SleepDisabled": True})
        encoded = json.dumps(value)
        self.assertNotIn("private", encoded)
        self.assertNotIn("Serial", encoded)
        self.assertNotIn("MAC", encoded)
        self.assertEqual(errors, [])

    def test_command_error_does_not_relay_stderr_or_exception(self):
        errors = []
        with patch.object(inventory.subprocess, "run", return_value=subprocess.CompletedProcess([], 1, b"private-output", b"private-user")):
            self.assertIsNone(inventory.run_readonly(["/usr/bin/sw_vers"], "sw_vers.build", errors))
        self.assertNotIn("private", json.dumps(errors))
        self.assertEqual(errors[0]["reason"], "command_failed")

    def test_unrecognized_text_is_not_printed(self):
        errors = []
        with patch.object(inventory, "run_readonly", return_value=b"private-serial-value"):
            value = inventory.validated_text([], "sysctl.hw.model", r"Mac[0-9]+,[0-9]+", errors)
        self.assertIsNone(value)
        self.assertNotIn("private", json.dumps(errors))

    def test_invalid_plist_is_recorded_without_raw_data(self):
        errors = []
        value = inventory.select_ioreg_properties(b"private-invalid-plist", errors)
        self.assertEqual(value["properties"], {})
        self.assertEqual(errors, [{"source": "ioreg.root_domain", "reason": "invalid_plist"}])

    def test_unknown_platform_returns_json_with_no_hostname(self):
        with patch.object(inventory.sys, "platform", "unsupported"):
            result = inventory.collect_inventory()
        self.assertEqual(result["lid_capability_verdict"], "not_validated")
        self.assertEqual(result["errors"], [{"source": "platform", "reason": "requires_macos"}])
        self.assertNotIn("hostname", result)


if __name__ == "__main__":
    unittest.main()
