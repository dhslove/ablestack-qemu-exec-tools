#!/usr/bin/env python3
import importlib.util
import os
import pathlib
import tempfile
import unittest
from unittest import mock


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "qcow2_bitmap_baseline", ROOT / "lib" / "ftctl" / "qcow2_bitmap_baseline.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class Args:
    bitmap = "ftctl-dr-plan-disk0"
    granularity = 65536
    check_only = False
    probe_only = False
    reset = False
    qemu_img = "qemu-img"


class Qcow2BitmapBaselineTest(unittest.TestCase):
    def test_remote_qemu_writer_is_reported_as_runtime_relocation(self):
        locked = MODULE.BaselineError(
            "DR_REVERSE_FILE_BASELINE_INVALID",
            "Failed to get shared \"write\" lock",
        )
        with mock.patch.object(MODULE, "run_command", side_effect=[locked, '{"format":"qcow2"}']) as command:
            with self.assertRaises(MODULE.BaselineError) as context:
                MODULE.image_info("qemu-img", "/mnt/glue-gfs/disk.qcow2")

        self.assertEqual("DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE", context.exception.code)
        self.assertEqual(110, context.exception.exit_code)
        self.assertNotIn("--force-share", command.call_args_list[0].args[0])
        self.assertIn("--force-share", command.call_args_list[1].args[0])

    def test_relative_path_is_bound_to_shared_root(self):
        with tempfile.TemporaryDirectory() as temp:
            root = pathlib.Path(temp)
            image = root / "disk.qcow2"
            image.write_bytes(b"image")
            resolved, resolved_root = MODULE.canonical_under("disk.qcow2", root)
            self.assertTrue(os.path.samefile(image, resolved))
            self.assertTrue(os.path.samefile(root, resolved_root))

    def test_path_escape_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp, tempfile.NamedTemporaryFile() as outside:
            with self.assertRaises(MODULE.BaselineError) as context:
                MODULE.canonical_under(outside.name, temp)
        self.assertEqual("DR_REVERSE_FILE_PATH_INVALID", context.exception.code)

    def test_missing_bitmap_is_created_and_revalidated(self):
        with tempfile.TemporaryDirectory() as temp:
            image = pathlib.Path(temp) / "disk.qcow2"
            image.write_bytes(b"image")
            args = Args()
            args.path = str(image)
            args.storage_root = temp
            missing = {"format": "qcow2", "format-specific": {"data": {"bitmaps": []}}}
            ready = {"format": "qcow2", "format-specific": {"data": {"bitmaps": [{
                "name": args.bitmap, "granularity": args.granularity, "flags": ["auto"]
            }]}}}
            with mock.patch.object(MODULE, "writable_holders", return_value=[]), \
                    mock.patch.object(MODULE, "image_info", side_effect=[missing, ready]), \
                    mock.patch.object(MODULE, "run_command") as command, \
                    mock.patch.object(MODULE, "fsync_path"):
                result = MODULE.ensure_baseline(args)
        self.assertTrue(result["created"])
        self.assertIn("--add", command.call_args.args[0])

    def test_existing_bitmap_is_cleared_for_offline_full_seed(self):
        with tempfile.TemporaryDirectory() as temp:
            image = pathlib.Path(temp) / "disk.qcow2"
            image.write_bytes(b"image")
            args = Args()
            args.path = str(image)
            args.storage_root = temp
            args.reset = True
            ready = {"format": "qcow2", "format-specific": {"data": {"bitmaps": [{
                "name": args.bitmap, "granularity": args.granularity, "flags": ["auto"]
            }]}}}
            with mock.patch.object(MODULE, "writable_holders", return_value=[]), \
                    mock.patch.object(MODULE, "image_info", side_effect=[ready, ready]), \
                    mock.patch.object(MODULE, "run_command") as command, \
                    mock.patch.object(MODULE, "fsync_path"):
                result = MODULE.ensure_baseline(args)
        self.assertFalse(result["created"])
        clear_command = command.call_args.args[0]
        self.assertEqual(["qemu-img", "bitmap", "--clear"], clear_command[:3])
        self.assertEqual(image.name, pathlib.Path(clear_command[3]).name)
        self.assertEqual(args.bitmap, clear_command[4])

    def test_probe_only_checks_offline_ownership_without_requiring_bitmap(self):
        with tempfile.TemporaryDirectory() as temp:
            image = pathlib.Path(temp) / "disk.qcow2"
            image.write_bytes(b"image")
            args = Args()
            args.path = str(image)
            args.storage_root = temp
            args.probe_only = True
            info = {"format": "qcow2", "format-specific": {"data": {"bitmaps": []}}}
            with mock.patch.object(MODULE, "writable_holders", return_value=[]), \
                    mock.patch.object(MODULE, "image_info", return_value=info), \
                    mock.patch.object(MODULE, "run_command") as command:
                result = MODULE.ensure_baseline(args)
        self.assertEqual("PROBED", result["state"])
        command.assert_not_called()

    def test_writable_holder_uses_qcow2_specific_exit_code(self):
        with tempfile.TemporaryDirectory() as temp:
            image = pathlib.Path(temp) / "disk.qcow2"
            image.write_bytes(b"image")
            args = Args()
            args.path = str(image)
            args.storage_root = temp
            with mock.patch.object(MODULE, "writable_holders", return_value=["pid=10 command=qemu"]):
                with self.assertRaises(MODULE.BaselineError) as context:
                    MODULE.ensure_baseline(args)
        self.assertEqual(112, context.exception.exit_code)

    def test_check_only_requires_existing_bitmap(self):
        with tempfile.TemporaryDirectory() as temp:
            image = pathlib.Path(temp) / "disk.qcow2"
            image.write_bytes(b"image")
            args = Args()
            args.path = str(image)
            args.storage_root = temp
            args.check_only = True
            missing = {"format": "qcow2", "format-specific": {"data": {"bitmaps": []}}}
            with mock.patch.object(MODULE, "writable_holders", return_value=[]), \
                    mock.patch.object(MODULE, "image_info", return_value=missing):
                with self.assertRaises(MODULE.BaselineError) as context:
                    MODULE.ensure_baseline(args)
        self.assertEqual("DR_REVERSE_FILE_BASELINE_MISSING", context.exception.code)

    def test_in_use_bitmap_is_rejected(self):
        info = {"format": "qcow2", "format-specific": {"data": {"bitmaps": [{
            "name": Args.bitmap, "granularity": Args.granularity, "flags": ["auto", "in-use"]
        }]}}}
        with self.assertRaises(MODULE.BaselineError) as context:
            MODULE.validate_bitmap(info, Args.bitmap, Args.granularity)
        self.assertEqual("DR_REVERSE_FILE_BITMAP_INVALID", context.exception.code)


if __name__ == "__main__":
    unittest.main()
