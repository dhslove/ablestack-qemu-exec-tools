#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_log_event() { :; }
ftctl_now_iso8601() { printf '2026-08-30T00:00:00+00:00\n'; }
ftctl_dr_runtime_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
ftctl_dr_runtime_plan_dir() { printf '%s/runtime/%s\n' "${TMP}" "$(ftctl_dr_runtime_key "$1")"; }
ftctl_dr_runtime_profile_value() { jq -r --arg key "$2" 'getpath($key|split(".")) // ""' "$1"; }
ftctl_state_read_kv() {
  awk -F= -v key="$2" '$1==key {sub(/^[^=]+=/, ""); print; found=1; exit} END {if (!found) exit 1}' "$1"
}
ftctl_state_write_kv_all() {
  local path="$1"; shift
  mkdir -p "$(dirname "${path}")"
  printf '%s\n' "$@" > "${path}"
}
ftctl_state_set_path() {
  local path="$1"; shift
  python3 - "${path}" "$@" <<'PY'
import os, sys, tempfile
path, updates = sys.argv[1], dict(item.split("=", 1) for item in sys.argv[2:])
values = {}
if os.path.exists(path):
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            key, sep, value = line.rstrip("\n").partition("=")
            if sep:
                values[key] = value
values.update(updates)
os.makedirs(os.path.dirname(path), exist_ok=True)
fd, temporary = tempfile.mkstemp(dir=os.path.dirname(path))
with os.fdopen(fd, "w", encoding="utf-8") as handle:
    for key, value in values.items():
        handle.write(f"{key}={value}\n")
os.replace(temporary, path)
PY
}
ftctl_dr_runtime_path_set() { ftctl_state_set_path "$@"; }

QMP_STUB_STATE=running
ftctl_cmd_run() {
  local timeout="$1" out_name="$2" err_name="$3" rc_name="$4" payload
  : "${timeout}"
  shift 5
  payload="${*: -1}"
  case "${payload}" in
    *query-status*) printf -v "${out_name}" '{"return":{"status":"%s"}}' "${QMP_STUB_STATE}" ;;
    *'"execute":"stop"'*) QMP_STUB_STATE=paused; printf -v "${out_name}" '%s' '{"return":{}}' ;;
    *'"execute":"cont"'*) QMP_STUB_STATE=running; printf -v "${out_name}" '%s' '{"return":{}}' ;;
    *) printf -v "${out_name}" '%s' '{"return":{}}' ;;
  esac
  printf -v "${err_name}" '%s' ''
  printf -v "${rc_name}" '%s' '0'
}

# shellcheck source=../lib/ftctl/dr_ablestack.sh
source "${ROOT}/lib/ftctl/dr_ablestack.sh"

PLAN=plan-qcow2-cutover
RUN=run-qcow2-cutover
PROFILE="${TMP}/profile.json"
RUN_PATH="${TMP}/run.state"
STATUS_PATH="${TMP}/status.state"
LIVE_PATH=/mnt/glue-gfs/volume-live

cat > "${PROFILE}" <<EOF
{
  "planUuid":"${PLAN}",
  "direction":"KVM_TO_KVM",
  "source":{"provider":"ABLESTACK","driver":"KVM_QMP","instanceName":"i-2-51-VM"},
  "target":{"provider":"ABLESTACK","storagePoolType":"SharedMountPoint"},
  "mapping":{"disks":[{
    "device":"volume-live","sourcePath":"/mnt/glue-gfs/deleted-overlay",
    "sourceType":"file","sourceFormat":"qcow2","targetPath":"/mnt/glue-gfs/target",
    "targetType":"file","targetFormat":"qcow2","sizeBytes":1073741824
  }]},
  "transport":{"mode":"site-agent-nbd","exports":[{
    "device":"volume-live","host":"10.10.31.2","port":12031,"name":"dr-export"
  }]},
  "request":{"sourceRuntimeQuiesceRequired":true,"sourceRuntimeQuiesceMode":"QMP_STOP",
    "cutoverRunUuid":"${RUN}","sourcePowerOffAfterCheckpoint":true}
}
EOF

rebind_count=0
ftctl_dr_ablestack_rebind_live_qcow2_sources() {
  local plan="$1" map="$2" temporary
  : "${plan}"
  rebind_count=$((rebind_count + 1))
  temporary="${map}.rebound"
  jq --arg live "${LIVE_PATH}" '.disks[0].sourcePath=$live | .disks[0].sourceFormat="qcow2"' \
    "${map}" > "${temporary}"
  mv -f "${temporary}" "${map}"
}

ftctl_state_write_kv_all "${RUN_PATH}" "state=RUNNING"
ftctl_dr_ablestack_cutover_quiesce_begin "${PLAN}" "${RUN}" "${PROFILE}" "${RUN_PATH}" "${STATUS_PATH}"
[[ "${QMP_STUB_STATE}" == "paused" ]]
QUIESCE_PATH="$(ftctl_dr_ablestack_cutover_quiesce_path "${PLAN}" "${RUN}")"
FROZEN_MAP="$(ftctl_dr_ablestack_cutover_source_map_path "${PLAN}" "${RUN}")"
[[ "$(ftctl_state_read_kv "${QUIESCE_PATH}" state)" == "PAUSED" ]]
jq -e --arg live "${LIVE_PATH}" '.disks[0].sourcePath == $live' "${FROZEN_MAP}" >/dev/null
[[ "$(ftctl_state_read_kv "${RUN_PATH}" source_runtime_quiesce_state)" == "PAUSED" ]]

# FAILOVER_FINAL must consume the Run-owned frozen map and must not query a
# mutable live source mapping again.
ftctl_dr_ablestack_rebind_live_qcow2_sources() { return 99; }
FINAL_MAP="${TMP}/final-map.json"
ftctl_dr_ablestack_prepare_cycle_disk_map "${PLAN}" "${PROFILE}" "${FINAL_MAP}" FAILOVER_FINAL
jq -e --arg live "${LIVE_PATH}" '.disks[0].sourcePath == $live' "${FINAL_MAP}" >/dev/null

cp -f "${FROZEN_MAP}" "${FROZEN_MAP}.good"
printf 'tampered\n' >> "${FROZEN_MAP}"
if ftctl_dr_ablestack_prepare_cycle_disk_map "${PLAN}" "${PROFILE}" "${FINAL_MAP}" FAILOVER_FINAL; then
  echo "[ERR] tampered frozen cutover map was accepted" >&2
  exit 1
fi
mv -f "${FROZEN_MAP}.good" "${FROZEN_MAP}"

ftctl_dr_ablestack_cutover_quiesce_release "${PLAN}" "${RUN}" "${RUN_PATH}" "${STATUS_PATH}"
[[ "${QMP_STUB_STATE}" == "running" ]]
[[ "$(ftctl_state_read_kv "${QUIESCE_PATH}" state)" == "RELEASED" ]]

# Existing provider contracts do not opt in implicitly.
jq 'del(.request.sourceRuntimeQuiesceRequired,.request.sourceRuntimeQuiesceMode,.request.cutoverRunUuid)' \
  "${PROFILE}" > "${TMP}/ordinary-profile.json"
! ftctl_dr_ablestack_cutover_quiesce_required "${TMP}/ordinary-profile.json"

# A remote-source abort must release QMP first, then wait for Cloud to power
# the source on before the existing RESUME_SYNC command starts the scheduler.
ftctl_state_vm_key() { printf '%s\n' "${1//[^A-Za-z0-9._-]/_}"; }
FTCTL_RUN_DIR="${TMP}/abort-root"
# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"
ftctl_dr_runtime_require_plan() { return 0; }
ftctl_dr_runtime_require_run() { return 0; }
ftctl_dr_runtime_remote_source_transition() { return 0; }
abort_quiesce_release_count=0
abort_scheduler_resume_count=0
ftctl_dr_ablestack_cutover_quiesce_release() {
  abort_quiesce_release_count=$((abort_quiesce_release_count + 1))
}
ftctl_dr_scheduler_resume_after_transition() {
  abort_scheduler_resume_count=$((abort_scheduler_resume_count + 1))
}
ftctl_dr_scheduler_checkpoint_lease_release() { return 0; }
ftctl_dr_runtime_abort_failover_session() { return 0; }
ftctl_dr_scheduler_transition_end() { return 0; }
ftctl_dr_runtime_emit_state_json() { return 0; }

ABORT_PLAN=plan-qcow2-abort
ABORT_RUN=run-qcow2-abort
ABORT_RUN_PATH="$(ftctl_dr_runtime_run_path "${ABORT_PLAN}" "${ABORT_RUN}")"
ABORT_PROFILE_PATH="$(ftctl_dr_runtime_profile_path "${ABORT_PLAN}")"
mkdir -p "$(dirname "${ABORT_RUN_PATH}")"
printf '{}\n' > "${ABORT_PROFILE_PATH}"
ftctl_state_write_kv_all "${ABORT_RUN_PATH}" \
  "state=CUTOVER_READY" "active_side=SOURCE" "target_power_state=POWERED_OFF" \
  "failover_session_id=session-qcow2-abort" "failover_restore_point_sequence=12"
ftctl_dr_runtime_failover_abort "${ABORT_PLAN}" "${ABORT_RUN}" "session-qcow2-abort" 1
[[ "${abort_quiesce_release_count}" == "1" ]]
[[ "${abort_scheduler_resume_count}" == "0" ]]
[[ "$(ftctl_state_read_kv "${ABORT_RUN_PATH}" state)" == "ABORTED" ]]
[[ "$(ftctl_state_read_kv "${ABORT_RUN_PATH}" scheduler_desired_state)" == "PAUSED" ]]
[[ "$(ftctl_state_read_kv "${ABORT_RUN_PATH}" scheduler_recovery_state)" == "SOURCE_POWER_ON_REQUIRED" ]]

echo "[OK] SharedMountPoint planned Failover QMP quiesce contract"
