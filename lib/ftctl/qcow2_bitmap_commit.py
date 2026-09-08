#!/usr/bin/env python3
"""Atomically clear a complete live qcow2 dirty-bitmap set after transfer."""

import argparse
import json
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from qcow2_bitmap_backup import BackupError, QmpClient, resolve_source_node


def commit_set(domain, entries, uri="qemu:///system", virsh="virsh"):
    client = QmpClient(domain, uri, virsh)
    nodes = client.execute("query-named-block-nodes") or []
    actions = []
    for entry in entries:
        node = resolve_source_node(nodes, str(entry.get("sourcePath") or ""))
        bitmap = str(entry.get("bitmap") or "")
        if not bitmap:
            raise BackupError("bitmap name is missing from commit set")
        actions.append({
            "type": "block-dirty-bitmap-clear",
            "data": {"node": node["node-name"], "name": bitmap},
        })
    if not actions:
        raise BackupError("bitmap commit set is empty")
    client.execute("transaction", {"actions": actions})


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--domain", required=True)
    parser.add_argument("--entries-json", required=True)
    parser.add_argument("--uri", default="qemu:///system")
    parser.add_argument("--virsh", default="virsh")
    args = parser.parse_args(argv)
    try:
        with open(args.entries_json, encoding="utf-8") as handle:
            entries = json.load(handle)
        commit_set(args.domain, entries, args.uri, args.virsh)
        print(json.dumps({"result": "ok", "committed": len(entries)}, separators=(",", ":")))
        return 0
    except (OSError, ValueError, BackupError) as exc:
        print(json.dumps({"result": "error", "errorCode": "DR_QCOW2_BITMAP_COMMIT_FAILED",
                          "error": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 116


if __name__ == "__main__":
    sys.exit(main())
