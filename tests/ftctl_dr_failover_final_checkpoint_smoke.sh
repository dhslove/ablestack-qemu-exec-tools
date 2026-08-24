#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"

PLAN="final-checkpoint-plan"
RUN="final-checkpoint-run"
OLD_REF="ftctl:${PLAN}:previous-run:4"
FINAL_REF="ftctl:${PLAN}:${RUN}:5"
PROFILE="${TMP}/profile.json"
RUN_PATH="${TMP}/run.state"
STATUS_PATH="${TMP}/status.state"
CAPTURE="${TMP}/capture.state"

printf '%s\n' '{"direction":"VMWARE_TO_KVM","request":{"finalSync":true}}' > "${PROFILE}"
: > "${RUN_PATH}"
: > "${STATUS_PATH}"

ftctl_now_iso8601() { printf '2026-08-25T00:00:00Z\n'; }
jq() {
  case "${2-}" in
    '.direction // ""') printf 'VMWARE_TO_KVM\n' ;;
    '.request.sourceIsolationAcknowledged // false') printf 'false\n' ;;
    '.request.sourceIsolationReason // empty') printf '\n' ;;
    *) return 1 ;;
  esac
}
ftctl_dr_runtime_profile_bool_default() { return 0; }
ftctl_dr_scheduler_control_set() { :; }
ftctl_dr_runtime_path_set() { :; }
ftctl_dr_runtime_state_get_from_path() {
  local path="${1-}" key="${2-}"
  awk -F= -v key="${key}" '$1 == key { sub(/^[^=]*=/, ""); print; exit }' "${path}" 2>/dev/null || true
}
ftctl_dr_runtime_failover_final_checkpoint() {
  printf 'checkpoint_sequence=5\nfailover_final_checkpoint_sequence=5\nfailover_final_restore_point_ref=%s\n' \
    "${FINAL_REF}" > "$4"
}
ftctl_dr_kvm_vmware_seed_cutover_baseline() { :; }
ftctl_dr_runtime_failover_dir() { printf '%s/failover\n' "${TMP}"; }
ftctl_dr_runtime_key() { printf '%s\n' "$1"; }
ftctl_guestprep_prepare_cutover_target() {
  printf 'guestprep_restore_point=%s\n' "$5" >> "${CAPTURE}"
}
ftctl_dr_runtime_finalize_failover() {
  printf 'finalize_restore_point=%s\n' "$4" >> "${CAPTURE}"
}
ftctl_log_event() { :; }

ftctl_dr_runtime_failover_worker "${PLAN}" "${RUN}" "${PROFILE}" "${OLD_REF}" planned \
  "${RUN_PATH}" "${STATUS_PATH}"

grep -Fxq "guestprep_restore_point=${FINAL_REF}" "${CAPTURE}"
grep -Fxq "finalize_restore_point=${FINAL_REF}" "${CAPTURE}"
if grep -Fq "${OLD_REF}" "${CAPTURE}"; then
  echo 'pre-Failover restore point leaked past the final checkpoint barrier' >&2
  exit 1
fi

echo 'ftctl DR Failover final checkpoint smoke: PASS'

REPAIR_DIR="${TMP}/repair"
REPAIR_RUN_PATH="${REPAIR_DIR}/run.state"
REPAIR_STATUS_PATH="${REPAIR_DIR}/status.state"
REPAIR_POINTS="${REPAIR_DIR}/restore-points.jsonl"
REPAIR_MANIFEST="${REPAIR_DIR}/manifest.json"
REPAIR_CHECKPOINT="${REPAIR_DIR}/checkpoint.json"
REPAIR_SESSION="${REPAIR_DIR}/session.json"
REPAIR_ACTIVE="${REPAIR_DIR}/active.json"
mkdir -p "${REPAIR_DIR}"
ftctl_dr_runtime_plan_dir() { printf '%s\n' "${REPAIR_DIR}"; }
printf '{}\n' > "${REPAIR_MANIFEST}"
cat > "${REPAIR_CHECKPOINT}" <<EOF
{"planUuid":"${PLAN}","runUuid":"${RUN}","sequence":5,"state":"TARGET_READY","cycleCommitState":"LOCAL_DURABLE","targetWritten":true,"writeVerified":true,"nbdTeardownState":"DRAINED","sourceCheckpointAt":"2026-08-25T00:00:01Z","targetDurableAt":"2026-08-25T00:00:02Z","targetReadyRpoSeconds":1}
EOF
cat > "${REPAIR_POINTS}" <<EOF
{"planUuid":"${PLAN}","runUuid":"${RUN}","checkpointSequence":5,"checkpointRef":"${FINAL_REF}","cycleType":"failover-final","state":"TARGET_READY","manifest":"${REPAIR_MANIFEST}","checkpoint":"${REPAIR_CHECKPOINT}"}
EOF
printf '{"planUuid":"%s","runUuid":"%s","restorePoint":{"ref":"%s","checkpointSequence":4}}\n' \
  "${PLAN}" "${RUN}" "${OLD_REF}" > "${REPAIR_SESSION}"
cp "${REPAIR_SESSION}" "${REPAIR_ACTIVE}"
printf 'failover_restore_point_sequence=4\n' > "${REPAIR_RUN_PATH}"
cp "${REPAIR_RUN_PATH}" "${REPAIR_STATUS_PATH}"

ftctl_dr_runtime_path_set() {
  local path="${1-}" item key tmp
  shift
  for item in "$@"; do
    key="${item%%=*}"
    tmp="${path}.tmp"
    awk -F= -v key="${key}" '$1 != key' "${path}" > "${tmp}" 2>/dev/null || true
    printf '%s\n' "${item}" >> "${tmp}"
    mv "${tmp}" "${path}"
  done
}
[[ "$(ftctl_dr_runtime_default_restore_points_path "${PLAN}" "${REPAIR_STATUS_PATH}")" == "${REPAIR_POINTS}" ]]

ftctl_dr_runtime_repair_final_checkpoint_selection "${PLAN}" "${RUN}" 5 \
  "${REPAIR_RUN_PATH}" "${REPAIR_STATUS_PATH}" "${REPAIR_SESSION}" "${REPAIR_ACTIVE}"
grep -Fxq "failover_restore_point_ref=${FINAL_REF}" "${REPAIR_RUN_PATH}"
grep -Fxq 'failover_restore_point_sequence=5' "${REPAIR_RUN_PATH}"
/usr/bin/jq -e --arg ref "${FINAL_REF}" '.restorePoint.ref == $ref and .restorePoint.checkpointSequence == 5' \
  "${REPAIR_SESSION}" >/dev/null
/usr/bin/jq -e --arg ref "${FINAL_REF}" '.restorePoint.ref == $ref and .restorePoint.checkpointSequence == 5' \
  "${REPAIR_ACTIVE}" >/dev/null

echo 'ftctl DR legacy final checkpoint repair smoke: PASS'
