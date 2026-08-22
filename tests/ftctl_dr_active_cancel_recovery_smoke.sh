#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT}/lib/ftctl/dr_scheduler.sh"
bash -n "${ROOT}/lib/ftctl/dr_runtime.sh"

grep -q 'KillMode=control-group' "${ROOT}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service"
grep -q 'TimeoutStopSec=20s' "${ROOT}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service"
grep -q 'ftctl_dr_scheduler_cancel_active_transfer' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'pending_reseed_reason=OPERATOR_CANCELED_TRANSFER' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'state=CANCEL_REQUESTED' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'terminal_authoritative=true' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'runtime_endpoints_drained=true' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q '"state":"CANCELED","terminal_authoritative":true,"runtime_endpoints_drained":true' "${ROOT}/lib/ftctl/dr_runtime.sh"

source "${ROOT}/lib/ftctl/dr_scheduler.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
touch "${tmp}/profile.json" "${tmp}/status.state" "${tmp}/run.state"

ftctl_dr_runtime_profile_path() { printf '%s\n' "${tmp}/profile.json"; }
ftctl_dr_runtime_status_path() { printf '%s\n' "${tmp}/status.state"; }
ftctl_dr_scheduler_active_worker_valid() { return 1; }
ftctl_dr_scheduler_control_command() { printf '%s\n' "${test_control_command}"; }
ftctl_dr_runtime_state_get_from_path() {
  case "${2-}" in
    state) printf 'READY\n' ;;
    active_side) printf 'SOURCE\n' ;;
    control_state) printf 'RUNNING\n' ;;
    scheduler_desired_state) printf 'RUNNING\n' ;;
    transition_state) printf 'IDLE\n' ;;
    latest_completed_producer_run_uuid|run) printf 'run-1\n' ;;
    nbd_teardown_state) printf 'READY\n' ;;
  esac
}
ftctl_dr_runtime_run_path() { printf '%s\n' "${tmp}/run.state"; }
ftctl_dr_scheduler_recover() { printf '%s\n' called > "${tmp}/recover.called"; }

test_control_command=stop
ftctl_dr_scheduler_reconcile_plan plan-1
[[ ! -e "${tmp}/recover.called" ]]

test_control_command=run
ftctl_dr_scheduler_reconcile_plan plan-1
[[ -e "${tmp}/recover.called" ]]

echo 'ftctl DR active cancel recovery smoke: PASS'
