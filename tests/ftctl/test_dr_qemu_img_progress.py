#!/usr/bin/env python3
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest


ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
HELPER = os.path.join(ROOT, "lib", "ftctl", "dr_qemu_img_progress.py")


class DrQemuImgProgressTest(unittest.TestCase):
    def run_helper(self, child_source, expected_exit=0):
        with tempfile.TemporaryDirectory() as directory:
            progress_path = os.path.join(directory, "progress.json")
            command = [
                sys.executable, HELPER,
                "--progress-json", progress_path,
                "--plan-uuid", "plan-1",
                "--run-uuid", "run-1",
                "--cycle-sequence", "7",
                "--disk-bytes", "1048576",
                "--total-bytes", "1048576",
                "--publish-interval", "0.02",
                "--final-disk",
                "--", sys.executable, "-c", child_source,
            ]
            process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            samples = []
            last_sequence = -1
            while process.poll() is None:
                try:
                    with open(progress_path, "r", encoding="utf-8") as handle:
                        sample = json.load(handle)
                    sequence = int(sample.get("sampleSequence") or 0)
                    if sequence > last_sequence:
                        samples.append(sample)
                        last_sequence = sequence
                except (OSError, ValueError):
                    pass
                time.sleep(0.005)
            stdout, stderr = process.communicate()
            with open(progress_path, "r", encoding="utf-8") as handle:
                terminal = json.load(handle)
            self.assertEqual(expected_exit, process.returncode)
            self.assertEqual(b"", stdout)
            return samples, terminal, stderr

    def test_collects_stdout_progress_without_polluting_stdout(self):
        source = (
            "import sys,time; "
            "[(sys.stdout.write(f'({value:.2f}/100%)\\r'),sys.stdout.flush(),time.sleep(.04)) "
            "for value in (0,25,50,75,100)]"
        )
        samples, terminal, stderr = self.run_helper(source)
        percents = [float(sample.get("percent") or 0) for sample in samples]
        self.assertGreaterEqual(len(set(percents)), 3)
        self.assertEqual(sorted(percents), percents)
        self.assertEqual(1048576, terminal["bytesTotal"])
        self.assertEqual(1048576, terminal["bytesProcessed"])
        self.assertEqual("COMPLETE", terminal["state"])
        self.assertIn(b"100.00/100%", stderr)

    def test_collects_stderr_progress_and_preserves_child_exit(self):
        source = "import sys; sys.stderr.write('(12.50/100%)\\rfailed\\n'); sys.stderr.flush(); sys.exit(17)"
        _, terminal, stderr = self.run_helper(source, expected_exit=17)
        self.assertEqual("FAILED", terminal["state"])
        self.assertEqual(131072, terminal["bytesProcessed"])
        self.assertIn(b"failed", stderr)


if __name__ == "__main__":
    unittest.main()
