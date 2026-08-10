import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MOVER = ROOT / "lib" / "ftctl" / "dr_vmware_mover.sh"
BASH = str(Path(os.environ.get("GIT_BASH", r"C:\Program Files\Git\bin\bash.exe"))) if os.name == "nt" else "bash"


class DrVmwareSnapshotRefTest(unittest.TestCase):
    def run_resolver(self, payload: str, snapshot_name: str = "ftctl-cycle") -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temp_dir:
            tree = Path(temp_dir) / "tree.json"
            tree.write_text(payload, encoding="utf-8")
            command = (
                f"source '{MOVER.as_posix()}'; "
                f"ftctl_vmware_mover_snapshot_ref_from_tree '{tree.as_posix()}' '{snapshot_name}'"
            )
            return subprocess.run(
                [BASH, "-c", command],
                capture_output=True,
                text=True,
                check=False,
            )

    def test_empty_or_invalid_tree_fails_without_traceback(self) -> None:
        for payload in ("", "not-json"):
            with self.subTest(payload=payload):
                result = self.run_resolver(payload)
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(result.stdout, "")
                self.assertEqual(result.stderr, "")

    def test_valid_tree_returns_matching_snapshot_ref(self) -> None:
        payload = json.dumps(
            {
                "Snapshot": {
                    "Name": "ftctl-cycle",
                    "Snapshot": {"Value": "snapshot-141"},
                }
            }
        )
        result = self.run_resolver(payload)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.strip(), "snapshot-141")
        self.assertEqual(result.stderr, "")
