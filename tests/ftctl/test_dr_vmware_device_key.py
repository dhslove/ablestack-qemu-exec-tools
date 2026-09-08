import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
MOVER = ROOT / "lib" / "ftctl" / "dr_vmware_mover.sh"
BASH = str(Path(os.environ.get("GIT_BASH", r"C:\Program Files\Git\bin\bash.exe"))) if os.name == "nt" else "bash"


class DrVmwareDeviceKeyTest(unittest.TestCase):
    def test_cbt_query_passes_immutable_device_key(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            temp = Path(temp_dir)
            helper = temp / "helper.sh"
            password = temp / "password"
            output = temp / "output.json"
            arguments = temp / "arguments.txt"
            helper.write_text(
                "#!/usr/bin/env bash\n"
                "printf '%s\\n' \"$@\" > \"$FTCTL_TEST_ARGUMENTS\"\n"
                "printf '%s\\n' '{\"new_change_id\":\"change-2\"}'\n",
                encoding="utf-8",
            )
            password.write_text("secret", encoding="utf-8")
            command = (
                f"source '{MOVER.as_posix()}'; "
                "ftctl_vmware_mover_resolve_cbt_python() { printf bash; }; "
                f"export FTCTL_DR_VMWARE_CBT_QUERY_HELPER='{helper.as_posix()}'; "
                f"export FTCTL_TEST_ARGUMENTS='{arguments.as_posix()}'; "
                "ftctl_vmware_mover_query_cbt '10.10.21.10' 'user' "
                f"'{password.as_posix()}' false /unused vm-1 snapshot-1 2000 change-1 "
                f"'{output.as_posix()}' false 2000"
            )
            result = subprocess.run([BASH, "-c", command], capture_output=True, text=True, check=False)

            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(json.loads(output.read_text(encoding="utf-8"))["new_change_id"], "change-2")
            argv = arguments.read_text(encoding="utf-8").splitlines()
            self.assertIn("--disk-id", argv)
            self.assertEqual(argv[argv.index("--disk-id") + 1], "2000")
            self.assertIn("--device-key", argv)
            self.assertEqual(argv[argv.index("--device-key") + 1], "2000")


if __name__ == "__main__":
    unittest.main()
