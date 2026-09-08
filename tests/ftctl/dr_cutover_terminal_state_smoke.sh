#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for library in common config logging libvirt_wrap state profile inventory cluster blockcopy dr_key standby xcolo fencing failover events dr_ablestack dr_vmware dr_scheduler guestprep dr_runtime verify orchestrator; do
  # shellcheck source=/dev/null
  source "${ROOT_DIR}/lib/ftctl/${library}.sh"
done

tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT
FTCTL_RUN_DIR="${tmp_dir}/run"
FTCTL_LOG_DIR="${tmp_dir}/log"
FTCTL_EVENTS_LOG="${FTCTL_LOG_DIR}/events.log"

plan="plan-cutover-terminal-smoke"
run="failover-run"
session="cutover-session"
run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
status_path="$(ftctl_dr_runtime_status_path "${plan}")"
mkdir -p "$(dirname "${run_path}")" "${FTCTL_LOG_DIR}"

ftctl_state_write_kv_all "${run_path}" \
  "plan=${plan}" "run=${run}" "action=dr-failover" "state=CUTOVER_READY" \
  "step=cutover-ready" "progress=100" "active_side=SOURCE" \
  "failover_session_id=${session}" "failover_restore_point_sequence=17" \
  "cloud_authority_generation=17" "scheduler_state=STOPPED" \
  "scheduler_desired_state=RUNNING" "scheduler_health=HEALTHY" \
  "scheduler_recovery_state=NONE" "replication_activity=RUNNING" \
  "scheduler_pid_alive=true" "owner_matched=true" \
  "active_worker_run_uuid=${run}" "active_worker_pid=1234" \
  "active_worker_start_ticks=5678" "worker_heartbeat_at=2026-07-30T00:00:00Z"
ftctl_dr_runtime_publish_status "${run_path}" "${status_path}"

ftctl_dr_runtime_cutover_commit \
  "${plan}" "${run}" "${session}" 17 17 \
  "POWERED_ON" "POWER_STATE_VALIDATED" 1 >/dev/null

for path in "${run_path}" "${status_path}"; do
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" state)" == "FAILED_OVER" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" active_side)" == "TARGET" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_state)" == "STOPPED" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_desired_state)" == "STOPPED" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_health)" == "SUPPRESSED" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_recovery_state)" == "SUPPRESSED" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" replication_activity)" == "STOPPED" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" scheduler_pid_alive)" == "false" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" owner_matched)" == "false" ]]
  [[ -z "$(ftctl_dr_runtime_state_get_from_path "${path}" active_worker_run_uuid)" ]]
  [[ -z "$(ftctl_dr_runtime_state_get_from_path "${path}" active_worker_pid)" ]]
  [[ -z "$(ftctl_dr_runtime_state_get_from_path "${path}" worker_heartbeat_at)" ]]
  [[ "$(ftctl_dr_runtime_state_get_from_path "${path}" engine_ack_state)" == "ACKNOWLEDGED" ]]
done

# Same generation must be idempotent and retain the canonical terminal contract.
ftctl_dr_runtime_cutover_commit \
  "${plan}" "${run}" "${session}" 17 17 \
  "POWERED_ON" "POWER_STATE_VALIDATED" 1 >/dev/null
[[ "$(ftctl_dr_runtime_state_get_from_path "${status_path}" scheduler_desired_state)" == "STOPPED" ]]

set +e
ftctl_dr_runtime_cutover_commit \
  "${plan}" "${run}" "${session}" 17 16 \
  "POWERED_ON" "POWER_STATE_VALIDATED" 1 >/dev/null
rc=$?
set -e
[[ "${rc}" -eq 79 ]]

printf 'PASS: FTCTL DR cutover commit publishes canonical TARGET terminal state\n'
