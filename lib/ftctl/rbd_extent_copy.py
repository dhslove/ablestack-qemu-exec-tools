#!/usr/bin/env python3
"""Apply Ceph RBD changed extents between two already attached block devices."""

import argparse
import json
import os


DEFAULT_CHUNK = 4 * 1024 * 1024


def copy_extent(source_fd, target_fd, offset, length, exists, chunk_size):
    remaining = length
    position = offset
    zero_chunk = bytes(min(chunk_size, max(1, length)))
    while remaining:
        size = min(chunk_size, remaining)
        if exists:
            payload = os.pread(source_fd, size, position)
            if len(payload) != size:
                raise OSError(f"short source read at {position}: {len(payload)} != {size}")
        else:
            payload = zero_chunk[:size]
        written = 0
        while written < size:
            count = os.pwrite(target_fd, payload[written:], position + written)
            if count <= 0:
                raise OSError(f"short target write at {position + written}")
            written += count
        position += size
        remaining -= size


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--source", required=True)
    parser.add_argument("--target", required=True)
    parser.add_argument("--diff-json", required=True)
    parser.add_argument("--chunk-size", type=int, default=DEFAULT_CHUNK)
    args = parser.parse_args()

    with open(args.diff_json, "r", encoding="utf-8") as handle:
        extents = json.load(handle)
    if not isinstance(extents, list):
        raise ValueError("RBD diff JSON must be an array")

    source_fd = os.open(args.source, os.O_RDONLY)
    target_fd = os.open(args.target, os.O_RDWR | getattr(os, "O_DSYNC", 0))
    changed = 0
    try:
        for extent in extents:
            if not isinstance(extent, dict):
                raise ValueError("RBD diff extent must be an object")
            offset = int(extent.get("offset", 0))
            length = int(extent.get("length", 0))
            exists = bool(extent.get("exists", True))
            if offset < 0 or length < 0:
                raise ValueError("RBD diff offset and length must be non-negative")
            if length:
                copy_extent(source_fd, target_fd, offset, length, exists, args.chunk_size)
                changed += length
        os.fsync(target_fd)
    finally:
        os.close(target_fd)
        os.close(source_fd)
    print(json.dumps({"result": "ok", "changedBytes": changed}, separators=(",", ":")))


if __name__ == "__main__":
    main()
