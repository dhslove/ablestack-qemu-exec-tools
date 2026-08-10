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

import argparse
import json
import os
import queue
import re
import subprocess
import sys
import tempfile
import threading
import time
from typing import Dict, List


PROGRESS_PATTERN = re.compile(rb"\(\s*([0-9]+(?:\.[0-9]+)?)\s*/\s*100%\s*\)")


def read_previous(path: str) -> Dict[str, object]:
    if not path:
        return {}
    try:
        with open(path, "r", encoding="utf-8") as handle:
            value = json.load(handle)
            return value if isinstance(value, dict) else {}
    except (OSError, ValueError):
        return {}


def write_atomic(path: str, payload: Dict[str, object]) -> None:
    if not path:
        return
    directory = os.path.dirname(path) or "."
    os.makedirs(directory, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{os.path.basename(path)}.", dir=directory)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
            handle.write("\n")
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def payload(args: argparse.Namespace, percent: float, state: str, started: float) -> Dict[str, object]:
    previous = read_previous(args.progress_json)
    disk_processed = int(max(0, args.disk_bytes) * max(0.0, min(100.0, percent)) / 100.0)
    processed = min(max(0, args.total_bytes), max(0, args.base_bytes) + disk_processed)
    elapsed = max(0.001, time.monotonic() - started)
    throughput = max(0, int(max(0, processed - args.base_bytes) / elapsed))
    remaining = max(0, args.total_bytes - processed)
    eta = int(remaining / throughput) if throughput > 0 and remaining > 0 else 0
    aggregate_percent = 100.0 if args.total_bytes <= 0 and state == "COMPLETE" else (
        processed * 100.0 / args.total_bytes if args.total_bytes > 0 else 0.0
    )
    now_ms = int(time.time() * 1000)
    sequence = int(previous.get("sampleSequence") or 0) + 1
    return {
        "schemaVersion": 2,
        "planUuid": args.plan_uuid,
        "runUuid": args.run_uuid,
        "cycleSequence": args.cycle_sequence,
        "sampleSequence": sequence,
        "phase": "TRANSFER",
        "state": state,
        "mode": args.mode,
        "direction": args.direction,
        "diskIndex": args.disk_index,
        "diskCount": args.disk_count,
        "diskLabel": args.disk_label,
        "bytesTotal": max(0, args.total_bytes),
        "bytesProcessed": processed,
        "sourceReadBytes": processed,
        "targetWrittenBytes": processed,
        "transferPayloadBytes": processed,
        "verifiedBytes": int(previous.get("verifiedBytes") or 0),
        "percent": round(max(0.0, min(100.0, aggregate_percent)), 2),
        "throughputBps": throughput,
        "etaSeconds": eta,
        "progressEstimated": True,
        "updatedAtEpochMs": now_ms,
        "heartbeatAtEpochMs": now_ms,
    }


def run(args: argparse.Namespace, command: List[str]) -> int:
    if not command:
        raise ValueError("qemu-img command is empty")
    started = time.monotonic()
    last_publish = 0.0
    last_percent = 0.0
    write_atomic(args.progress_json, payload(args, 0.0, "COPYING", started))
    process = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    buffer = b""
    assert process.stdout is not None
    chunks: "queue.Queue[object]" = queue.Queue()

    def read_child_output() -> None:
        try:
            while True:
                chunk = os.read(process.stdout.fileno(), 4096)
                if not chunk:
                    break
                chunks.put(chunk)
        finally:
            chunks.put(None)

    reader = threading.Thread(target=read_child_output, name="dr-qemu-progress-reader", daemon=True)
    reader.start()

    def publish(percent: float, force: bool = False) -> None:
        nonlocal last_publish, last_percent
        if percent < last_percent:
            return
        last_percent = percent
        now = time.monotonic()
        if force or now - last_publish >= args.publish_interval:
            write_atomic(args.progress_json, payload(args, last_percent, "COPYING", started))
            last_publish = now

    def consume(data: bytes, final: bool = False) -> None:
        nonlocal buffer
        buffer += data
        records = re.split(rb"[\r\n]+", buffer)
        buffer = b"" if final else records.pop()
        for record in records:
            for match in PROGRESS_PATTERN.finditer(record):
                percent = float(match.group(1))
                publish(percent, percent >= 100.0)
        if len(buffer) > 4096:
            buffer = buffer[-4096:]

    while True:
        try:
            chunk = chunks.get(timeout=min(0.5, args.publish_interval))
            if chunk is None:
                break
            if isinstance(chunk, bytes):
                # Keep stdout reserved for machine-readable wrapper results.
                # qemu-img progress and diagnostics are relayed to stderr.
                sys.stderr.buffer.write(chunk)
                sys.stderr.buffer.flush()
                consume(chunk)
        except queue.Empty:
            if process.poll() is None:
                publish(last_percent)
    reader.join(timeout=1.0)
    consume(b"", final=True)
    return_code = process.wait()
    terminal_state = "COMPLETE" if return_code == 0 and args.final_disk else ("COPYING" if return_code == 0 else "FAILED")
    terminal_percent = 100.0 if return_code == 0 else last_percent
    write_atomic(args.progress_json, payload(args, terminal_percent, terminal_state, started))
    return return_code


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--progress-json", required=True)
    parser.add_argument("--plan-uuid", default="")
    parser.add_argument("--run-uuid", default="")
    parser.add_argument("--cycle-sequence", type=int, default=0)
    parser.add_argument("--mode", default="FULL_SEED")
    parser.add_argument("--direction", default="VMWARE_TO_KVM")
    parser.add_argument("--disk-index", type=int, default=0)
    parser.add_argument("--disk-count", type=int, default=1)
    parser.add_argument("--disk-label", default="")
    parser.add_argument("--disk-bytes", type=int, default=0)
    parser.add_argument("--base-bytes", type=int, default=0)
    parser.add_argument("--total-bytes", type=int, default=0)
    parser.add_argument("--publish-interval", type=float, default=2.0)
    parser.add_argument("--final-disk", action="store_true")
    parser.add_argument("command", nargs=argparse.REMAINDER)
    args = parser.parse_args()
    args.publish_interval = max(0.01, args.publish_interval)
    command = args.command[1:] if args.command and args.command[0] == "--" else args.command
    return run(args, command)


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"DR_QEMU_IMG_PROGRESS_FAILED: {error}", file=sys.stderr)
        sys.exit(68)
