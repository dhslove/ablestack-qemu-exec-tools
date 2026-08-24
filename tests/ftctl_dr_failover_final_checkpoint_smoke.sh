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
