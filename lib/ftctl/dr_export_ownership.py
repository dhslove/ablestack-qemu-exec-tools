#!/usr/bin/env python3
"""Durable, host-local export fencing. Caller holds the plan transition flock."""
import json
import os
import sys
from pathlib import Path


def gate(root, operation, profile):
    path = Path(root) / "ownership.json"
    current = json.loads(path.read_text()) if path.exists() else {}
    request = json.loads(Path(profile).read_text()).get("request", {}) if profile and Path(profile).is_file() else {}
    generation = request.get("exportGeneration")
    previous = int(current.get("generation", 0))
    if generation is None:
        if previous and not (operation == "STOP" and current.get("operation") == "STOP"):
            raise ValueError("DR_EXPORT_STALE_GENERATION: legacy command cannot override managed ownership")
        return previous
    if isinstance(generation, bool) or not isinstance(generation, int) or generation <= 0:
        raise ValueError("DR_EXPORT_INVALID_GENERATION")
    if generation < previous or (generation == previous and current.get("operation") != operation):
        raise ValueError("DR_EXPORT_STALE_GENERATION")
    root = Path(root)
    root.mkdir(parents=True, exist_ok=True)
    temp = path.with_suffix(".tmp")
    with temp.open("w") as out:
        json.dump({"generation": generation, "operation": operation}, out)
        out.flush()
        os.fsync(out.fileno())
    os.replace(temp, path)
    fd = os.open(str(root), os.O_DIRECTORY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)
    return generation


if __name__ == "__main__":
    try:
        print(gate(*sys.argv[1:4]))
    except (ValueError, OSError, TypeError) as exc:
        print(str(exc), file=sys.stderr)
        sys.exit(93)
