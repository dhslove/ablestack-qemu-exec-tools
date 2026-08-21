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

checkpoint="${TMP}/checkpoint.json"
printf '{"state":"READY"}\n' > "${checkpoint}"
ftctl_dr_scheduler_append_restore_point "${restore_points}" plan run 9 incremental driver manifest "${checkpoint}" 47
[[ "$(tail -1 "${restore_points}" | jq -r '.schedulerDurationSeconds')" == "47" ]]

grep -q 'ftctl_dr_runtime_json_number_field "target_rpo_seconds"' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'ftctl_dr_runtime_json_number_field "latest_completed_cycle_sequence"' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'ftctl_dr_runtime_json_string_field "scheduler_next_run_at"' "${ROOT}/lib/ftctl/dr_runtime.sh"

echo "ftctl DR RPO deadline smoke: PASS"
