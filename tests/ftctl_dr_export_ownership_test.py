import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location("ownership", Path(__file__).resolve().parents[1] / "lib/ftctl/dr_export_ownership.py")
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class OwnershipTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.profile = self.root / "profile.json"

    def gate(self, host, generation, operation):
        self.profile.write_text(json.dumps({"request": {} if generation is None else {"exportGeneration": generation}}))
        return module.gate(str(self.root / host), operation, str(self.profile))

    def test_transfer_rejects_late_start_and_stop(self):
        for host in ("old", "new"):
            self.gate(host, 2, "STOP")
        self.gate("old", 3, "START")
        for host in ("old", "new"):
            self.gate(host, 4, "STOP")
        self.gate("new", 5, "START")
        for host, generation, operation in (("old", 3, "START"), ("new", 4, "STOP")):
            with self.assertRaises(ValueError):
                self.gate(host, generation, operation)
        self.assertEqual(5, self.gate("new", 5, "START"))

    def test_reboot_cannot_restore_old_profile(self):
        self.gate("old", 2, "START")
        self.gate("old", 4, "STOP")
        with self.assertRaises(ValueError):
            self.gate("old", 2, "START")
        self.assertEqual(4, self.gate("old", 4, "STOP"))

    def test_legacy_transition_only_before_management(self):
        self.assertEqual(0, self.gate("old", None, "START"))
        self.gate("old", 2, "STOP")
        with self.assertRaises(ValueError):
            self.gate("old", None, "START")
        self.assertEqual(2, self.gate("old", None, "STOP"))
        self.gate("old", 3, "START")
        with self.assertRaises(ValueError):
            self.gate("old", None, "STOP")

    def test_same_generation_conflict_and_invalid_values(self):
        self.gate("old", 2, "STOP")
        for generation in (2, 1, 0, -1, "3", True):
            with self.assertRaises(ValueError):
                self.gate("old", generation, "START")

    def test_corrupt_tombstone_fails_closed(self):
        self.gate("old", 2, "STOP")
        (self.root / "old/ownership.json").write_text("broken")
        with self.assertRaises(ValueError):
            self.gate("old", 3, "START")


if __name__ == "__main__":
    unittest.main()
