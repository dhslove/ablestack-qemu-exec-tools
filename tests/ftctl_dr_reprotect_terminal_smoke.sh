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
cloud_authority_generation=336
cloud_cutover_session_id=cutover-336
target_power_state=POWERED_ON
target_promotion_state=PROMOTED
EOF
touch "${AUTH_RUN_PATH}"
cat > "${AUTH_SPEC}" <<EOF
{
  "expectedActiveSide": "TARGET",
  "authorityGeneration": 336,
  "checkpointSequence": 6,
  "cutoverSessionId": "cutover-336",
  "targetPowerState": "POWERED_ON",
  "targetPromotionState": "PROMOTED"
}
EOF

ftctl_dr_runtime_capture_authority_context \
  "${AUTH_PLAN}" "${AUTH_RUN_PATH}" "${AUTH_STATUS}" "${AUTH_SPEC}"
grep -q '^authority_state=FAILED_OVER$' "${AUTH_RUN_PATH}"
grep -q '^active_side=TARGET$' "${AUTH_RUN_PATH}"
grep -q '^checkpoint_sequence=7$' "${AUTH_RUN_PATH}"
grep -q '^cloud_authority_generation=336$' "${AUTH_RUN_PATH}"

sed -i 's/^checkpoint_sequence=7$/checkpoint_sequence=5/' "${AUTH_STATUS}"
if ftctl_dr_runtime_capture_authority_context \
    "${AUTH_PLAN}" "${AUTH_RUN_PATH}" "${AUTH_STATUS}" "${AUTH_SPEC}"; then
  echo "ERROR: stale FTCTL checkpoint was accepted" >&2
  exit 1
fi

echo "ftctl DR reprotect terminal smoke: PASS"
