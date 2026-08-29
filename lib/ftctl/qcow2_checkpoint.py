#!/usr/bin/env python3
"""Seal and validate immutable SharedMountPoint qcow2 DR checkpoints."""

import argparse
import hashlib
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.etree import ElementTree


class CheckpointError(RuntimeError):
    def __init__(self, code, message):
        super().__init__(message)
        self.code = code


def safe_component(value):
    text = re.sub(r"[^A-Za-z0-9_.-]+", "-", str(value or "")).strip("-.")
    if not text:
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "empty checkpoint path component")
    return text[:96]


def require_tool(name):
    path = shutil.which(name)
    if not path:
        raise CheckpointError("DR_TEST_CHECKPOINT_INSPECTOR_UNAVAILABLE", f"required tool is unavailable: {name}")
    return path


def run(command, *, input_text=None):
    result = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "command failed").strip()
        raise CheckpointError("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", detail)
    return result.stdout


def fsync_path(path):
    try:
        fd = os.open(path, os.O_RDONLY | getattr(os, "O_BINARY", 0))
    except OSError:
        if os.name == "nt" and Path(path).is_dir():
            return
        raise
    try:
        try:
            os.fsync(fd)
        except OSError:
            if os.name != "nt":
                raise
    finally:
        os.close(fd)


def canonical_under(path, root, *, must_exist=False):
    root_path = Path(root).resolve(strict=True)
    path_obj = Path(path).resolve(strict=must_exist)
    try:
        path_obj.relative_to(root_path)
    except ValueError as exc:
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_CONTRACT_INVALID",
            f"path escapes SharedMountPoint root: {path_obj}",
        ) from exc
    return path_obj, root_path


def contract_digest(metadata):
    canonical = json.dumps(metadata, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(canonical).hexdigest()


def image_info(qemu_img, path, *, force_share=False):
    command = [qemu_img, "info", "--output=json"]
    if force_share:
        command.append("--force-share")
    command.append(str(path))
    try:
        return json.loads(run(command))
    except (ValueError, CheckpointError) as exc:
        if isinstance(exc, CheckpointError):
            raise
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", f"invalid qemu-img info for {path}") from exc


def check_image(qemu_img, path):
    result = subprocess.run(
        [qemu_img, "check", "-q", str(path)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "qemu-img check failed").strip()
        raise CheckpointError("DR_TEST_CHECKPOINT_QCOW2_INVALID", detail)


def compare_images(qemu_img, source, source_format, checkpoint):
    result = subprocess.run(
        [qemu_img, "compare", "-f", str(source_format or "qcow2"), "-F", "qcow2",
         str(source), str(checkpoint)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        detail = (result.stderr or result.stdout or "checkpoint differs from drained target").strip()
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTENT_MISMATCH", detail)


def writable_holders(path):
    expected = path.resolve(strict=True)
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
                if descriptor.resolve(strict=True) != expected:
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


def ensure_source_quiescent(source):
    holders = writable_holders(source)
    if holders:
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_WRITER_NOT_DRAINED",
            "drained target still has writable holders: " + "; ".join(holders[:4]),
        )


def strict_guest_command(command, *, input_text=None):
    result = subprocess.run(
        command,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    detail = "\n".join(part for part in (result.stderr.strip(), result.stdout.strip()) if part)
    lowered = detail.lower()
    unavailable_markers = (
        "unsupported filesystem type",
        "unknown filesystem type",
        "ntfs-3g: not found",
        "mount.ntfs: not found",
    )
    unsafe_markers = (
        "some filesystems could not be mounted",
        "structure needs cleaning",
        "mount exited with status",
        "input/output error",
        "filesystem is inconsistent",
    )
    if any(marker in lowered for marker in unavailable_markers):
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_GUEST_FS_DRIVER_UNAVAILABLE",
            detail or "guest filesystem driver is unavailable",
        )
    if result.returncode != 0 or any(marker in lowered for marker in unsafe_markers):
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT",
            detail or "guest filesystem inspection failed",
        )
    return result.stdout


def windows_root_device(inspection_root):
    device = str(inspection_root.findtext(".//root") or "").strip()
    if not re.fullmatch(r"/dev/[A-Za-z0-9._/+:-]+", device):
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT",
            "Windows root filesystem device could not be determined",
        )
    return device


def probe_windows_root(guestfish, probe, inspection_root):
    device = windows_root_device(inspection_root)
    mountpoint = "/tmp/ftctl-windows-root"
    shell = (
        "set -eu; "
        f"rm -rf {shlex.quote(mountpoint)}; mkdir -p {shlex.quote(mountpoint)}; "
        f"/usr/bin/ntfs-3g -o ro {shlex.quote(device)} {shlex.quote(mountpoint)}; "
        f"test -f {shlex.quote(mountpoint + '/Windows/System32/config/SYSTEM')}; "
        f"umount {shlex.quote(mountpoint)}; rmdir {shlex.quote(mountpoint)}"
    )
    script = "run\ndebug sh " + json.dumps(shell) + "\n"
    strict_guest_command([guestfish, "--ro", "-a", str(probe)], input_text=script)


def seal(args):
    qemu_img = require_tool("qemu-img")
    copy_tool = require_tool("cp")
    source, root = canonical_under(args.source, args.storage_root, must_exist=True)
    if not source.is_file():
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", f"target file does not exist: {source}")

    plan = safe_component(args.plan)
    sequence = int(args.sequence)
    if sequence <= 0:
        raise CheckpointError("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", "checkpoint sequence must be positive")
    device = safe_component(args.device)
    checkpoint_dir = root / ".ftctl-dr-checkpoints" / plan / str(sequence)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)
    checkpoint = checkpoint_dir / f"{device}.qcow2"
    metadata_path = checkpoint.with_suffix(".json")

    ensure_source_quiescent(source)
    fsync_path(source)
    fsync_path(source.parent)
    source_info = image_info(qemu_img, source, force_share=False)
    if source_info.get("format") != "qcow2":
        raise CheckpointError(
            "DR_TEST_CHECKPOINT_CONTRACT_INVALID",
            f"SharedMountPoint checkpoint source must be qcow2, got {source_info.get('format') or 'unknown'}",
        )
    source_stat = source.stat()
    expected = {
        "version": 2,
        "planUuid": args.plan,
        "checkpointSequence": sequence,
        "checkpointRef": args.checkpoint_ref,
        "device": args.device,
        "sourcePath": str(source),
        "sourceFormat": source_info.get("format"),
        "virtualSize": source_info.get("virtual-size"),
        "sourceFileSize": source_stat.st_size,
        "sourceMtimeNs": source_stat.st_mtime_ns,
    }
    expected["contractSha256"] = contract_digest(expected)

    if checkpoint.exists() or metadata_path.exists():
        if not checkpoint.is_file() or not metadata_path.is_file():
            raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", "partial immutable checkpoint exists")
        with metadata_path.open("r", encoding="utf-8") as handle:
            actual = json.load(handle)
        if actual != expected:
            raise CheckpointError("DR_TEST_CHECKPOINT_SEQUENCE_MISMATCH", "immutable checkpoint metadata does not match request")
        check_image(qemu_img, checkpoint)
        compare_images(qemu_img, source, source_info.get("format"), checkpoint)
        probe_checkpoint(qemu_img, checkpoint, checkpoint_dir)
        return checkpoint, metadata_path, expected, True

    fd, temp_name = tempfile.mkstemp(prefix=f".{device}.", suffix=".tmp", dir=checkpoint_dir)
    os.close(fd)
    os.unlink(temp_name)
    temp_path = Path(temp_name)
    metadata_temp = metadata_path.with_name(f".{metadata_path.name}.{os.getpid()}.tmp")
    try:
        result = subprocess.run(
            [copy_tool, "--reflink=auto", "--sparse=always", "--", str(source), str(temp_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise CheckpointError(
                "DR_TEST_CHECKPOINT_SEAL_FAILED",
                (result.stderr or result.stdout or "qcow2 container copy failed").strip(),
            )
        check_image(qemu_img, temp_path)
        compare_images(qemu_img, source, source_info.get("format"), temp_path)
        probe_checkpoint(qemu_img, temp_path, checkpoint_dir)
        fsync_path(temp_path)
        os.replace(temp_path, checkpoint)
        with metadata_temp.open("w", encoding="utf-8") as handle:
            json.dump(expected, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(metadata_temp, metadata_path)
        fsync_path(checkpoint_dir)
    finally:
        if temp_path.exists():
            temp_path.unlink()
        if metadata_temp.exists():
            metadata_temp.unlink()
    return checkpoint, metadata_path, expected, False


def create_overlay(qemu_img, backing, output):
    if output.exists():
        raise CheckpointError("DR_TEST_CHECKPOINT_CONTRACT_INVALID", f"test artifact already exists: {output}")
    result = subprocess.run(
        [qemu_img, "create", "-f", "qcow2", "-F", "qcow2", "-b", str(backing), str(output)],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        check=False,
    )
    if result.returncode != 0:
        raise CheckpointError("DR_TEST_MATERIALIZATION_FAILED", (result.stderr or result.stdout).strip())
    check_image(qemu_img, output)


def probe_checkpoint(qemu_img, checkpoint, checkpoint_dir):
    virt_inspector = require_tool("virt-inspector")
    guestfish = require_tool("guestfish")
    virt_cat = require_tool("virt-cat")
    virt_ls = require_tool("virt-ls")
    probe = checkpoint_dir / f".probe-{os.getpid()}.qcow2"
    try:
        create_overlay(qemu_img, checkpoint, probe)
        inspection = strict_guest_command([virt_inspector, "-a", str(probe)])
        if "<operatingsystem>" not in inspection:
            raise CheckpointError("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", "no bootable operating system was discovered")
        try:
            root = ElementTree.fromstring(inspection)
            guest_name = str(root.findtext(".//name") or "").lower()
        except ElementTree.ParseError as exc:
            raise CheckpointError("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", "invalid virt-inspector output") from exc
        if guest_name == "windows":
            probe_windows_root(guestfish, probe, root)
        else:
            strict_guest_command([guestfish, "--ro", "-a", str(probe), "-i", "mountpoints"])
        if guest_name == "linux":
            strict_guest_command([virt_cat, "-a", str(probe), "/etc/fstab"])
            strict_guest_command([virt_ls, "-a", str(probe), "-l", "/boot"])
    finally:
        if probe.exists():
            probe.unlink()


def execute(args):
    checkpoint, metadata_path, metadata, reused = seal(args)
    qemu_img = require_tool("qemu-img")
    output, root = canonical_under(args.output, args.storage_root, must_exist=False)
    output.parent.mkdir(parents=True, exist_ok=True)
    create_overlay(qemu_img, checkpoint, output)
    return {
        "state": "CREATED",
        "type": "qcow2-checkpoint-overlay",
        "path": str(output),
        "storageRoot": str(root),
        "ownedByFtctl": True,
        "checkpointPath": str(checkpoint),
        "checkpointMetadataPath": str(metadata_path),
        "checkpointSequence": metadata["checkpointSequence"],
        "checkpointRef": metadata["checkpointRef"],
        "checkpointContractSha256": metadata["contractSha256"],
        "checkpointSealState": "SEALED",
        "checkpointIntegrityState": "PASSED",
        "checkpointReused": reused,
    }


def parse_args():
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", required=True)
    parser.add_argument("--sequence", required=True, type=int)
    parser.add_argument("--checkpoint-ref", required=True)
    parser.add_argument("--device", required=True)
    parser.add_argument("--source", required=True)
    parser.add_argument("--storage-root", required=True)
    parser.add_argument("--output", required=True)
    return parser.parse_args()


def main():
    try:
        print(json.dumps(execute(parse_args()), sort_keys=True, separators=(",", ":")))
        return 0
    except CheckpointError as exc:
        print(json.dumps({"state": "FAILED", "errorCode": exc.code, "errorMessage": str(exc)}, sort_keys=True), file=sys.stderr)
        return 46
    except Exception as exc:  # keep an actionable structured failure at the Agent boundary
        print(json.dumps({"state": "FAILED", "errorCode": "DR_TEST_CHECKPOINT_SEAL_FAILED", "errorMessage": str(exc)}, sort_keys=True), file=sys.stderr)
        return 46


if __name__ == "__main__":
    sys.exit(main())
