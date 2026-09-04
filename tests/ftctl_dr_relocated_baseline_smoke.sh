#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT}/lib/ftctl/dr_scheduler.sh"
bash -n "${ROOT}/lib/ftctl/dr_runtime.sh"
bash -n "${ROOT}/bin/ablestack_vm_ftctl.sh"

source "${ROOT}/lib/ftctl/dr_scheduler.sh"

tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT
profile="${tmp}/profile.json"
state="${tmp}/run.state"
status="${tmp}/status.state"
sequence="${tmp}/sequence.state"

cat > "${profile}" <<'JSON'
{
  "source":{"provider":"ABLESTACK"},
  "target":{"provider":"ABLESTACK"},
  "request":{
    "resumeBaselineCheckpointSequence":259,
    "minimumCompletedCheckpointSequence":260,
    "checkpointSequence":259,
    "checkpointState":"READY",
    "checkpointRef":"ftctl:plan-old:run-old:259",
    "checkpointCycleType":"incremental",
    "checkpointCycleToken":"plan-old:259",
    "checkpointEffectiveMode":"NO_CHANGE",
    "checkpointSourceCreatedAt":"2026-09-04T16:46:02+09:00",
    "checkpointTargetReadyAt":"2026-09-04T16:46:05+09:00",
    "checkpointIncrementalVerified":true
  }
}
JSON
printf 'run=run-new\n' > "${state}"
: > "${status}"

ftctl_dr_scheduler_sequence_path() { printf '%s\n' "${sequence}"; }
ftctl_dr_scheduler_current_plan_sequence() { printf '0\n'; }
ftctl_dr_scheduler_current_authority_sequence() { printf '724\n'; }
ftctl_now_iso8601() { printf '2026-09-04T23:00:00+09:00\n'; }
ftctl_dr_runtime_profile_value() {
  jq -r --arg path "${2-}" 'getpath($path | split(".")) // empty' "${1-}"
}
ftctl_dr_runtime_state_get_from_path() {
  sed -n "s/^${2-}=//p" "${1-}" 2>/dev/null | tail -1
}
ftctl_state_set_path() {
  local path="${1-}"
  shift
  printf '%s\n' "$@" > "${path}"
}
ftctl_dr_scheduler_update_state() {
  local run_path="${1-}" status_path="${2-}"
  shift 2
  printf '%s\n' "$@" >> "${run_path}"
  cp -f "${run_path}" "${status_path}"
}

ftctl_dr_scheduler_seed_relocated_baseline plan-new "${profile}" "${state}" "${status}" '' ''

grep -q '^plan_cycle_sequence=259$' "${sequence}"
grep -q '^minimum_completed_checkpoint_sequence=260$' "${sequence}"
grep -q '^immediate_cycle_pending=true$' "${sequence}"
grep -q '^latest_completed_checkpoint_sequence=259$' "${status}"
grep -q '^latest_completed_checkpoint_ref=ftctl:plan-old:run-old:259$' "${status}"
grep -q '^baseline_state=LOCAL_DURABLE$' "${status}"
grep -q '^target_durable=true$' "${status}"

bad_profile="${tmp}/bad-profile.json"
jq '.request.checkpointTargetReadyAt = ""' "${profile}" > "${bad_profile}"
if ftctl_dr_scheduler_seed_relocated_baseline plan-new "${bad_profile}" "${state}" "${status}" 300 301; then
  echo 'incomplete relocated baseline evidence was accepted' >&2
  exit 1
fi

echo 'ftctl DR relocated baseline smoke: PASS'
