#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

FTCTL_DR_INITIAL_JITTER_MAX_SEC=30
ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_now_iso8601() { printf '2026-08-21T00:00:00Z\n'; }
ftctl_iso_to_epoch() { date -d "$1" +%s; }

# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

restore_points="${TMP}/restore-points.jsonl"
cat > "${restore_points}" <<'EOF'
{"schedulerDurationSeconds":20}
{"schedulerDurationSeconds":35}
{"schedulerDurationSeconds":40}
EOF

[[ "$(ftctl_dr_scheduler_execution_budget_seconds "${restore_points}" 300)" == "40" ]]
[[ "$(ftctl_dr_scheduler_execution_budget_seconds "${TMP}/missing" 300)" == "60" ]]

durable_at='2026-08-21T00:00:00Z'
durable_epoch="$(date -d "${durable_at}" +%s)"
expected=$((durable_epoch + 300 - 40 - 4))
actual="$(ftctl_dr_scheduler_next_deadline_epoch "${durable_at}" 300 40 4)"
[[ "${actual}" == "${expected}" ]]

# Control and heartbeat work inside the wait loop must not accumulate into the
# RPO interval. Model two seconds of wall-clock progress per loop with no real
# sleeping and verify that a three-second wait exits after two probes.
clock_path="${TMP}/clock"
probe_path="${TMP}/probes"
printf '100\n' > "${clock_path}"
printf '0\n' > "${probe_path}"
ftctl_dr_scheduler_now_epoch() {
  local value
  value="$(cat "${clock_path}")"
  printf '%s\n' $((value + 2)) > "${clock_path}"
  printf '%s\n' "${value}"
}
ftctl_dr_scheduler_control_command() {
  local probes
  probes="$(cat "${probe_path}")"
  printf '%s\n' $((probes + 1)) > "${probe_path}"
  printf 'run\n'
}
ftctl_dr_scheduler_control_generation() { printf '7\n'; }
ftctl_dr_scheduler_active_worker_valid() { return 1; }
sleep() { :; }
ftctl_dr_scheduler_sleep_or_stop plan 3 7
[[ "$(cat "${probe_path}")" == "1" ]]

checkpoint="${TMP}/checkpoint.json"
printf '{"state":"READY"}\n' > "${checkpoint}"
ftctl_dr_scheduler_append_restore_point "${restore_points}" plan run 9 incremental driver manifest "${checkpoint}" 47
[[ "$(tail -1 "${restore_points}" | jq -r '.schedulerDurationSeconds')" == "47" ]]

grep -q 'ftctl_dr_runtime_json_number_field "target_rpo_seconds"' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'ftctl_dr_runtime_json_number_field "latest_completed_cycle_sequence"' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'ftctl_dr_runtime_json_string_field "scheduler_next_run_at"' "${ROOT}/lib/ftctl/dr_runtime.sh"

echo "ftctl DR RPO deadline smoke: PASS"
