#!/usr/bin/env python3
"""Build and validate the FTCTL DR real-failover guest preparation manifest."""

import argparse
import hashlib
import json
import os
import sys


SCHEMA_VERSION = "FTCTL_GUESTPREP_MANIFEST_V2"


class ManifestError(Exception):
    def __init__(self, code, message, exit_code):
        super().__init__(message)
        self.code = code
        self.message = message
        self.exit_code = exit_code


def fail(code, message, exit_code):
    raise ManifestError(code, message, exit_code)


def load_json(path, required=True):
    if not path or not os.path.isfile(path):
        if required:
            fail("DR_CUTOVER_MANIFEST_INVALID", f"JSON input is missing: {path}", 60)
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        fail("DR_CUTOVER_MANIFEST_INVALID", f"cannot read JSON {path}: {exc}", 60)
    if not isinstance(value, dict):
        fail("DR_CUTOVER_MANIFEST_INVALID", f"JSON root must be an object: {path}", 60)
    return value


def load_state(path):
    result = {}
    if path and os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as handle:
            for line in handle:
                line = line.rstrip("\n")
                if "=" in line:
                    key, value = line.split("=", 1)
                    result[key] = value
    return result


def obj(value):
    return value if isinstance(value, dict) else {}


def arr(value):
    return value if isinstance(value, list) else []


def text(value):
    if value is None or isinstance(value, (dict, list)):
        return ""
    return str(value).strip()


def first(*values):
    for value in values:
        candidate = text(value)
        if candidate and candidate.lower() != "null":
            return candidate
    return ""


def integer(*values, minimum=0):
    for value in values:
        try:
            candidate = int(value)
        except (TypeError, ValueError):
            continue
        if candidate >= minimum:
            return candidate
    return 0


def boolean(*values):
    for value in values:
        if isinstance(value, bool):
            return value
        candidate = text(value).lower()
        if candidate in {"true", "1", "yes", "on", "secure", "enabled"}:
            return True
        if candidate in {"false", "0", "no", "off", "legacy", "disabled"}:
            return False
    return False


def nested(data, *keys):
    current = data
    for key in keys:
        if not isinstance(current, dict):
            return None
        current = current.get(key)
    return current


def read_restore_points(path):
    records = []
    if not path or not os.path.isfile(path):
        return records
    with open(path, "r", encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except json.JSONDecodeError:
                continue
            if isinstance(value, dict):
                records.append(value)
    return records


def record_ref(plan, run, record):
    explicit = first(
        record.get("checkpointRef"),
        record.get("sourceSnapshotRef"),
        record.get("restorePointRef"),
    )
    if explicit:
        return explicit
    sequence = record.get("checkpointSequence")
    if sequence is not None:
        return f"ftctl:{plan}:{first(record.get('runUuid'), run)}:{sequence}"
    return first(record.get("checkpoint"), f"ftctl:{plan}:latest")


def select_checkpoint(plan, run, restore_points_path, selector, status_path):
    records = read_restore_points(restore_points_path)
    selected = None
    if selector:
        for record in records:
            candidates = {
                record_ref(plan, run, record),
                f"ftctl:{plan}:{record.get('checkpointSequence', '')}",
                text(record.get("checkpointSequence")),
                text(record.get("checkpoint")),
                text(record.get("manifest")),
                text(record.get("sourceSnapshotRef")),
                text(record.get("restorePointRef")),
                text(record.get("checkpointRef")),
            }
            if selector in candidates:
                selected = record
                break
        if selected is None:
            fail("DR_RESTORE_POINT_NOT_FOUND", f"restore point was not found: {selector}", 44)
    elif records:
        selected = records[-1]

    state = load_state(status_path)
    if selected is None:
        checkpoint_path = state.get("checkpoint_path", "")
        if not checkpoint_path:
            fail("DR_TARGET_DISK_NOT_DURABLE", "no durable checkpoint is available", 64)
        selected = {
            "planUuid": plan,
            "runUuid": state.get("run"),
            "checkpointSequence": state.get("checkpoint_sequence"),
            "checkpoint": checkpoint_path,
            "manifest": state.get("manifest_path"),
            "sourceCheckpointAt": state.get("last_source_checkpoint_at"),
            "targetDurableAt": state.get("last_target_durable_at"),
            "targetReadyRpoSeconds": state.get("target_ready_rpo_seconds"),
            "state": state.get("state"),
        }

    checkpoint_path = first(selected.get("checkpoint"), state.get("checkpoint_path"))
    checkpoint = load_json(checkpoint_path)
    checkpoint_state = first(checkpoint.get("state"), selected.get("state"))
    commit_state = first(
        checkpoint.get("commitState"),
        nested(checkpoint, "commit", "state"),
        checkpoint.get("targetCommitState"),
    )
    target_durable_at = first(
        selected.get("targetDurableAt"),
        checkpoint.get("targetDurableAt"),
        state.get("last_target_durable_at"),
    )
    if checkpoint_state != "TARGET_READY":
        fail("DR_TARGET_DISK_NOT_DURABLE", f"checkpoint is not TARGET_READY: {checkpoint_state}", 64)
    if commit_state and commit_state != "LOCAL_DURABLE":
        fail("DR_TARGET_DISK_NOT_DURABLE", f"checkpoint is not locally durable: {commit_state}", 64)
    if not commit_state and not target_durable_at:
        fail("DR_TARGET_DISK_NOT_DURABLE", "checkpoint has no durable commit evidence", 64)

    return {
        "ref": record_ref(plan, run, selected),
        "sequence": integer(selected.get("checkpointSequence"), checkpoint.get("checkpointSequence")),
        "state": checkpoint_state,
        "commitState": commit_state or "LOCAL_DURABLE",
        "path": checkpoint_path,
        "manifest": first(selected.get("manifest"), state.get("manifest_path")),
        "sourceCheckpointAt": first(selected.get("sourceCheckpointAt"), checkpoint.get("sourceCheckpointAt")),
        "targetDurableAt": target_durable_at,
        "targetReadyRpoSeconds": integer(
            selected.get("targetReadyRpoSeconds"), checkpoint.get("targetReadyRpoSeconds")
        ),
    }


def infer_guest_family(guest_id, explicit):
    value = f"{explicit} {guest_id}".lower()
    if "windows" in value or "win" in value:
        return "windows"
    linux_tokens = ("linux", "rhel", "centos", "rocky", "ubuntu", "debian", "sles", "oracle")
    if any(token in value for token in linux_tokens):
        return "linux"
    fail("DR_GUEST_OS_UNRESOLVED", f"guest family cannot be resolved from guestId={guest_id!r}", 61)


def source_vm(profile):
    mapping_source = obj(nested(profile, "mapping", "source"))
    source_vm_data = obj(mapping_source.get("vm"))
    hardware = obj(mapping_source.get("hardware"))
    workload = obj(mapping_source.get("workload"))
    source = obj(profile.get("source"))

    guest_id = first(
        source_vm_data.get("guestId"),
        hardware.get("guestId"),
        workload.get("guestId"),
        mapping_source.get("guestId"),
        source.get("guestId"),
    )
    family = infer_guest_family(
        guest_id,
        first(source_vm_data.get("guestFamily"), hardware.get("guestFamily"), workload.get("guestFamily")),
    )
    firmware_raw = first(
        source_vm_data.get("firmware"),
        hardware.get("firmware"),
        hardware.get("bootType"),
        nested(profile, "mapping", "target", "hardware", "bootType"),
        "bios",
    )
    firmware = "efi" if any(token in firmware_raw.upper() for token in ("EFI", "UEFI")) else "bios"
    secure_boot = boolean(
        source_vm_data.get("secureBoot"),
        hardware.get("secureBoot"),
        nested(profile, "mapping", "target", "hardware", "bootMode") == "SECURE",
    )
    name = first(source_vm_data.get("name"), workload.get("name"), source.get("externalRef"), "ftctl-dr-cutover")
    cpu = integer(
        nested(profile, "mapping", "target", "cpuNumber"),
        source_vm_data.get("cpu"), hardware.get("cpu"), 2, minimum=1,
    )
    memory = integer(
        nested(profile, "mapping", "target", "memory"),
        source_vm_data.get("memoryMb"), hardware.get("memoryMb"), 2048, minimum=1,
    )
    return {
        "name": name,
        "cpu": cpu,
        "memory_mb": memory,
        "firmware": firmware,
        "secure_boot": secure_boot,
        "guestFamily": family,
        "guestId": guest_id,
        "nics": [],
    }


def canonical_locator(disk):
    path = first(
        disk.get("targetProviderLocator"),
        nested(disk, "target", "providerLocator"),
        nested(disk, "target", "path"),
        disk.get("targetPath"),
    )
    disk_type = first(disk.get("targetType"), nested(disk, "target", "type")).lower()
    storage_type = first(disk.get("targetStorageType"), nested(disk, "target", "storageType")).upper()
    target_name = first(disk.get("targetName"), nested(disk, "target", "name"))
    storage_path = first(disk.get("targetStoragePath"), nested(disk, "target", "storagePath"))
    is_rbd = disk_type == "rbd" or "RBD" in storage_type or path.startswith(("rbd:", "rbd/", "/dev/rbd/"))
    if is_rbd:
        if path.startswith("rbd:"):
            spec = path[4:]
        elif path.startswith("rbd/"):
            spec = path[4:]
        elif path.startswith("/dev/rbd/"):
            spec = path[len("/dev/rbd/"):]
        elif storage_path.startswith("rbd:") and target_name:
            spec = f"{storage_path[4:].rstrip('/')}/{target_name}"
        elif storage_path.startswith("rbd/") and target_name:
            spec = f"{storage_path[4:].rstrip('/')}/{target_name}"
        else:
            fail("DR_TARGET_DISK_LOCATOR_INVALID", f"RBD disk has no canonical provider locator: {path}", 63)
        spec = spec.strip("/")
        if "/" not in spec or any(part in {"", ".", ".."} for part in spec.split("/")):
            fail("DR_TARGET_DISK_LOCATOR_INVALID", f"invalid RBD locator: {path}", 63)
        return "rbd", "raw", f"rbd:{spec}"

    if path.startswith("file:"):
        path = path[5:]
    if not os.path.isabs(path):
        fail("DR_TARGET_DISK_LOCATOR_INVALID", f"file disk path is not absolute: {path}", 63)
    disk_format = first(disk.get("targetFormat"), nested(disk, "target", "format"), "qcow2").lower()
    if disk_format not in {"qcow2", "raw"}:
        fail("DR_TARGET_DISK_LOCATOR_INVALID", f"unsupported file format: {disk_format}", 63)
    return "file", disk_format, path


def build_disks(disk_map):
    result = []
    seen = set()
    storage_types = set()
    formats = set()
    for index, disk in enumerate(arr(disk_map.get("disks"))):
        if not isinstance(disk, dict):
            fail("DR_TARGET_DISK_MAP_MISSING", f"disk map entry {index} is invalid", 62)
        source_key = first(
            disk.get("sourceDiskKey"), nested(disk, "source", "diskKey"),
            disk.get("device"), nested(disk, "source", "device"), f"disk{index}",
        )
        device = first(disk.get("device"), nested(disk, "target", "device"), f"sd{chr(ord('a') + index)}")
        if source_key in seen:
            fail("DR_TARGET_DISK_MAP_MISSING", f"duplicate source disk key: {source_key}", 62)
        seen.add(source_key)
        storage_type, disk_format, locator = canonical_locator(disk)
        storage_types.add(storage_type)
        formats.add(disk_format)
        size_bytes = integer(disk.get("sizeBytes"), disk.get("capacityBytes"), minimum=1)
        if size_bytes <= 0:
            fail("DR_TARGET_DISK_MAP_MISSING", f"disk size is unresolved: {source_key}", 62)
        result.append({
            "disk_id": device,
            "source_disk_key": source_key,
            "device": device,
            "boot": boolean(disk.get("boot"), index == 0),
            "size_bytes": size_bytes,
            "controller": {"type": "VirtualSCSIController"},
            "storage": {"type": storage_type, "format": disk_format, "locator": locator},
            "transfer": {"target_path": locator},
        })
    if not result:
        fail("DR_TARGET_DISK_MAP_MISSING", "target disk map contains no disks", 62)
    if len(storage_types) != 1 or len(formats) != 1:
        fail("DR_CUTOVER_MANIFEST_INVALID", "mixed storage type or format is not supported by guest preparation", 60)
    return result, storage_types.pop(), formats.pop()


def write_manifest(manifest, output, checkpoint_sequence=0):
    validate_manifest(manifest)
    os.makedirs(os.path.dirname(os.path.abspath(output)), exist_ok=True)
    encoded = json.dumps(manifest, sort_keys=True, separators=(",", ":")) + "\n"
    temporary = output + ".tmp"
    with open(temporary, "w", encoding="utf-8") as handle:
        handle.write(encoded)
    os.replace(temporary, output)
    digest = hashlib.sha256(encoded.encode("utf-8")).hexdigest()
    print(json.dumps({
        "result": "ok",
        "schemaVersion": SCHEMA_VERSION,
        "manifest": output,
        "sha256": digest,
        "checkpointSequence": checkpoint_sequence,
        "diskCount": len(arr(manifest.get("disks"))),
        "guestFamily": nested(manifest, "source", "vm", "guestFamily"),
        "guestId": nested(manifest, "source", "vm", "guestId"),
    }, sort_keys=True, separators=(",", ":")))


def build_manifest(args):
    profile = load_json(args.profile)
    disk_map = load_json(args.disk_map)
    plan = first(args.plan, profile.get("planUuid"), disk_map.get("planUuid"))
    run = first(args.run, profile.get("runUuid"))
    selector = first(args.selector, nested(profile, "request", "restorePointRef"), nested(profile, "request", "restorePointId"))
    checkpoint = select_checkpoint(plan, run, args.restore_points, selector, args.status)
    disks, storage_type, disk_format = build_disks(disk_map)
    source = source_vm(profile)
    target_mapping = obj(nested(profile, "mapping", "target"))
    target_hw = obj(target_mapping.get("hardware"))
    manifest = {
        "version": 1,
        "schemaVersion": SCHEMA_VERSION,
        "planUuid": plan,
        "runUuid": run,
        "checkpoint": checkpoint,
        "source": {"vm": source},
        "target": {
            "storage": {"type": storage_type},
            "format": disk_format,
            "libvirt": {"name": "ftctl-dr-cutover-prep"},
            "rootDiskController": first(target_hw.get("rootDiskController"), "scsi"),
            "ioPolicy": first(target_hw.get("ioPolicy"), target_mapping.get("ioPolicy"), "io_uring"),
            "ioThreads": boolean(target_hw.get("ioThreads"), target_mapping.get("ioThreads"), True),
        },
        "disks": disks,
    }
    write_manifest(manifest, args.output, checkpoint.get("sequence", 0))


def build_test_disks(session):
    artifacts = obj(session.get("testArtifacts"))
    records = arr(artifacts.get("records"))
    result = []
    storage_types = set()
    formats = set()
    for index, record in enumerate(records):
        if not isinstance(record, dict) or first(record.get("state")) != "CREATED":
            continue
        artifact_type = first(record.get("type")).lower()
        locator = first(record.get("clone"), record.get("path"))
        if artifact_type == "rbd-clone":
            if not locator.startswith("rbd:"):
                fail("DR_TARGET_DISK_LOCATOR_INVALID", f"invalid RBD test artifact: {locator}", 63)
            storage_type, disk_format = "rbd", "raw"
        elif artifact_type in {"qcow2-overlay", "qcow2-copy", "qcow2-checkpoint-overlay"}:
            if not os.path.isabs(locator):
                fail("DR_TARGET_DISK_LOCATOR_INVALID", f"invalid file test artifact: {locator}", 63)
            storage_type, disk_format = "file", "qcow2"
        else:
            fail("DR_TARGET_DISK_LOCATOR_INVALID", f"unsupported test artifact type: {artifact_type}", 63)
        size_bytes = integer(record.get("sizeBytes"), minimum=1)
        if size_bytes <= 0:
            fail("DR_TARGET_DISK_MAP_MISSING", f"test artifact size is unresolved: {locator}", 62)
        device = first(record.get("device"), f"sd{chr(ord('a') + index)}")
        result.append({
            "disk_id": device,
            "source_disk_key": device,
            "device": device,
            "boot": index == 0,
            "size_bytes": size_bytes,
            "controller": {"type": "VirtualSCSIController"},
            "storage": {"type": storage_type, "format": disk_format, "locator": locator},
            "transfer": {"target_path": locator},
        })
        storage_types.add(storage_type)
        formats.add(disk_format)
    if not result:
        fail("DR_TARGET_DISK_MAP_MISSING", "test session contains no created artifacts", 62)
    if len(storage_types) != 1 or len(formats) != 1:
        fail("DR_CUTOVER_MANIFEST_INVALID", "mixed test storage type or format is not supported", 60)
    return result, storage_types.pop(), formats.pop()


def build_test_manifest(args):
    session = load_json(args.session)
    profile = obj(session.get("profile"))
    source = source_vm(profile)
    request = obj(session.get("request"))
    if first(request.get("networkMode"), "ISOLATED").upper() == "ISOLATED":
        source["nics"] = []
    else:
        source["nics"] = arr(nested(profile, "mapping", "source", "workload", "nics"))
    disks, storage_type, disk_format = build_test_disks(session)
    restore = obj(session.get("restorePoint"))
    sequence = integer(restore.get("checkpointSequence"), minimum=0)
    checkpoint = {
        "ref": first(restore.get("ref"), f"ftctl:{first(session.get('planUuid'))}:{sequence}"),
        "sequence": sequence,
        "state": "TARGET_READY",
        "commitState": "LOCAL_DURABLE",
        "path": first(restore.get("checkpoint")),
        "manifest": first(restore.get("manifest")),
        "sourceCheckpointAt": first(restore.get("sourceCheckpointAt")),
        "targetDurableAt": first(restore.get("targetDurableAt")),
        "targetReadyRpoSeconds": integer(restore.get("targetReadyRpoSeconds")),
    }
    target_mapping = obj(nested(profile, "mapping", "target"))
    target_hw = obj(target_mapping.get("hardware"))
    manifest = {
        "version": 1,
        "schemaVersion": SCHEMA_VERSION,
        "planUuid": first(session.get("planUuid"), profile.get("planUuid")),
        "runUuid": first(session.get("runUuid"), profile.get("runUuid")),
        "checkpoint": checkpoint,
        "source": {"vm": source},
        "target": {
            "storage": {"type": storage_type},
            "format": disk_format,
            "libvirt": {"name": args.domain},
            "rootDiskController": first(target_hw.get("rootDiskController"), "scsi"),
            "ioPolicy": first(target_hw.get("ioPolicy"), target_mapping.get("ioPolicy"), "io_uring"),
            "ioThreads": boolean(
                target_hw.get("ioThreads"),
                target_hw.get("ioThreadsEnabled"),
                target_mapping.get("ioThreads"),
                True,
            ),
        },
        "disks": disks,
    }
    write_manifest(manifest, args.output, sequence)


def inspect_command(args):
    profile = load_json(args.profile)
    source = source_vm(profile)
    print(json.dumps({
        "result": "ok",
        "guestFamily": source.get("guestFamily"),
        "guestId": source.get("guestId"),
        "firmware": source.get("firmware"),
        "secureBoot": source.get("secure_boot"),
        "cpu": source.get("cpu"),
        "memoryMb": source.get("memory_mb"),
    }, sort_keys=True, separators=(",", ":")))


def validate_manifest(manifest):
    if manifest.get("schemaVersion") != SCHEMA_VERSION:
        fail("DR_CUTOVER_MANIFEST_INVALID", "unsupported manifest schema", 60)
    source = obj(nested(manifest, "source", "vm"))
    if not first(source.get("guestId"), source.get("guestFamily")):
        fail("DR_GUEST_OS_UNRESOLVED", "guest identity is missing", 61)
    checkpoint = obj(manifest.get("checkpoint"))
    if checkpoint.get("state") != "TARGET_READY" or checkpoint.get("commitState") != "LOCAL_DURABLE":
        fail("DR_TARGET_DISK_NOT_DURABLE", "checkpoint is not target-ready and locally durable", 64)
    disks = arr(manifest.get("disks"))
    if not disks:
        fail("DR_TARGET_DISK_MAP_MISSING", "manifest contains no target disks", 62)
    for disk in disks:
        locator = first(nested(disk, "storage", "locator"), nested(disk, "transfer", "target_path"))
        storage_type = first(nested(disk, "storage", "type"), nested(manifest, "target", "storage", "type"))
        if storage_type == "rbd" and not locator.startswith("rbd:"):
            fail("DR_TARGET_DISK_LOCATOR_INVALID", f"RBD locator is not canonical: {locator}", 63)
        if storage_type == "file" and not os.path.isabs(locator):
            fail("DR_TARGET_DISK_LOCATOR_INVALID", f"file locator is not absolute: {locator}", 63)
        if integer(disk.get("size_bytes"), minimum=1) <= 0:
            fail("DR_TARGET_DISK_MAP_MISSING", "manifest disk size is unresolved", 62)


def validate_command(args):
    manifest = load_json(args.manifest)
    validate_manifest(manifest)
    print(json.dumps({"result": "ok", "schemaVersion": SCHEMA_VERSION}, separators=(",", ":")))


def parser():
    result = argparse.ArgumentParser()
    subparsers = result.add_subparsers(dest="command", required=True)
    build = subparsers.add_parser("build")
    build.add_argument("--profile", required=True)
    build.add_argument("--disk-map", required=True)
    build.add_argument("--restore-points", required=True)
    build.add_argument("--status", required=True)
    build.add_argument("--selector", default="")
    build.add_argument("--plan", default="")
    build.add_argument("--run", default="")
    build.add_argument("--output", required=True)
    build_test = subparsers.add_parser("build-test")
    build_test.add_argument("--session", required=True)
    build_test.add_argument("--domain", required=True)
    build_test.add_argument("--output", required=True)
    inspect = subparsers.add_parser("inspect")
    inspect.add_argument("--profile", required=True)
    validate = subparsers.add_parser("validate")
    validate.add_argument("--manifest", required=True)
    return result


def main():
    args = parser().parse_args()
    try:
        if args.command == "build":
            build_manifest(args)
        elif args.command == "build-test":
            build_test_manifest(args)
        elif args.command == "inspect":
            inspect_command(args)
        else:
            validate_command(args)
    except ManifestError as exc:
        print(json.dumps({
            "result": "error", "errorCode": exc.code, "message": exc.message,
            "exitCode": exc.exit_code,
        }, sort_keys=True, separators=(",", ":")), file=sys.stderr)
        return exc.exit_code
    return 0


if __name__ == "__main__":
    sys.exit(main())
