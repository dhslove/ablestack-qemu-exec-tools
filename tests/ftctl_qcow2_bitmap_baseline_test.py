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
    qemu_img = "qemu-img"


class Qcow2BitmapBaselineTest(unittest.TestCase):
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
