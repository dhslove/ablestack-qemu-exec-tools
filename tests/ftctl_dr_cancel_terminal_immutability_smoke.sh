#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

FTCTL_RUN_DIR="${tmp}/run"
FTCTL_STATE_DIR="${tmp}/state"
export FTCTL_RUN_DIR FTCTL_STATE_DIR

# Match the production loader order so runtime state reads exercise the real
# key-value parser instead of silently falling back to empty values.
source "${ROOT}/lib/ftctl/state.sh"
source "${ROOT}/lib/ftctl/dr_runtime.sh"

ftctl_ensure_dir() { mkdir -p "${1-}"; }
ftctl_now_iso8601() { printf '2026-08-26T18:30:00+09:00\n'; }
ftctl_dr_runtime_require_plan() { return 0; }
ftctl_dr_runtime_require_run() { return 0; }
ftctl__json_escape() {
  python3 -c 'import json,sys; print(json.dumps(sys.argv[1])[1:-1])' "${1-}"
}
ftctl_dr_scheduler_control_action() {
  printf 'unexpected\n' > "${tmp}/scheduler-called"
  return 1
}

plan='plan-terminal'
run='run-terminal'
ftctl_dr_runtime_ensure_plan_dirs "${plan}"
run_path="$(ftctl_dr_runtime_run_path "${plan}" "${run}")"
cat > "${run_path}" <<'EOF'
plan=plan-terminal
run=run-terminal
state=READY
step=full-resync-completed
progress=100
terminal_source=ENGINE_TERMINAL
terminal_authoritative=true
runtime_endpoints_drained=true
transfer_activity_state=IDLE
latest_completed_cycle_sequence=75
EOF
cp "${run_path}" "${tmp}/before.state"

output="$(ftctl_dr_runtime_cancel "${plan}" "${run}" 0 1)"

grep -q '"result":"already_terminal"' <<<"${output}"
grep -q '"state":"READY"' <<<"${output}"
grep -q '"terminal_authoritative":true' <<<"${output}"
cmp -s "${tmp}/before.state" "${run_path}"
[[ ! -e "${tmp}/scheduler-called" ]]

echo 'ftctl DR cancel terminal immutability smoke: PASS'
