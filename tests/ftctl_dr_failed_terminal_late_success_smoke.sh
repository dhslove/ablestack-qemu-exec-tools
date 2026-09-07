#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export FTCTL_RUN_DIR="${TMP}/run"
export FTCTL_LOG_DIR="${TMP}/log"
export FTCTL_EVENTS_LOG="${TMP}/log/events.log"
export FTCTL_STATE_DIR="${TMP}/state"
export FTCTL_PROFILE_DIR="${TMP}/profiles"
mkdir -p "${FTCTL_LOG_DIR}" "${FTCTL_STATE_DIR}" "${FTCTL_PROFILE_DIR}"

ftctl_log_event() { :; }

# shellcheck source=../lib/ftctl/common.sh
source "${ROOT}/lib/ftctl/common.sh"
# shellcheck source=../lib/ftctl/state.sh
source "${ROOT}/lib/ftctl/state.sh"
# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"
# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"

PLAN='late-success-plan'
RUN='late-success-run'
PLAN_DIR="$(ftctl_dr_runtime_plan_dir "${PLAN}")"
RUN_PATH="$(ftctl_dr_runtime_run_path "${PLAN}" "${RUN}")"
TERMINAL_PATH="$(ftctl_dr_runtime_run_journal_path "${PLAN}" "${RUN}" terminal)"
SEQUENCE_PATH="${PLAN_DIR}/scheduler/sequence.state"
RESTORE_POINTS="${PLAN_DIR}/restore-points.jsonl"
MANIFEST="${PLAN_DIR}/${RUN}-cycle-2-manifest.json"
CHECKPOINT="${PLAN_DIR}/${RUN}-cycle-2-checkpoint.json"
mkdir -p "$(dirname "${RUN_PATH}")" "$(dirname "${SEQUENCE_PATH}")"
printf '{}\n' > "${MANIFEST}"
printf '{}\n' > "${CHECKPOINT}"

cat > "${RUN_PATH}" <<EOF
plan=${PLAN}
run=${RUN}
action=dr-sync-start
state=READY
step=target-checkpoint-ready
progress=100
control_request_run_uuid=${RUN}
requested_cycle_mode=FULL_RESEED
requested_cycle_owner_run=${RUN}
requested_cycle_sequence=1
requested_cycle_state=FAILED
restore_points_path=${RESTORE_POINTS}
scheduler_session_uuid=${PLAN}
scheduler_lease_epoch=7
worker_state=TERMINAL_PUBLISHED
worker_exit_code=1
terminal_authoritative=true
error_code=DR_CBT_QUERY_FAILED
EOF
cat > "${SEQUENCE_PATH}" <<EOF
requested_cycle_mode=FULL_RESEED
requested_cycle_owner_run=${RUN}
requested_cycle_sequence=1
requested_cycle_state=FAILED
requested_cycle_error=DR_CBT_QUERY_FAILED
EOF
ftctl_dr_runtime_terminal_journal_write "${PLAN}" "${RUN}" "${PLAN}" 7 FAILED 1 DR_CBT_QUERY_FAILED \
  '2026-09-08T00:00:00Z'

# A different Run is not sufficient recovery evidence.
printf '%s\n' "$(jq -cn --arg p "${PLAN}" --arg m "${MANIFEST}" --arg c "${CHECKPOINT}" \
  '{planUuid:$p,runUuid:"other-run",producerRunUuid:"other-run",checkpointSequence:2,cycleType:"full-seed",requestedMode:"FULL_RESEED",state:"READY",cycleCommitState:"LOCAL_DURABLE",cycleToken:($p+":2"),manifest:$m,checkpoint:$c}')" \
  > "${RESTORE_POINTS}"
ftctl_dr_runtime_repair_requested_cycle_terminal "${PLAN}" "${RUN}" "${RUN_PATH}"
grep -q '^terminal_state=FAILED$' "${TERMINAL_PATH}"

printf '%s\n' "$(jq -cn --arg p "${PLAN}" --arg r "${RUN}" --arg m "${MANIFEST}" --arg c "${CHECKPOINT}" \
  '{planUuid:$p,runUuid:$r,producerRunUuid:$r,checkpointSequence:2,cycleType:"full-seed",requestedMode:"FULL_RESEED",effectiveMode:"FULL_RESEED",state:"READY",cycleCommitState:"LOCAL_DURABLE",cycleToken:($p+":2"),manifest:$m,checkpoint:$c,sourceCheckpointAt:"2026-09-08T00:00:05Z",targetDurableAt:"2026-09-08T00:00:10Z"}')" \
  >> "${RESTORE_POINTS}"
ftctl_dr_runtime_repair_requested_cycle_terminal "${PLAN}" "${RUN}" "${RUN_PATH}"

grep -q '^terminal_state=SUCCEEDED$' "${TERMINAL_PATH}"
grep -q '^terminal_exit_code=0$' "${TERMINAL_PATH}"
grep -q '^state=READY$' "${RUN_PATH}"
grep -q '^step=full-resync-completed$' "${RUN_PATH}"
grep -q '^requested_cycle_sequence=2$' "${RUN_PATH}"
grep -q '^requested_cycle_state=COMPLETED$' "${RUN_PATH}"
grep -q '^worker_exit_code=0$' "${RUN_PATH}"
grep -q '^error_code=$' "${RUN_PATH}"
grep -q '^requested_cycle_sequence=2$' "${SEQUENCE_PATH}"
grep -q '^requested_cycle_state=COMPLETED$' "${SEQUENCE_PATH}"

echo 'ftctl DR failed requested terminal late-success smoke: PASS'
