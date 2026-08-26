#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT}/lib/ftctl/dr_scheduler.sh"
bash -n "${ROOT}/lib/ftctl/dr_runtime.sh"

grep -q 'KillMode=control-group' "${ROOT}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service"
grep -q 'TimeoutStopSec=20s' "${ROOT}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service"
grep -q 'ftctl_dr_scheduler_cancel_active_transfer' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'ftctl_dr_scheduler_queue_cancel_recovery' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'pending_reseed_reason=OPERATOR_CANCELED_TRANSFER' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'state=CANCEL_REQUESTED' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'terminal_authoritative=true' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'runtime_endpoints_drained=true' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q '"state":"CANCELED","terminal_authoritative":true,"runtime_endpoints_drained":true' "${ROOT}/lib/ftctl/dr_runtime.sh"

source "${ROOT}/lib/ftctl/dr_scheduler.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
printf '%s\n' '{"direction":"KVM_TO_KVM","transport":{"mode":"site-agent-nbd"}}' > "${tmp}/profile.json"
touch "${tmp}/status.state" "${tmp}/run.state"

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
    scheduler_recovery_state|scheduler_recovery_trigger) printf '\n' ;;
    latest_completed_producer_run_uuid|run) printf 'run-1\n' ;;
    nbd_teardown_state) printf 'READY\n' ;;
  esac
}
ftctl_dr_runtime_run_path() {
  [[ "${2-}" == "run-1" ]] && printf '%s\n' "${tmp}/run.state" || printf '%s/%s.state\n' "${tmp}" "${2-}"
}
ftctl_dr_scheduler_recover() { printf '%s\n' called > "${tmp}/recover.called"; }

test_control_command=stop
ftctl_dr_scheduler_reconcile_plan plan-1
[[ ! -e "${tmp}/recover.called" ]]

test_control_command=run
ftctl_dr_scheduler_reconcile_plan plan-1
[[ -e "${tmp}/recover.called" ]]

# A terminal one-shot operation has no live scheduler left to acknowledge a
# STOP request. Cancel must use that absence as the drain boundary instead of
# waiting for a worker that cannot respond.
ftctl_dr_scheduler_systemd_available() { return 0; }
ftctl_dr_scheduler_has_live_worker() { return 1; }
ftctl_dr_scheduler_active_value() { printf '\n'; }
ftctl_dr_scheduler_control_set() { printf '%s\n' "$*" > "${tmp}/control.set"; printf '42\n'; }
ftctl_dr_scheduler_control_ack() { printf '%s\n' "$*" > "${tmp}/cancel.ack"; }
ftctl_dr_scheduler_wait_for_ack() { return 21; }
ftctl_now_iso8601() { printf '2026-08-25T14:00:00+09:00\n'; }
ftctl_dr_scheduler_sequence_path() { printf '%s\n' "${tmp}/sequence.state"; }
ftctl_dr_scheduler_update_state() { printf '%s\n' "$*" > "${tmp}/cancel.state"; }
ftctl_dr_runtime_launch_nonce() { printf 'recovery-run-1\n'; }
ftctl_dr_runtime_profile_value() {
  case "${2-}" in
    direction) printf 'KVM_TO_KVM\n' ;;
    transport.mode) printf 'site-agent-nbd\n' ;;
  esac
}
ftctl_dr_runtime_path_set() { local path="${1-}"; shift; printf '%s\n' "$@" >> "${path}"; }
ftctl_state_set_path() { local path="${1-}"; shift; printf '%s\n' "$@" > "${path}"; }
ftctl_log_event() { :; }
ftctl_dr_runtime_state_get_from_path() {
  case "${2-}" in
    transfer_activity_state) printf 'IDLE\n' ;;
    cycle_state) printf 'IDLE\n' ;;
    baseline_state) printf 'LOCAL_DURABLE\n' ;;
    reseed_reason|current_checkpoint_state) printf '\n' ;;
  esac
}

generation="$(ftctl_dr_scheduler_cancel_active_transfer plan-1 run-1 "${tmp}/run.state" "${tmp}/status.state")"
[[ "${generation}" == "42" ]]
grep -q 'plan-1 42 STOPPED IDLE run-1' "${tmp}/cancel.ack"
grep -q 'runtime_endpoints_drained=true' "${tmp}/cancel.state"

recovery_run="$(ftctl_dr_scheduler_queue_cancel_recovery plan-1 run-1 "${tmp}/status.state")"
[[ "${recovery_run}" == "recovery-run-1" ]]
grep -q '^plan-1 run cancel-auto-recovery recovery-run-1 false$' "${tmp}/control.set"
grep -q '^pending_reseed_run=recovery-run-1$' "${tmp}/sequence.state"
grep -q '^pending_reseed_request_bound=false$' "${tmp}/sequence.state"
grep -q '^requested_cycle_state=PENDING$' "${tmp}/sequence.state"
grep -q 'scheduler_desired_state=RUNNING' "${tmp}/cancel.state"
grep -q 'scheduler_recovery_run_uuid=recovery-run-1' "${tmp}/cancel.state"
grep -q '^scheduler_recovery_parent_run_uuid=run-1$' "${tmp}/recovery-run-1.state"

echo 'ftctl DR active cancel recovery smoke: PASS'
