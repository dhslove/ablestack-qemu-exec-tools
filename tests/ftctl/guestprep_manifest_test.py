#!/usr/bin/env python3

import json
import pathlib
import subprocess
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[2]
TOOL = ROOT / "lib" / "ftctl" / "guestprep_manifest.py"


class GuestprepManifestTest(unittest.TestCase):
    def run_tool(self, *args, expected=0):
        result = subprocess.run(
            ["python3", str(TOOL), *args],
            check=False,
            capture_output=True,
            text=True,
        )
        self.assertEqual(expected, result.returncode, result.stderr)
        output = result.stdout if result.returncode == 0 else result.stderr
        return json.loads(output)

    def test_inspect_uses_canonical_vm_guest_id(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = pathlib.Path(directory) / "profile.json"
            profile.write_text(json.dumps({
                "mapping": {
                    "source": {
                        "vm": {
                            "guestId": "windows2019srvNext_64Guest",
                            "firmware": "efi",
                            "secureBoot": True,
                        },
                        "hardware": {"guestId": "otherGuest"},
                    }
                }
            }), encoding="utf-8")
            result = self.run_tool("inspect", "--profile", str(profile))
            self.assertEqual("windows", result["guestFamily"])
            self.assertEqual("windows2019srvNext_64Guest", result["guestId"])
            self.assertEqual("efi", result["firmware"])
            self.assertTrue(result["secureBoot"])

    def test_build_test_preserves_guest_and_target_io_contract(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            session = root / "session.json"
            manifest = root / "manifest.json"
            session.write_text(json.dumps({
                "planUuid": "plan-1",
                "runUuid": "run-1",
                "restorePoint": {
                    "ref": "ftctl:plan-1:run-0:9",
                    "checkpointSequence": 9,
                    "targetDurableAt": "2026-07-28T00:00:00Z",
                },
                "profile": {
                    "mapping": {
                        "source": {
                            "vm": {
                                "guestId": "windows2019srvNext_64Guest",
                                "firmware": "efi",
                                "secureBoot": True,
                            }
                        },
                        "target": {
                            "hardware": {
                                "ioPolicy": "io_uring",
                                "ioThreadsEnabled": True,
                            }
                        },
                    }
                },
                "request": {"networkMode": "ISOLATED"},
                "testArtifacts": {
                    "state": "CREATED",
                    "records": [{
                        "state": "CREATED",
                        "type": "rbd-clone",
                        "device": "sda",
                        "clone": "rbd:rbd/test-volume",
                        "sizeBytes": 1073741824,
                    }],
                },
            }), encoding="utf-8")
            result = self.run_tool(
                "build-test",
                "--session", str(session),
                "--domain", "ftctl-test-domain",
                "--output", str(manifest),
            )
            data = json.loads(manifest.read_text(encoding="utf-8"))
            self.assertEqual("windows", result["guestFamily"])
            self.assertEqual("windows2019srvNext_64Guest", data["source"]["vm"]["guestId"])
            self.assertEqual("efi", data["source"]["vm"]["firmware"])
            self.assertTrue(data["source"]["vm"]["secure_boot"])
            self.assertEqual("io_uring", data["target"]["ioPolicy"])
            self.assertTrue(data["target"]["ioThreads"])
            self.assertEqual("rbd:rbd/test-volume", data["disks"][0]["storage"]["locator"])

    def test_inspect_rejects_unresolved_guest_identity(self):
        with tempfile.TemporaryDirectory() as directory:
            profile = pathlib.Path(directory) / "profile.json"
            profile.write_text('{"mapping":{"source":{"vm":{}}}}', encoding="utf-8")
            result = self.run_tool("inspect", "--profile", str(profile), expected=61)
            self.assertEqual("DR_GUEST_OS_UNRESOLVED", result["errorCode"])


if __name__ == "__main__":
    unittest.main()
