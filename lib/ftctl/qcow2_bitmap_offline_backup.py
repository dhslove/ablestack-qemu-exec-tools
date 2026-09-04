#!/usr/bin/env python3
"""Run a qcow2 bitmap backup through a temporary offline QEMU block graph."""

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import qcow2_bitmap_backup as backup


class UnixQmpClient:
    def __init__(self, socket_path, timeout=30):
        self.socket_path = socket_path
        self.timeout = timeout
        self.sequence = 0
        self.connection = None
        self.reader = None

    def connect(self):
        deadline = time.monotonic() + self.timeout
        last_error = None
        while time.monotonic() < deadline:
            try:
                self.connection = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self.connection.settimeout(self.timeout)
                self.connection.connect(self.socket_path)
                self.reader = self.connection.makefile("rb")
                greeting = self._read_message()
                if "QMP" not in greeting:
                    raise backup.BackupError("storage daemon returned an invalid QMP greeting")
                self.execute("qmp_capabilities")
                return
            except (OSError, backup.BackupError) as exc:
                last_error = exc
                self.close()
                time.sleep(0.1)
        raise backup.BackupError(f"storage daemon QMP did not become ready: {last_error}")

    def close(self):
        if self.reader is not None:
            self.reader.close()
            self.reader = None
        if self.connection is not None:
            self.connection.close()
            self.connection = None

    def _read_message(self):
        line = self.reader.readline()
        if not line:
            raise backup.BackupError("storage daemon QMP connection closed")
        try:
            return json.loads(line.decode("utf-8"))
        except json.JSONDecodeError as exc:
            raise backup.BackupError("storage daemon returned invalid QMP JSON") from exc

    def execute(self, command, arguments=None):
        self.sequence += 1
        request_id = self.sequence
        payload = {"execute": command, "id": request_id}
        if arguments:
            payload["arguments"] = arguments
        encoded = (json.dumps(payload, separators=(",", ":")) + "\n").encode("utf-8")
        self.connection.sendall(encoded)
        while True:
            response = self._read_message()
            if response.get("id") != request_id:
                continue
            if response.get("error"):
                error = response["error"]
                raise backup.BackupError(
                    f"{command}: {error.get('class', 'QMP_ERROR')}: {error.get('desc', '')}"
                )
            return response.get("return")


class OfflineStorageDaemon:
    def __init__(self, source_path, binary="qemu-storage-daemon"):
        self.source_path = str(Path(source_path).resolve(strict=True))
        self.binary = binary
        self.tempdir = None
        self.process = None
        self.client = None

    def __enter__(self):
        self.tempdir = tempfile.TemporaryDirectory(prefix="ftctl-qcow2-offline-")
        socket_path = os.path.join(self.tempdir.name, "qmp.sock")
        self.process = subprocess.Popen(
            [
                self.binary,
                "--chardev", f"socket,id=qmp,path={socket_path},server=on,wait=off",
                "--monitor", "chardev=qmp,mode=control",
            ],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
            text=True,
        )
        self.client = UnixQmpClient(socket_path)
        try:
            self.client.connect()
            self.client.execute("blockdev-add", {
                "driver": "file",
                "node-name": "ftctl-offline-source-file",
                "filename": self.source_path,
                "cache": {"direct": True, "no-flush": False},
            })
            self.client.execute("blockdev-add", {
                "driver": "qcow2",
                "node-name": "ftctl-offline-source",
                "file": "ftctl-offline-source-file",
                "read-only": False,
            })
            return self.client
        except Exception:
            self.__exit__(*sys.exc_info())
            raise

    def __exit__(self, exc_type, exc_value, traceback):
        if self.client is not None:
            try:
                self.client.execute("blockdev-del", {"node-name": "ftctl-offline-source"})
            except Exception:
                pass
            try:
                self.client.execute("blockdev-del", {"node-name": "ftctl-offline-source-file"})
            except Exception:
                pass
            self.client.close()
        if self.process is not None:
            self.process.terminate()
            try:
                self.process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=5)
        if self.tempdir is not None:
            self.tempdir.cleanup()


def main(argv=None):
    args = backup.parse_args(argv)
    if args.mode != "incremental":
        print(json.dumps({"result": "error", "errorCode": "DR_QCOW2_OFFLINE_MODE_INVALID",
                          "error": "offline bitmap backup accepts incremental mode only"},
                         separators=(",", ":")), file=sys.stderr)
        return 115
    args.preserve_bitmap = True
    try:
        with OfflineStorageDaemon(args.source_path) as client:
            print(json.dumps(backup.run_backup(args, client), sort_keys=True, separators=(",", ":")))
        return 0
    except backup.BaselineUnavailable as exc:
        print(json.dumps({"result": "error", "errorCode": "DR_QCOW2_BASELINE_NOT_DURABLE",
                          "error": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 116
    except (backup.BackupError, OSError) as exc:
        print(json.dumps({"result": "error", "errorCode": "DR_QCOW2_OFFLINE_TRANSFER_FAILED",
                          "error": str(exc)}, separators=(",", ":")), file=sys.stderr)
        return 115


if __name__ == "__main__":
    sys.exit(main())
