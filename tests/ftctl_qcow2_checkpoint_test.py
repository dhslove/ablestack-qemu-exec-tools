#!/usr/bin/env python3

import importlib.util
import json
import os
import tempfile
import unittest
from pathlib import Path
from unittest import mock


MODULE_PATH = Path(__file__).resolve().parents[1] / "lib" / "ftctl" / "qcow2_checkpoint.py"
SPEC = importlib.util.spec_from_file_location("qcow2_checkpoint", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Args:
    plan = "plan-uuid"
    sequence = 17
    checkpoint_ref = "ftctl:plan-uuid:run-uuid:17"
    device = "vda"


class Qcow2CheckpointTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "replica.qcow2"
        self.source.write_bytes(b"source")
        self.output = self.root / "ftctl-dr-test-run-vda.qcow2"
        self.args = Args()
        self.args.source = str(self.source)
        self.args.storage_root = str(self.root)
        self.args.output = str(self.output)

    def tearDown(self):
        self.temp.cleanup()

    def fake_run(self, command, **kwargs):
        executable = Path(command[0]).name
        if executable == "qemu-img" and command[1] == "info":
            return mock.Mock(returncode=0, stdout=json.dumps({"format": "qcow2", "virtual-size": 4096}), stderr="")
        if executable == "cp":
            Path(command[-1]).write_bytes(b"qcow2")
            return mock.Mock(returncode=0, stdout="", stderr="")
        if executable == "qemu-img" and command[1] == "create":
            Path(command[-1]).write_bytes(b"qcow2")
            return mock.Mock(returncode=0, stdout="", stderr="")
        if executable == "qemu-img" and command[1] in ("check", "compare"):
            return mock.Mock(returncode=0, stdout="", stderr="")
        if executable == "virt-inspector":
            return mock.Mock(returncode=0, stdout="<operatingsystems><operatingsystem><name>linux</name></operatingsystem></operatingsystems>", stderr="")
        if executable == "guestfish":
            return mock.Mock(returncode=0, stdout="/dev/sda1: /\n", stderr="")
        if executable == "virt-cat":
            return mock.Mock(returncode=0, stdout="/dev/mapper/rl-root / xfs defaults 0 0\n", stderr="")
        if executable == "virt-ls":
            return mock.Mock(returncode=0, stdout="vmlinuz\n", stderr="")
        raise AssertionError(command)

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_seals_probes_and_creates_overlay(self, run_mock, _which):
        run_mock.side_effect = self.fake_run
        result = MODULE.execute(self.args)

        self.assertEqual("SEALED", result["checkpointSealState"])
        self.assertEqual("PASSED", result["checkpointIntegrityState"])
        self.assertEqual(17, result["checkpointSequence"])
        self.assertTrue(Path(result["checkpointPath"]).is_file())
        self.assertTrue(self.output.is_file())
        self.assertFalse(any(Path(result["checkpointPath"]).parent.glob(".probe-*.qcow2")))

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_reuses_only_matching_immutable_checkpoint(self, run_mock, _which):
        run_mock.side_effect = self.fake_run
        first = MODULE.execute(self.args)
        self.output.unlink()
        second = MODULE.execute(self.args)
        self.assertFalse(first["checkpointReused"])
        self.assertTrue(second["checkpointReused"])

        metadata = Path(second["checkpointMetadataPath"])
        data = json.loads(metadata.read_text(encoding="utf-8"))
        data["checkpointSequence"] = 18
        metadata.write_text(json.dumps(data), encoding="utf-8")
        self.output.unlink()
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", context.exception.code)

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_probe_failure_does_not_publish_test_overlay(self, run_mock, _which):
        def failing_run(command, **kwargs):
            if Path(command[0]).name == "virt-inspector":
                return mock.Mock(returncode=1, stdout="", stderr="filesystem is inconsistent")
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = failing_run
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", context.exception.code)
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_rejects_checkpoint_that_differs_from_drained_target(self, run_mock, _which):
        def mismatched_run(command, **kwargs):
            if Path(command[0]).name == "qemu-img" and command[1] == "compare":
                return mock.Mock(returncode=1, stdout="Content mismatch at offset 69632", stderr="")
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = mismatched_run
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_CONTENT_MISMATCH", context.exception.code)
        checkpoint_dir = self.root / ".ftctl-dr-checkpoints" / self.args.plan / str(self.args.sequence)
        self.assertFalse((checkpoint_dir / "vda.qcow2").exists())
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE.subprocess, "run")
    def test_rejects_separate_boot_filesystem_mount_failure(self, run_mock, _which):
        def failing_run(command, **kwargs):
            if Path(command[0]).name == "virt-cat":
                return mock.Mock(
                    returncode=0,
                    stdout="/dev/mapper/rl-root / xfs defaults 0 0\n",
                    stderr="some filesystems could not be mounted: Structure needs cleaning",
                )
            return self.fake_run(command, **kwargs)

        run_mock.side_effect = failing_run
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", context.exception.code)
        self.assertFalse(self.output.exists())

    @mock.patch.object(MODULE.shutil, "which", side_effect=lambda name: f"/usr/bin/{name}")
    @mock.patch.object(MODULE, "writable_holders", return_value=["pid=4242 command=qemu-kvm fd=17"])
    def test_rejects_checkpoint_while_canonical_target_is_writable(self, _holders, _which):
        with self.assertRaises(MODULE.CheckpointError) as context:
            MODULE.execute(self.args)
        self.assertEqual("DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED", context.exception.code)
        self.assertIn("qemu-kvm", str(context.exception))
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
