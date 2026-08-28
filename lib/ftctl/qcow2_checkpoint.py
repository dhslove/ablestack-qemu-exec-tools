#!/usr/bin/env python3
"""Seal and validate immutable SharedMountPoint qcow2 DR checkpoints."""

import argparse
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


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


def seal(args):
    qemu_img = require_tool("qemu-img")
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

    source_info = image_info(qemu_img, source, force_share=False)
    expected = {
        "version": 1,
        "planUuid": args.plan,
        "checkpointSequence": sequence,
        "checkpointRef": args.checkpoint_ref,
        "device": args.device,
        "sourcePath": str(source),
        "sourceFormat": source_info.get("format"),
        "virtualSize": source_info.get("virtual-size"),
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
        return checkpoint, metadata_path, expected, True

    fd, temp_name = tempfile.mkstemp(prefix=f".{device}.", suffix=".tmp", dir=checkpoint_dir)
    os.close(fd)
    os.unlink(temp_name)
    temp_path = Path(temp_name)
    metadata_temp = metadata_path.with_name(f".{metadata_path.name}.{os.getpid()}.tmp")
    try:
        result = subprocess.run(
            [qemu_img, "convert", "-f", str(source_info.get("format") or "qcow2"),
             "-O", "qcow2", "-S", "4k", str(source), str(temp_path)],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            check=False,
        )
        if result.returncode != 0:
            raise CheckpointError(
                "DR_TEST_CHECKPOINT_SEAL_FAILED",
                (result.stderr or result.stdout or "qemu-img convert failed").strip(),
            )
        check_image(qemu_img, temp_path)
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
    probe = checkpoint_dir / f".probe-{os.getpid()}.qcow2"
    try:
        create_overlay(qemu_img, checkpoint, probe)
        inspection = run([virt_inspector, "-a", str(probe)])
        if "<operatingsystem>" not in inspection:
            raise CheckpointError("DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT", "no bootable operating system was discovered")
        run([guestfish, "--rw", "-a", str(probe), "-i"], input_text="mountpoints\n")
    finally:
        if probe.exists():
            probe.unlink()


def execute(args):
    checkpoint, metadata_path, metadata, reused = seal(args)
    qemu_img = require_tool("qemu-img")
    probe_checkpoint(qemu_img, checkpoint, checkpoint.parent)
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
