#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT
FTCTL_LIB_BASE="${ROOT}/lib"
TRACE="${TMP}/trace.log"

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_log_event() { printf 'event %s\n' "$*" >> "${TRACE}"; }
ftctl_dr_runtime_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_dr_runtime_plan_dir() { printf '%s/runtime/%s\n' "${TMP}" "$(ftctl_dr_runtime_key "$1")"; }
ftctl_now_iso8601() { printf '2026-09-04T00:00:00Z\n'; }
ftctl_iso_to_epoch() { printf '100\n'; }
ftctl_cmd_run() {
  local timeout="$1" out_var="$2" err_var="$3" rc_var="$4"
  shift 5
  : "${timeout}"
  printf 'command %s\n' "$*" >> "${TRACE}"
  printf -v "${out_var}" '%s' ''
  printf -v "${err_var}" '%s' ''
  printf -v "${rc_var}" '%s' '0'
}

# shellcheck source=../lib/ftctl/dr_ablestack.sh
source "${ROOT}/lib/ftctl/dr_ablestack.sh"

map="${TMP}/disk-map.json"
mkdir -p "${TMP}/source"
for index in 0 1 2; do : > "${TMP}/source/disk-${index}.qcow2"; done
python3 - "${map}" "${TMP}" <<'PY'
import json,sys
path,root=sys.argv[1:]
disks=[]
exports=[]
for index in range(3):
    device=f"vd{chr(ord('a') + index)}"
    disks.append({"device":device,"sourcePath":f"{root}/source/disk-{index}.qcow2",
                  "targetPath":f"{root}/target/disk-{index}.qcow2",
                  "sourceFormat":"qcow2","targetFormat":"qcow2",
                  "sourceType":"file","targetType":"file","sizeBytes":"1048576"})
    exports.append({"device":device,"host":"10.10.31.3","port":str(12000 + index),
                    "name":f"dr-{device}","uri":f"nbd://10.10.31.3:{12000 + index}/dr-{device}"})
with open(path,"w",encoding="utf-8") as fh:
    json.dump({"count":3,"sourceProvider":"ABLESTACK",
               "source":{"instanceName":"i-2-100-VM","storagePath":f"{root}/source"},
               "disks":disks,"transport":{"exports":exports}},fh)
PY

# The Cloud profile may omit source.storagePath. The resolver must return the
# single canonical parent through an output variable even when it is named
# "root" by the caller; Bash dynamic scoping must not swallow the assignment.
map_without_root="${TMP}/disk-map-without-root.json"
python3 - "${map}" "${map_without_root}" <<'PY'
import json,sys
source,target=sys.argv[1:]
with open(source,encoding="utf-8") as fh:
    data=json.load(fh)
data["source"]["storagePath"]=""
with open(target,"w",encoding="utf-8") as fh:
    json.dump(data,fh)
PY
root=""
ftctl_dr_ablestack_qcow2_source_root "${map_without_root}" root
[[ "${root}" == "${TMP}/source" ]]

ftctl_dr_ablestack_prepare_targets() { :; }
ftctl_dr_ablestack_site_agent_transport_load() { return 0; }
ftctl_dr_ablestack_remote_transport_load() { return 1; }
ftctl_dr_ablestack_target_export_reachable() { return 0; }
ftctl_dr_ablestack_source_size_bytes() { printf -v "$4" '%s' '1048576'; }
ftctl_dr_ablestack_probe_offline_qcow2_sources() { printf 'offline-probe\n' >> "${TRACE}"; }
ftctl_dr_ablestack_initialize_qcow2_source_baselines() {
  [[ "$4" == "1" ]]
  printf 'offline-baseline-reset\n' >> "${TRACE}"
}
ftctl_dr_ablestack_qcow2_source_baselines_ready() { return 0; }
ftctl_dr_ablestack_write_manifest() { printf 'manifest\n' >> "${TRACE}"; }
ftctl_dr_ablestack_write_checkpoint() { printf 'checkpoint\n' >> "${TRACE}"; }

# Stopped domains select the dedicated offline path for every disk. The
# baseline set is reset before the first transfer and --force-share is absent.
ftctl_dr_ablestack_qcow2_runtime_ready() { return 1; }
ftctl_dr_ablestack_qcow2_push_disk() {
  printf 'unexpected-qmp\n' >> "${TRACE}"
  return 1
}
ftctl_dr_ablestack_full_seed_once plan-offline run-offline unused "${map}" \
  "${TMP}/manifest.json" "${TMP}/checkpoint.json" FULL_SEED FULL_SEED '' 7
[[ "$(grep -c '^command qemu-img convert ' "${TRACE}")" == "3" ]]
! grep -q -- '--force-share' "${TRACE}"
[[ "$(grep -c -- ' -O raw ' "${TRACE}")" == "3" ]]
! grep -q -- ' -O qcow2 ' "${TRACE}"
[[ "$(grep -n -m1 '^offline-baseline-reset$' "${TRACE}" | cut -d: -f1)" -lt \
   "$(grep -n -m1 '^command qemu-img convert ' "${TRACE}" | cut -d: -f1)" ]]
! grep -q '^unexpected-qmp$' "${TRACE}"

# Running domains preserve the existing QMP persistent-bitmap path for every
# disk and never enter the offline baseline branch.
: > "${TRACE}"
ftctl_dr_ablestack_qcow2_runtime_ready() { return 0; }
ftctl_dr_ablestack_qcow2_push_disk() {
  local out_var="${10-}"
  printf 'qmp-backup %s\n' "$(ftctl_dr_ablestack_disk_json_field "$7" device)" >> "${TRACE}"
  printf -v "${out_var}" '%s' '{"changedBytes":1048576}'
}
ftctl_dr_ablestack_full_seed_once plan-online run-online unused "${map}" \
  "${TMP}/manifest-online.json" "${TMP}/checkpoint-online.json" FULL_SEED FULL_SEED '' 8
[[ "$(grep -c '^qmp-backup ' "${TRACE}")" == "3" ]]
! grep -q '^offline-' "${TRACE}"
! grep -q '^command qemu-img convert ' "${TRACE}"

[[ "$(ftctl_dr_ablestack_error_code_for_rc 110)" == "DR_QCOW2_SOURCE_RUNTIME_UNAVAILABLE" ]]
[[ "$(ftctl_dr_ablestack_error_code_for_rc 112)" == "DR_QCOW2_OFFLINE_SOURCE_BUSY" ]]
[[ "$(ftctl_dr_ablestack_error_code_for_rc 115)" == "DR_QCOW2_OFFLINE_TRANSFER_FAILED" ]]
[[ "$(ftctl_dr_ablestack_error_code_for_rc 92)" != "DR_NBD_TEARDOWN_TIMEOUT" ]]

# A stopped source remains protectable after Full Seed. Scheduled incremental
# requests are promoted to the same validated offline Full Seed producer rather
# than failing merely because QMP is unavailable.
: > "${TRACE}"
ftctl_dr_ablestack_qcow2_runtime_ready() { return 1; }
ftctl_dr_ablestack_full_seed_once() {
  [[ "$7" == "CBT_INCREMENTAL" ]]
  [[ "$8" == "FULL_SEED" ]]
  [[ "$9" == "source_runtime_unavailable" ]]
  [[ "${10}" == "9" ]]
  printf 'offline-incremental-fallback\n' >> "${TRACE}"
}
ftctl_dr_ablestack_qcow2_incremental_once plan-offline run-scheduled unused "${map}" \
  "${TMP}/manifest-scheduled.json" "${TMP}/checkpoint-scheduled.json" 9
grep -q '^offline-incremental-fallback$' "${TRACE}"
grep -q 'reason=source_runtime_unavailable mode=offline-full-seed' "${TRACE}"

printf 'ftctl ABLESTACK offline full seed smoke: PASS\n'
