#!/usr/bin/env python3
import importlib.util
import json
import os
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
MODULE_PATH = os.path.join(ROOT, "lib", "ftctl", "dr_extent_patch.py")
spec = importlib.util.spec_from_file_location("dr_extent_patch", MODULE_PATH)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)

with tempfile.TemporaryDirectory() as directory:
    source = os.path.join(directory, "source.raw")
    target = os.path.join(directory, "target.raw")
    payload = b"x" * (1024 * 1024)
    with open(source, "wb") as handle:
        handle.write(payload)
    with open(target, "wb") as handle:
        handle.truncate(len(payload))
    started = time.monotonic()
    result = module.copy_extents(
        source,
        target,
        [{"offset": 0, "length": len(payload)}],
        64 * 1024,
        bandwidth_limit_mbps=8,
    )
    elapsed = time.monotonic() - started
    assert elapsed >= 0.85, elapsed
    assert result["bandwidthLimitMbps"] == 8, json.dumps(result)
    with open(target, "rb") as handle:
        assert handle.read() == payload

print("[OK] FTCTL DR bandwidth limit smoke")
