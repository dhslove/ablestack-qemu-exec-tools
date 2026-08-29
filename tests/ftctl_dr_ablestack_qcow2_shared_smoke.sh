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
ftctl_cmd_run() {
  local _timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
  shift 5
  printf '%s\n' "$*" >> "${TMP}/cmd-run.log"
  printf -v "${out_var}" '%s' '{"format":"qcow2","virtual-size":1073741824}'
  printf -v "${err_var}" '%s' ''
  printf -v "${rc_var}" '%s' '0'
}

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

relative_target_profile="${TMP}/profile-relative-target.json"
relative_target_canonical="${TMP}/canonical-relative-target.json"
jq '.mapping.disks[0] |= (.targetPath="target-volume" | .targetStoragePath="/mnt/glue-gfs" | .targetStorageType="SharedMountPoint")' \
  "${profile}" > "${relative_target_profile}"
ftctl_dr_ablestack_canonicalize_profile "${relative_target_profile}" "${relative_target_canonical}"
jq -e '.disks[0].targetPath == "/mnt/glue-gfs/target-volume"' "${relative_target_canonical}" >/dev/null

traversal_target_profile="${TMP}/profile-traversal-target.json"
traversal_target_canonical="${TMP}/canonical-traversal-target.json"
jq '.mapping.disks[0] |= (.targetPath="../outside" | .targetStoragePath="/mnt/glue-gfs" | .targetStorageType="SharedMountPoint")' \
  "${profile}" > "${traversal_target_profile}"
if ftctl_dr_ablestack_canonicalize_profile "${traversal_target_profile}" "${traversal_target_canonical}" 2>/dev/null; then
  echo "[ERR] SharedMountPoint traversal target was accepted" >&2
  exit 1
fi

missing_format_profile="${TMP}/profile-missing-format.json"
missing_format_canonical="${TMP}/canonical-missing-format.json"
touch "${TMP}/source-volume"
jq --arg path "${TMP}/source-volume" '.mapping.disks[0].sourcePath=$path | del(.mapping.disks[0].sourceFormat)' \
  "${profile}" > "${missing_format_profile}"
ftctl_dr_ablestack_canonicalize_profile "${missing_format_profile}" "${missing_format_canonical}"
ftctl_dr_ablestack_qcow2_push_provider "${missing_format_canonical}"
jq -e '.disks[0].sourceFormat == "qcow2"' "${missing_format_canonical}" >/dev/null

remote_source_profile="${TMP}/profile-remote-source.json"
remote_source_canonical="${TMP}/canonical-remote-source.json"
jq '.mapping.disks[0] |= (.sourcePath="/mnt/glue-gfs/not-mounted-on-target" | del(.sourceFormat))' \
  "${profile}" > "${remote_source_profile}"
ftctl_dr_ablestack_canonicalize_profile "${remote_source_profile}" "${remote_source_canonical}"
jq -e '.disks[0].sourceFormat == "" and .disks[0].sourceType == "file"' "${remote_source_canonical}" >/dev/null

reverse_relative_profile="${TMP}/profile-reverse-relative.json"
reverse_relative_canonical="${TMP}/canonical-reverse-relative.json"
jq '.source.storagePath="/mnt/glue-gfs"
  | .source.storagePoolType="SharedMountPoint"
  | .mapping.disks[0].sourcePath="rocky9-vm-dr-disk-0"' \
  "${profile}" > "${reverse_relative_profile}"
ftctl_dr_ablestack_canonicalize_profile "${reverse_relative_profile}" "${reverse_relative_canonical}"
jq -e '.source.storagePath == "/mnt/glue-gfs"
  and .source.storagePoolType == "SharedMountPoint"
  and .disks[0].sourcePath == "/mnt/glue-gfs/rocky9-vm-dr-disk-0"' \
  "${reverse_relative_canonical}" >/dev/null
ftctl_dr_ablestack_qcow2_push_provider "${reverse_relative_canonical}"

# A promoted SharedMountPoint qcow2 remains locked by the running VM. Reverse
# preflight must use the shared-safe metadata probe instead of reporting the
# existing source file as missing.
reverse_live_profile="${TMP}/profile-reverse-live.json"
reverse_live_source="${TMP}/live-source-volume"
touch "${reverse_live_source}"
jq --arg root "${TMP}" --arg path "${reverse_live_source}" \
  '.source.storagePath=$root
  | .source.storagePoolType="SharedMountPoint"
  | .mapping.disks[0] |= (.sourcePath=$path | .sourceFormat="qcow2")' \
  "${profile}" > "${reverse_live_profile}"
: > "${TMP}/cmd-run.log"
reverse_live_preflight="$(ftctl_dr_ablestack_reverse_preflight plan-reverse-live "${reverse_live_profile}" FAILBACK_FINAL AUTO 1)"
jq -e '.ready == true
  and .source_disk_probe_state == "READY"
  and .effective_mode == "FULL_RESEED"' <<< "${reverse_live_preflight}" >/dev/null
grep -q 'qemu-img info --force-share --output=json' "${TMP}/cmd-run.log"

rbd_profile="${TMP}/profile-rbd.json"
rbd_canonical="${TMP}/canonical-rbd.json"
jq '.mapping.disks[0] |= (.sourcePath="rbd:rbd/source" | .sourceType="rbd" | .sourceFormat="raw" | .targetPath="rbd:rbd/target" | .targetType="rbd" | .targetFormat="raw")' "${profile}" > "${rbd_profile}"
ftctl_dr_ablestack_canonicalize_profile "${rbd_profile}" "${rbd_canonical}"
jq -e '.disks[0].sourceFormat == "raw" and .disks[0].sourceType == "rbd"' "${rbd_canonical}" >/dev/null
! ftctl_dr_ablestack_qcow2_push_provider "${rbd_canonical}"

[[ "$(ftctl_dr_ablestack_full_seed_transferred_bytes '{"changedBytes":4096}' 8192)" == "4096" ]]
[[ "$(ftctl_dr_ablestack_full_seed_transferred_bytes '{"mode":"FULL_RESEED","changedBytes":0,"bytesProcessed":16384,"sourceReadBytes":16384,"targetWrittenBytes":16384}' 8192)" == "16384" ]]
[[ "$(ftctl_dr_ablestack_full_seed_transferred_bytes '{"mode":"FULL_RESEED","changedBytes":0,"bytesProcessed":0,"targetWrittenBytes":0}' 8192)" == "0" ]]
[[ "$(ftctl_dr_ablestack_full_seed_transferred_bytes '{}' 8192)" == "8192" ]]
[[ "$(ftctl_dr_ablestack_full_seed_transferred_bytes 'invalid-json' 8192)" == "8192" ]]
[[ "$(ftctl_dr_ablestack_incremental_effective_mode 0)" == "NO_CHANGE" ]]
[[ "$(ftctl_dr_ablestack_incremental_effective_mode 4096)" == "CBT_INCREMENTAL" ]]
[[ "$(ftctl_dr_ablestack_incremental_effective_mode invalid)" == "NO_CHANGE" ]]

checkpoint_manifest="${TMP}/full-seed-manifest.json"
checkpoint_path="${TMP}/full-seed-checkpoint.json"
jq '{planUuid,runUuid:"run-full-seed",disks}' "${canonical}" > "${checkpoint_manifest}"
ftctl_dr_ablestack_write_checkpoint "${canonical}" "${checkpoint_manifest}" "${checkpoint_path}" \
  TARGET_READY 2026-08-28T00:00:00Z 2026-08-28T00:00:10Z 10 \
  FULL_SEED FULL_SEED false 1073741824 '' 1 0 0
jq -e '.changedBytes == 1073741824
  and .sourceReadBytes == 1073741824
  and .targetWrittenBytes == 1073741824
  and .transferPayloadBytes == 1073741824
  and .cycleToken == "plan-qcow2:1"
  and .cycleCommitState == "LOCAL_DURABLE"' "${checkpoint_path}" >/dev/null

grep -q 'total_transferred_bytes' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q '"${total_transferred_bytes}" "${reseed_reason}"' "${ROOT}/lib/ftctl/dr_ablestack.sh"

grep -q 'file:qcow2)' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'qcow2_bitmap_backup.py' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'ftctl_dr_ablestack_qcow2_incremental_once' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'effective_mode="$(ftctl_dr_ablestack_incremental_effective_mode "${total_changed_bytes}")"' "${ROOT}/lib/ftctl/dr_ablestack.sh"
grep -q 'rbd export-diff --from-snap' "${ROOT}/lib/ftctl/dr_ablestack.sh"

python3 "${ROOT}/tests/ftctl_qcow2_bitmap_backup_test.py"
printf 'ftctl SharedMountPoint qcow2 smoke: PASS\n'
