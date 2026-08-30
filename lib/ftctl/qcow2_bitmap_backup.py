#!/usr/bin/env python3
"""Run a live qcow2 full or incremental backup through QEMU dirty bitmaps."""

import argparse
import json
import os
import subprocess
import sys
import tempfile
import time
from pathlib import Path


class BackupError(RuntimeError):
    pass


class BaselineUnavailable(BackupError):
    pass


class QmpClient:
    def __init__(self, domain, uri="qemu:///system", virsh="virsh"):
        self.domain = domain
        self.uri = uri
        self.virsh = virsh

    def execute(self, command, arguments=None):
        payload = {"execute": command}
        if arguments:
            payload["arguments"] = arguments
        proc = subprocess.run(
            [self.virsh, "-c", self.uri, "qemu-monitor-command", self.domain,
             "--pretty", json.dumps(payload, separators=(",", ":"))],
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
        if proc.returncode != 0:
            raise BackupError(proc.stderr.strip() or f"virsh failed for {command}")
        try:
            response = json.loads(proc.stdout)
        except json.JSONDecodeError as exc:
            raise BackupError(f"invalid QMP response for {command}: {proc.stdout[:200]}") from exc
        if response.get("error"):
            error = response["error"]
            raise BackupError(f"{command}: {error.get('class', 'QMP_ERROR')}: {error.get('desc', '')}")
        return response.get("return")


def atomic_write_json(path, value):
    if not path:
        return
    target = Path(path)
    target.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=target.name + ".", dir=str(target.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(value, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
        os.replace(tmp, target)
    finally:
        if os.path.exists(tmp):
            os.unlink(tmp)


def resolve_source_node(nodes, source_path):
    matches = []
    for node in nodes or []:
        filename = (node.get("image") or {}).get("filename") or node.get("file")
        if filename == source_path and node.get("drv") == "qcow2":
            matches.append(node)
    active = [node for node in matches if node.get("active") is True]
    selected = active[0] if len(active) == 1 else matches[0] if len(matches) == 1 else None
    if not selected or not selected.get("node-name"):
        raise BackupError(f"active qcow2 source node was not resolved for {source_path}")
    return selected


def bitmap_details(node, bitmap_name):
    for bitmap in node.get("dirty-bitmaps") or []:
        if bitmap.get("name") == bitmap_name:
            return bitmap
    return None


def ensure_bitmap(client, node_name, node, bitmap_name, mode, granularity):
    bitmap = bitmap_details(node, bitmap_name)
    if bitmap and (bitmap.get("busy") or bitmap.get("inconsistent")):
        raise BackupError(f"dirty bitmap {bitmap_name} is busy or inconsistent")
    if not bitmap:
        if mode == "incremental":
            raise BaselineUnavailable(f"dirty bitmap {bitmap_name} is not available")
        client.execute("block-dirty-bitmap-add", {
            "node": node_name,
            "name": bitmap_name,
            "granularity": granularity,
            "persistent": True,
        })
        return 0
    if bitmap.get("recording") is False:
        client.execute("block-dirty-bitmap-enable", {"node": node_name, "name": bitmap_name})
    count = int(bitmap.get("count") or 0)
    if mode == "full":
        client.execute("block-dirty-bitmap-clear", {"node": node_name, "name": bitmap_name})
        return 0
    return count


def write_progress(path, args, state, processed, total, changed, started, sample_sequence):
    now = time.time()
    elapsed = max(now - started, 0.001)
    percent = int(min(100, max(0, processed * 100 / total))) if total else 0
    throughput = int(processed / elapsed)
    remaining = max(total - processed, 0)
    eta = int(remaining / throughput) if throughput > 0 else 0
    atomic_write_json(path, {
        "schemaVersion": 2,
        "planUuid": args.plan_uuid,
        "runUuid": args.run_uuid,
        "cycleSequence": args.cycle_sequence,
        "sampleSequence": sample_sequence,
        "state": state,
        "phase": "full-reseed-transfer" if args.mode == "full" else "incremental-transfer",
        "mode": "FULL_RESEED" if args.mode == "full" else "CBT_INCREMENTAL",
        "bytesTotal": total,
        "bytesProcessed": processed,
        "changedBytes": changed,
        "transferPayloadBytes": processed,
        "sourceReadBytes": processed,
        "targetWrittenBytes": processed,
        "verifiedBytes": processed if state == "COMPLETED" else 0,
        "percent": percent,
        "throughputBps": throughput,
        "etaSeconds": eta,
        "diskIndex": args.disk_index,
        "diskCount": args.disk_count,
        "progressEstimated": False,
        "updatedAtEpochMs": int(now * 1000),
    })


def wait_for_job(client, job_id, args, changed_bytes):
    deadline = time.monotonic() + args.timeout
    started = time.time()
    sample_sequence = 0
    last_total = args.virtual_size
    last_processed = 0
    while time.monotonic() < deadline:
        jobs = client.execute("query-jobs") or []
        job = next((entry for entry in jobs if entry.get("id") == job_id), None)
        if job is None:
            raise BackupError(f"QEMU backup job {job_id} disappeared before terminal state")
        sample_sequence += 1
        last_total = int(job.get("total-progress") or last_total or 0)
        last_processed = int(job.get("current-progress") or 0)
        status = str(job.get("status") or "unknown")
        write_progress(args.progress_path, args, "COPYING", last_processed, last_total,
                       changed_bytes, started, sample_sequence)
        if status == "concluded":
            if job.get("error"):
                raise BackupError(str(job["error"]))
            client.execute("job-dismiss", {"id": job_id})
            write_progress(args.progress_path, args, "COMPLETED", last_total, last_total,
                           changed_bytes, started, sample_sequence + 1)
            return {
                "changedBytes": changed_bytes,
                "bytesProcessed": last_total,
                "sourceReadBytes": last_total,
                "targetWrittenBytes": last_total,
                "durationMs": int((time.time() - started) * 1000),
            }
        time.sleep(args.poll_interval)
    try:
        client.execute("job-cancel", {"id": job_id, "force": True})
    except BackupError:
        pass
    raise BackupError(f"QEMU backup job {job_id} timed out after {args.timeout}s")


def run_backup(args, client=None):
    client = client or QmpClient(args.domain, args.uri, args.virsh)
    nodes = client.execute("query-named-block-nodes") or []
    source = resolve_source_node(nodes, args.source_path)
    source_node = source["node-name"]
    changed_bytes = ensure_bitmap(client, source_node, source, args.bitmap, args.mode, args.granularity)
    target_node = args.target_node
    client.execute("blockdev-add", {
        "driver": "nbd",
        "node-name": target_node,
        "server": {"type": "inet", "host": args.target_host, "port": str(args.target_port)},
        "export": args.target_export,
        "read-only": False,
    })
    try:
        backup_args = {
            "job-id": args.job_id,
            "device": source_node,
            "target": target_node,
            "sync": "full" if args.mode == "full" else "incremental",
            "auto-finalize": True,
            "auto-dismiss": False,
            "on-source-error": "report",
            "on-target-error": "report",
        }
        if args.mode == "incremental":
            backup_args["bitmap"] = args.bitmap
            backup_args["bitmap-mode"] = "on-success"
        if args.bandwidth_limit_mbps > 0:
            backup_args["speed"] = args.bandwidth_limit_mbps * 1024 * 1024
        client.execute("blockdev-backup", backup_args)
        result = wait_for_job(client, args.job_id, args, changed_bytes)
    finally:
        try:
            client.execute("blockdev-del", {"node-name": target_node})
        except BackupError:
            pass
    result.update({
        "result": "ok",
        "mode": "FULL_RESEED" if args.mode == "full" else "CBT_INCREMENTAL",
        "sourceNode": source_node,
        "bitmap": args.bitmap,
    })
    return result


def parse_args(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    parser.add_argument("--source-path", required=True)
    parser.add_argument("--target-host", required=True)
    parser.add_argument("--target-port", required=True, type=int)
    parser.add_argument("--target-export", required=True)
    parser.add_argument("--bitmap", required=True)
    parser.add_argument("--mode", choices=("full", "incremental"), required=True)
    parser.add_argument("--job-id", required=True)
    parser.add_argument("--target-node", required=True)
    parser.add_argument("--virtual-size", type=int, default=0)
    parser.add_argument("--timeout", type=int, default=3600)
    parser.add_argument("--poll-interval", type=float, default=1.0)
    parser.add_argument("--granularity", type=int, default=65536)
    parser.add_argument("--bandwidth-limit-mbps", type=int, default=0)
    parser.add_argument("--progress-path", default="")
    parser.add_argument("--plan-uuid", default="")
    parser.add_argument("--run-uuid", default="")
    parser.add_argument("--cycle-sequence", type=int, default=0)
    parser.add_argument("--disk-index", type=int, default=1)
    parser.add_argument("--disk-count", type=int, default=1)
    parser.add_argument("--uri", default="qemu:///system")
    parser.add_argument("--virsh", default="virsh")
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    try:
        print(json.dumps(run_backup(args), sort_keys=True, separators=(",", ":")))
        return 0
    except BaselineUnavailable as exc:
        print(json.dumps({"result": "error", "error": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 91
    except BackupError as exc:
        print(json.dumps({"result": "error", "error": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 92


if __name__ == "__main__":
    sys.exit(main())
