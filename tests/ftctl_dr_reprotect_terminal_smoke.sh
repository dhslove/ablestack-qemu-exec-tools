#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PLAN="reprotect-terminal-plan"
RUN="reprotect-terminal-run"
CONFIG="${TMP}/ftctl.conf"
PLAN_DIR="${TMP}/run/dr-runtime/plans/${PLAN}"
RUN_PATH="${PLAN_DIR}/runs/${RUN}.state"
MANIFEST="${PLAN_DIR}/reprotect-manifest.json"
CHECKPOINT="${PLAN_DIR}/reprotect-checkpoint.json"

mkdir -p "${PLAN_DIR}/runs" "${TMP}/log"
printf '{}\n' > "${MANIFEST}"
printf '{}\n' > "${CHECKPOINT}"
cat > "${CONFIG}" <<EOF
FTCTL_RUN_DIR="${TMP}/run"
FTCTL_LOG_DIR="${TMP}/log"
FTCTL_EVENTS_LOG="${TMP}/log/events.log"
FTCTL_STATE_DIR="${TMP}/run/state"
FTCTL_PROFILE_DIR="${TMP}/profiles"
FTCTL_CLUSTER_CONFIG="${TMP}/cluster.conf"
FTCTL_CLUSTER_DIR="${TMP}/cluster"
FTCTL_CLUSTER_HOSTS_DIR="${TMP}/cluster/hosts"
FTCTL_BLOCKCOPY_TARGET_BASE_DIR="${TMP}/blockcopy"
FTCTL_XML_BACKUP_DIR="${TMP}/xml"
EOF

cat > "${RUN_PATH}" <<EOF
plan=${PLAN}
run=${RUN}
action=dr-reprotect
state=READY
step=reprotect-ready
progress=100
accepted=true
active_side=TARGET
worker_state=SUCCEEDED
worker_exit_code=0
worker_launch_nonce=test-launch
worker_generation=42
reprotect_completed_at=2026-08-23T00:00:10Z
reprotect_manifest_path=${MANIFEST}
reprotect_checkpoint_path=${CHECKPOINT}
error_code=
updated_at=2026-08-23T00:00:10Z
EOF
cp "${RUN_PATH}" "${PLAN_DIR}/status.state"

status_json="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status \
  --config "${CONFIG}" --plan "${PLAN}" --run "${RUN}" --json)"
jq -e '.state == "READY"
  and .step == "reprotect-ready"
  and .terminal_authoritative == true
  and .runtime_endpoints_drained == true
  and .worker_state == "TERMINAL_PUBLISHED"
  and .control_request_run_uuid == "reprotect-terminal-run"' <<<"${status_json}" >/dev/null

TERMINAL_PATH="${PLAN_DIR}/runs/${RUN}.journals/terminal.state"
[[ -f "${TERMINAL_PATH}" ]]
grep -q '^terminal_state=SUCCEEDED$' "${TERMINAL_PATH}"
grep -q '^terminal_authoritative=true$' "${TERMINAL_PATH}"

cat > "${PLAN_DIR}/runs/${RUN}.journals/worker.state" <<EOF
version=1
writer_role=worker
plan=${PLAN}
run=${RUN}
launch_nonce=test-launch
generation=42
worker_pid=999999
worker_start_ticks=1
worker_state=RUNNING
worker_heartbeat_at=2026-08-23T00:00:09Z
EOF

terminal_status_json="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status \
  --config "${CONFIG}" --plan "${PLAN}" --run "${RUN}" --json)"
jq -e '.terminal_authoritative == true
  and .worker_state == "TERMINAL_PUBLISHED"
  and .runtime_endpoints_drained == true' <<<"${terminal_status_json}" >/dev/null

# A failed Reprotect may have durably advanced the reverse checkpoint before a
# later transport failure. Retrying with the same committed Cloud authority is
# valid when the FTCTL checkpoint is newer, but a stale lower checkpoint must
# still fail closed.
export FTCTL_RUN_DIR="${TMP}/run"
export FTCTL_STATE_DIR="${TMP}/run/state"
# shellcheck source=../lib/ftctl/common.sh
source "${ROOT}/lib/ftctl/common.sh"
# shellcheck source=../lib/ftctl/state.sh
source "${ROOT}/lib/ftctl/state.sh"
# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"
# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"

AUTH_PLAN="reprotect-authority-plan"
AUTH_RUN="reprotect-authority-run"
AUTH_DIR="${TMP}/run/dr-runtime/plans/${AUTH_PLAN}"
AUTH_STATUS="${AUTH_DIR}/status.state"
AUTH_RUN_PATH="${AUTH_DIR}/runs/${AUTH_RUN}.state"
AUTH_SPEC="${AUTH_DIR}/runs/${AUTH_RUN}.authority.json"
mkdir -p "${AUTH_DIR}/runs"
cat > "${AUTH_STATUS}" <<EOF
state=ERROR
active_side=TARGET
checkpoint_sequence=7
cloud_authority_generation=61
cloud_cutover_session_id=cutover-61
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
EOF
touch "${AUTH_RUN_PATH}"
cat > "${AUTH_SPEC}" <<EOF
{
  "expectedActiveSide": "TARGET",
  "authorityGeneration": 61,
  "authoritySequenceFloor": 153,
  "checkpointSequence": 6,
  "cutoverSessionId": "cutover-61",
  "targetPowerState": "POWERED_ON",
  "targetPromotionState": "PROMOTED"
}
EOF

ftctl_dr_runtime_capture_authority_context \
  "${AUTH_PLAN}" "${AUTH_RUN_PATH}" "${AUTH_STATUS}" "${AUTH_SPEC}"
grep -q '^authority_state=FAILED_OVER$' "${AUTH_RUN_PATH}"
grep -q '^active_side=TARGET$' "${AUTH_RUN_PATH}"
grep -q '^checkpoint_sequence=7$' "${AUTH_RUN_PATH}"
grep -q '^cloud_authority_generation=61$' "${AUTH_RUN_PATH}"
grep -q '^cloud_authority_sequence_floor=153$' "${AUTH_RUN_PATH}"
[[ "$(ftctl_dr_scheduler_current_authority_sequence "${AUTH_PLAN}")" == "153" ]]

# A non-empty command floor is operation evidence and must not be erased by an
# empty previous status or a lower authority specification.
CLI_PLAN="reprotect-cli-floor-plan"
CLI_RUN="reprotect-cli-floor-run"
CLI_DIR="${TMP}/run/dr-runtime/plans/${CLI_PLAN}"
CLI_STATUS="${CLI_DIR}/status.state"
CLI_RUN_PATH="${CLI_DIR}/runs/${CLI_RUN}.state"
CLI_SPEC="${CLI_DIR}/runs/${CLI_RUN}.authority.json"
mkdir -p "${CLI_DIR}/runs"
cat > "${CLI_STATUS}" <<EOF
state=ERROR
active_side=TARGET
checkpoint_sequence=7
cloud_authority_generation=61
cloud_authority_sequence_floor=
cloud_cutover_session_id=cutover-61
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
EOF
printf 'cloud_authority_sequence_floor=676\n' > "${CLI_RUN_PATH}"
cp "${AUTH_SPEC}" "${CLI_SPEC}"
ftctl_dr_runtime_capture_authority_context \
  "${CLI_PLAN}" "${CLI_RUN_PATH}" "${CLI_STATUS}" "${CLI_SPEC}"
grep -q '^cloud_authority_sequence_floor=676$' "${CLI_RUN_PATH}"
[[ "$(ftctl_dr_scheduler_current_authority_sequence "${CLI_PLAN}")" == "676" ]]

ftctl_state_set_path "$(ftctl_dr_scheduler_sequence_path "${AUTH_PLAN}")" \
  "plan_cycle_sequence=7" \
  "authority_sequence=41"
AUTH_STATUS_JSON="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status \
  --config "${CONFIG}" --plan "${AUTH_PLAN}" --json)"
jq -e '.cloud_authority_generation == 61 and .authority_sequence == 153' \
  <<<"${AUTH_STATUS_JSON}" >/dev/null

# A stale target-site scheduler sequence must absorb the committed Cloud
# generation, while a newer local sequence must never move backwards.
ftctl_state_set_path "$(ftctl_dr_scheduler_sequence_path "${AUTH_PLAN}")" \
  "plan_cycle_sequence=7" \
  "authority_sequence=400"
ftctl_dr_runtime_capture_authority_context \
  "${AUTH_PLAN}" "${AUTH_RUN_PATH}" "${AUTH_STATUS}" "${AUTH_SPEC}"
[[ "$(ftctl_dr_scheduler_current_authority_sequence "${AUTH_PLAN}")" == "400" ]]

for _ in $(seq 1 20); do
  (ftctl_dr_scheduler_next_authority_sequence "${AUTH_PLAN}" >/dev/null) &
done
wait
[[ "$(ftctl_dr_scheduler_current_authority_sequence "${AUTH_PLAN}")" == "420" ]]

sed -i 's/^checkpoint_sequence=7$/checkpoint_sequence=5/' "${AUTH_STATUS}"
if ftctl_dr_runtime_capture_authority_context \
    "${AUTH_PLAN}" "${AUTH_RUN_PATH}" "${AUTH_STATUS}" "${AUTH_SPEC}"; then
  echo "ERROR: stale FTCTL checkpoint was accepted" >&2
  exit 1
fi

echo "ftctl DR reprotect terminal smoke: PASS"
