#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_log_event() { :; }
ftctl__json_escape() { printf '%s' "${1-}"; }
ftctl_dr_runtime_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_dr_runtime_plan_dir() { printf '%s/runtime/%s\n' "${TMP}" "$(ftctl_dr_runtime_key "$1")"; }
ftctl_state_write_json_file() { printf '%s\n' "$2" > "$1"; }
ftctl_state_write_kv_all() { :; }
ftctl_state_read_kv() { :; }

# shellcheck source=../lib/ftctl/dr_ablestack.sh
source "${ROOT}/lib/ftctl/dr_ablestack.sh"

profile="${TMP}/profile.json"
canonical="${TMP}/canonical.json"
cat > "${profile}" <<'EOF'
{
  "planUuid": "plan-qcow2",
  "source": {"provider":"ABLESTACK","instanceName":"i-2-13-VM"},
  "target": {"provider":"ABLESTACK"},
  "mapping": {"disks":[{
    "device":"sda",
    "sourcePath":"/mnt/glue-gfs/source-volume",
    "targetPath":"/mnt/glue-gfs/target-volume",
    "sourceFormat":"qcow2",
    "targetFormat":"qcow2",
    "sizeBytes":1073741824,
    "sourceType":"file",
    "targetType":"file"
  }]},
  "transport": {
    "mode":"site-agent-nbd",
    "controlMode":"site-agent",
    "targetHostAddress":"10.10.31.2",
    "exports":[{"device":"sda","host":"10.10.31.2","port":12031,"name":"dr-plan-qcow2-sda"}]
  }
}
EOF

ftctl_dr_ablestack_canonicalize_profile "${profile}" "${canonical}"
ftctl_dr_ablestack_qcow2_push_provider "${canonical}"
[[ "$(ftctl_dr_ablestack_qcow2_bitmap_name plan-qcow2 sda)" == ftctl-dr-*-sda ]]
python3 - "${canonical}" <<'PY'
import json,sys
with open(sys.argv[1], encoding="utf-8") as fh:
    disk=json.load(fh)["disks"][0]
assert disk["sourceType"] == "file"
assert disk["targetFormat"] == "qcow2"
PY

grep -q 'file:qcow2)' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'qcow2_bitmap_backup.py' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'ftctl_dr_ablestack_qcow2_incremental_once' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'rbd export-diff --from-snap' "${ROOT}/lib/ftctl/dr_ablestack.sh"

python3 "${ROOT}/tests/ftctl_qcow2_bitmap_backup_test.py"
printf 'ftctl SharedMountPoint qcow2 smoke: PASS\n'
