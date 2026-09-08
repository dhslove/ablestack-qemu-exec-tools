#!/usr/bin/env python3

import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
COPY_TOOL = ROOT / "lib" / "ftctl" / "rbd_extent_copy.py"


def main():
    with tempfile.TemporaryDirectory() as tmpdir:
        tmp = pathlib.Path(tmpdir)
        source = tmp / "source.raw"
        target = tmp / "target.raw"
        diff = tmp / "diff.json"
        source.write_bytes(b"A" * 4096 + b"B" * 4096 + b"C" * 4096)
        target.write_bytes(b"x" * 4096 + b"y" * 4096 + b"z" * 4096)
        diff.write_text(json.dumps([
            {"offset": 4096, "length": 4096, "exists": True},
            {"offset": 8192, "length": 4096, "exists": False},
        ]), encoding="utf-8")

        result = subprocess.run([
            sys.executable, str(COPY_TOOL),
            "--source", str(source),
            "--target", str(target),
            "--diff-json", str(diff),
            "--chunk-size", "1024",
        ], check=True, capture_output=True, text=True)
        payload = json.loads(result.stdout)
        assert payload == {"result": "ok", "changedBytes": 8192}
        assert target.read_bytes() == b"x" * 4096 + b"B" * 4096 + bytes(4096)

    print("ftctl DR RBD extent copy smoke: PASS")


if __name__ == "__main__":
    main()
