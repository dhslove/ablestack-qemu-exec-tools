#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT}/lib/ftctl/dr_scheduler.sh"
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
profile="${tmp}/profile.json"
status="${tmp}/status.state"
run_path="${tmp}/run.state"
touch "${profile}" "${status}" "${run_path}"

test_recovery_state=FAILED
test_reseed_reason=OPERATOR_CANCELED_TRANSFER

ftctl_dr_runtime_state_get_from_path() {
  case "${2-}" in
    state) printf 'READY\n' ;;
    active_side) printf 'SOURCE\n' ;;
    control_state) printf 'STOPPED\n' ;;
    transition_state) printf 'IDLE\n' ;;
    scheduler_recovery_state) printf '%s\n' "${test_recovery_state}" ;;
    reseed_reason) printf '%s\n' "${test_reseed_reason}" ;;
    nbd_teardown_state) printf 'DRAINED\n' ;;
    *) printf '\n' ;;
  esac
}
ftctl_dr_scheduler_control_set() {
  printf '%s\n' "$*" > "${tmp}/control.set"
  printf '41\n'
}
ftctl_dr_scheduler_sequence_path() { printf '%s\n' "${tmp}/sequence.state"; }
ftctl_state_set_path() { local path="${1-}"; shift; printf '%s\n' "$@" > "${path}"; }
ftctl_dr_scheduler_recover_nbd_quarantine() { return 0; }
ftctl_dr_scheduler_active_worker_valid() { return 1; }
ftctl_dr_scheduler_update_state() { printf '%s\n' "$*" > "${tmp}/state.updated"; }
ftctl_dr_scheduler_launch_via_systemd() {
  printf '%s\n' "$*" > "${tmp}/launch.called"
  return 0
}
ftctl_now_iso8601() { printf '2026-08-26T21:00:00+09:00\n'; }

ftctl_dr_scheduler_recover plan-1 recover-run-1 "${profile}" "${run_path}" "${status}" MANUAL
grep -q '^plan-1 run cancel-recovery recover-run-1 false$' "${tmp}/control.set"
grep -q '^pending_reseed_run=recover-run-1$' "${tmp}/sequence.state"
grep -q '^requested_cycle_state=PENDING$' "${tmp}/sequence.state"
grep -q 'plan-1 recover-run-1' "${tmp}/launch.called"

rm -f "${tmp}/control.set" "${tmp}/launch.called"
test_recovery_state=NONE
if ftctl_dr_scheduler_recover plan-1 blocked-run "${profile}" "${run_path}" "${status}" MANUAL; then
  echo 'ordinary STOP unexpectedly recovered' >&2
  exit 1
fi
[[ ! -e "${tmp}/control.set" && ! -e "${tmp}/launch.called" ]]

test_recovery_state=FAILED
test_reseed_reason=
if ftctl_dr_scheduler_recover plan-1 blocked-run "${profile}" "${run_path}" "${status}" MANUAL; then
  echo 'FAILED without canceled-transfer evidence unexpectedly recovered' >&2
  exit 1
fi

echo 'ftctl DR cancel manual recovery smoke: PASS'
