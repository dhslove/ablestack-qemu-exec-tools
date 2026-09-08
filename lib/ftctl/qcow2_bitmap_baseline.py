#!/usr/bin/env python3
"""Create and validate an offline persistent qcow2 dirty-bitmap baseline."""

import argparse
import json
import os
import subprocess
import sys
from pathlib import Path


class BaselineError(RuntimeError):
    def __init__(self, code, message, exit_code=113):
        super().__init__(message)
        self.code = code
        self.exit_code = exit_code


def canonical_under(path, root):
    root_path = Path(root).resolve(strict=True)
    candidate = Path(path)
    if not candidate.is_absolute():
        candidate = root_path / candidate
    candidate = candidate.resolve(strict=True)
    try:
        candidate.relative_to(root_path)
    except ValueError as exc:
        raise BaselineError(
            "DR_REVERSE_FILE_PATH_INVALID",
            f"qcow2 path escapes SharedMountPoint root: {candidate}",
        ) from exc
    if candidate == root_path or not candidate.is_file():
        raise BaselineError("DR_REVERSE_FILE_PATH_INVALID", f"qcow2 file is invalid: {candidate}")
    return candidate, root_path


def writable_holders(path):
    holders = []
    proc_root = Path("/proc")
    if not proc_root.is_dir():
        return holders
    for process in proc_root.iterdir():
        if not process.name.isdigit():
            continue
        try:
            descriptors = list((process / "fd").iterdir())
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                if descriptor.resolve(strict=True) != path:
                    continue
                flags_text = (process / "fdinfo" / descriptor.name).read_text(encoding="utf-8")
                flags_line = next((line for line in flags_text.splitlines() if line.startswith("flags:")), "")
                flags = int(flags_line.split()[1], 8) if flags_line else 0
                if flags & os.O_ACCMODE not in (os.O_WRONLY, os.O_RDWR):
                    continue
                command = (process / "comm").read_text(encoding="utf-8").strip()
                holders.append(f"pid={process.name} command={command or 'unknown'} fd={descriptor.name}")
            except (OSError, ValueError):
                continue
    return holders


def run_command(command):
    result = subprocess.run(
        command,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "command failed").strip()
        raise BaselineError("DR_REVERSE_FILE_BASELINE_INVALID", detail)
    return result.stdout


def is_shared_write_lock_error(error):
    detail = str(error).lower()
    return "failed to get shared" in detail and "write" in detail and "lock" in detail


def image_info(qemu_img, path):
    try:
        output = run_command([qemu_img, "info", "--output=json", str(path)])
    except BaselineError as exc:
        if not is_shared_write_lock_error(exc):
            raise
        try:
            run_command([qemu_img, "info", "--force-share", "--output=json", str(path)])
        except BaselineError:
            raise exc
        raise BaselineError(
            "DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE",
            "qcow2 source is active on another host; current VM placement must be re-resolved",
            exit_code=110,
        ) from exc
    try:
        return json.loads(output)
    except json.JSONDecodeError as exc:
        raise BaselineError("DR_REVERSE_FILE_BASELINE_INVALID", "qemu-img returned invalid JSON") from exc


def bitmap_record(info, name):
    format_data = (info.get("format-specific") or {}).get("data") or {}
    for bitmap in format_data.get("bitmaps") or []:
        if bitmap.get("name") == name:
            return bitmap
    return None


def validate_bitmap(info, bitmap, granularity):
    if info.get("format") != "qcow2":
        raise BaselineError(
            "DR_REVERSE_FILE_FORMAT_INVALID",
            f"reverse baseline source must be qcow2, got {info.get('format') or 'unknown'}",
        )
    record = bitmap_record(info, bitmap)
    if record is None:
        raise BaselineError(
            "DR_REVERSE_FILE_BASELINE_MISSING",
            f"persistent bitmap is missing: {bitmap}",
            exit_code=116,
        )
    if int(record.get("granularity") or 0) != int(granularity):
        raise BaselineError(
            "DR_REVERSE_FILE_BITMAP_GRANULARITY_MISMATCH",
            f"bitmap {bitmap} granularity is {record.get('granularity')}, expected {granularity}",
        )
    flags = set(record.get("flags") or [])
    if "in-use" in flags or "auto" not in flags:
        raise BaselineError(
            "DR_REVERSE_FILE_BITMAP_INVALID",
            f"bitmap {bitmap} is not an enabled offline persistent bitmap: {sorted(flags)}",
        )
    return record


def fsync_path(path):
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def ensure_baseline(args):
    path, root = canonical_under(args.path, args.storage_root)
    holders = writable_holders(path)
    if holders:
        raise BaselineError(
            "DR_REVERSE_FILE_WRITER_NOT_DRAINED",
            "reverse baseline source has writable holders: " + "; ".join(holders[:4]),
            exit_code=112,
        )

    info = image_info(args.qemu_img, path)
    if info.get("format") != "qcow2":
        raise BaselineError(
            "DR_REVERSE_FILE_FORMAT_INVALID",
            f"reverse baseline source must be qcow2, got {info.get('format') or 'unknown'}",
        )
    if getattr(args, "probe_only", False):
        return {
            "result": "ok",
            "state": "PROBED",
            "path": str(path),
            "storageRoot": str(root),
        }
    record = bitmap_record(info, args.bitmap)
    created = False
    if record is None:
        if args.check_only:
            validate_bitmap(info, args.bitmap, args.granularity)
        run_command([
            args.qemu_img, "bitmap", "--add", "--enable", "-g", str(args.granularity),
            str(path), args.bitmap,
        ])
        created = True
    elif getattr(args, "reset", False):
        run_command([
            args.qemu_img, "bitmap", "--clear", str(path), args.bitmap,
        ])

    info = image_info(args.qemu_img, path)
    record = validate_bitmap(info, args.bitmap, args.granularity)
    fsync_path(path)
    fsync_path(path.parent)
    return {
        "result": "ok",
        "state": "READY",
        "path": str(path),
        "storageRoot": str(root),
        "bitmap": args.bitmap,
        "granularity": int(record["granularity"]),
        "created": created,
    }


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--path", required=True)
    parser.add_argument("--storage-root", required=True)
    parser.add_argument("--bitmap", required=True)
    parser.add_argument("--granularity", type=int, default=65536)
    parser.add_argument("--check-only", action="store_true")
    parser.add_argument("--probe-only", action="store_true")
    parser.add_argument("--reset", action="store_true")
    parser.add_argument("--qemu-img", default="qemu-img")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    if args.check_only and (args.probe_only or args.reset):
        print(json.dumps({"result": "error", "errorCode": "DR_QCOW2_BASELINE_ARGUMENT_INVALID",
                          "error": "--check-only cannot be combined with --probe-only or --reset"},
                         separators=(",", ":")), file=sys.stderr)
        return 113
    try:
        print(json.dumps(ensure_baseline(args), sort_keys=True, separators=(",", ":")))
        return 0
    except BaselineError as exc:
        print(json.dumps({"result": "error", "errorCode": exc.code, "error": str(exc)},
                         separators=(",", ":")), file=sys.stderr)
        return exc.exit_code


if __name__ == "__main__":
    sys.exit(main())
