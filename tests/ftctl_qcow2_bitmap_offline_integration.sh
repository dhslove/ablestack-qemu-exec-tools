#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d /var/tmp/ftctl-qcow2-offline-test.XXXXXX)"
SOURCE="${TMP}/source.qcow2"
TARGET="${TMP}/target.qcow2"
PID_FILE="${TMP}/target.pid"
BITMAP="ftctl-dr-offline-test"

cleanup() {
  local pid=""
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -z "${pid}" ]] || kill "${pid}" >/dev/null 2>&1 || true
  rm -rf "${TMP}"
}
trap cleanup EXIT

for command in qemu-img qemu-io qemu-nbd qemu-storage-daemon python3; do
  command -v "${command}" >/dev/null
done

free_port() {
  python3 - <<'PY'
import socket
with socket.socket() as sock:
    sock.bind(("127.0.0.1", 0))
    print(sock.getsockname()[1])
PY
}

start_target() {
  local port="$1"
  rm -f "${PID_FILE}"
  qemu-nbd --fork --persistent --shared=4 --bind 127.0.0.1 --port "${port}" \
    --export-name dr-offline-test --format qcow2 --pid-file "${PID_FILE}" "${TARGET}"
}

stop_target() {
  local pid=""
  pid="$(cat "${PID_FILE}" 2>/dev/null || true)"
  [[ -z "${pid}" ]] || kill "${pid}" >/dev/null 2>&1 || true
  rm -f "${PID_FILE}"
  sleep 0.2
}

qemu-img create -q -f qcow2 "${SOURCE}" 64M
qemu-img create -q -f qcow2 "${TARGET}" 64M
qemu-img bitmap --add --enable -g 65536 "${SOURCE}" "${BITMAP}"
qemu-io -f qcow2 -c 'write -P 0x5a 4M 1M' "${SOURCE}" >/dev/null

PORT="$(free_port)"
start_target "${PORT}"
FIRST="$(python3 "${ROOT}/lib/ftctl/qcow2_bitmap_offline_backup.py" \
  --domain offline --source-path "${SOURCE}" --target-host 127.0.0.1 \
  --target-port "${PORT}" --target-export dr-offline-test --bitmap "${BITMAP}" \
  --mode incremental --job-id offline-first --target-node offline-target-first \
  --virtual-size 67108864 --timeout 30 --poll-interval 0.05)"
python3 -c 'import json,sys; assert int(json.loads(sys.argv[1])["changedBytes"]) == 1048576' "${FIRST}"
stop_target
qemu-img compare -q -f qcow2 -F qcow2 "${SOURCE}" "${TARGET}"

qemu-img bitmap --clear "${SOURCE}" "${BITMAP}"
# Make the target intentionally different. An empty source bitmap must not
# rewrite this range; this proves NO_CHANGE does not hide a full data copy.
qemu-io -f qcow2 -c 'write -P 0xa5 8M 1M' "${TARGET}" >/dev/null
PORT="$(free_port)"
start_target "${PORT}"
SECOND="$(python3 "${ROOT}/lib/ftctl/qcow2_bitmap_offline_backup.py" \
  --domain offline --source-path "${SOURCE}" --target-host 127.0.0.1 \
  --target-port "${PORT}" --target-export dr-offline-test --bitmap "${BITMAP}" \
  --mode incremental --job-id offline-second --target-node offline-target-second \
  --virtual-size 67108864 --timeout 30 --poll-interval 0.05)"
python3 -c 'import json,sys; value=json.loads(sys.argv[1]); assert int(value["changedBytes"]) == 0; assert int(value["targetWrittenBytes"]) == 0' "${SECOND}"
stop_target
qemu-io -f qcow2 -c 'read -P 0xa5 8M 1M' "${TARGET}" >/dev/null

printf 'ftctl qcow2 offline bitmap integration: PASS\n'
