#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT}/lib/ftctl/dr_scheduler.sh"
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
profile="${tmp}/profile.json"
state_path="${tmp}/run.state"
status_path="${tmp}/status.state"
touch "${profile}" "${state_path}" "${status_path}"

ftctl_dr_scheduler_session_uuid() { printf 'session-1\n'; }
ftctl_dr_scheduler_active_worker_valid() { [[ -f "${tmp}/systemd-launched" ]]; }
ftctl_dr_scheduler_pid_path() { printf '%s\n' "${tmp}/run.pid"; }
ftctl_dr_scheduler_pid_alive() { return 1; }
ftctl_dr_scheduler_has_live_worker() { return 1; }
ftctl_dr_scheduler_control_generation() { printf '7\n'; }
ftctl_dr_scheduler_update_state() {
  printf '%s\n' "$@" > "${tmp}/last-update"
}
ftctl_dr_scheduler_systemd_available() { return 0; }
ftctl_dr_scheduler_start() {
  touch "${tmp}/systemd-launched"
  return 0
}
ftctl_dr_scheduler_active_value() {
  case "${2-}" in
    pid) printf '4321\n' ;;
    start_ticks) printf '12345\n' ;;
    lease_epoch) printf '9\n' ;;
    *) printf '\n' ;;
  esac
}
ftctl_dr_scheduler_current_authority_sequence() { printf '42\n'; }
ftctl_now_iso8601() { printf '2026-08-31T01:22:16+09:00\n'; }

ftctl_dr_scheduler_ensure_running plan-1 scheduler-run-1 \
  "${profile}" "${state_path}" "${status_path}"

[[ -f "${tmp}/systemd-launched" ]]
[[ ! -e "${tmp}/run.pid" ]]
grep -q '^scheduler_state=RUNNING$' "${tmp}/last-update"
grep -q '^active_worker_run_uuid=scheduler-run-1$' "${tmp}/last-update"
grep -q '^owner_matched=true$' "${tmp}/last-update"

echo 'ftctl DR systemd async start smoke: PASS'
