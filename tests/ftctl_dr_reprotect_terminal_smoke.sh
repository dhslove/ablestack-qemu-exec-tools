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

# A retry after a partially projected Reprotect adopts an already healthy
# reverse scheduler only when every same-Plan durable and ownership proof is
# present. It must not start another full seed.
ADOPT_PLAN="reprotect-adopt-plan"
ADOPT_RUN="reprotect-adopt-run"
ADOPT_DIR="${TMP}/run/dr-runtime/plans/${ADOPT_PLAN}"
ADOPT_PROFILE="${ADOPT_DIR}/profile.json"
ADOPT_RUN_PATH="${ADOPT_DIR}/runs/${ADOPT_RUN}.state"
ADOPT_STATUS="${ADOPT_DIR}/status.state"
ADOPT_REVERSE_PROFILE="${ADOPT_DIR}/reverse-profiles/original-reprotect.json"
ADOPT_MANIFEST="${ADOPT_DIR}/manifests/cycle-180.json"
ADOPT_CHECKPOINT="${ADOPT_DIR}/checkpoints/cycle-180.json"
mkdir -p "${ADOPT_DIR}/runs" "${ADOPT_DIR}/reprotects" \
  "${ADOPT_DIR}/reverse-profiles" "${ADOPT_DIR}/manifests" \
  "${ADOPT_DIR}/checkpoints" "${ADOPT_DIR}/scheduler"
printf '{}\n' > "${ADOPT_REVERSE_PROFILE}"
printf '{}\n' > "${ADOPT_MANIFEST}"
printf '{}\n' > "${ADOPT_CHECKPOINT}"
cat > "${ADOPT_PROFILE}" <<EOF
{"planUuid":"${ADOPT_PLAN}","direction":"KVM_TO_KVM","activeSide":"SOURCE","source":{"provider":"ABLESTACK"},"target":{"provider":"ABLESTACK"}}
EOF
cat > "${ADOPT_DIR}/reprotects/active.json" <<EOF
{"planUuid":"${ADOPT_PLAN}","state":"READY","activeSide":"TARGET","reverseProfilePath":"${ADOPT_REVERSE_PROFILE}","restorePoint":{"checkpointSequence":179}}
EOF
cat > "${ADOPT_STATUS}" <<EOF
latest_completed_checkpoint_sequence=180
latest_completed_manifest_path=${ADOPT_MANIFEST}
latest_completed_checkpoint_path=${ADOPT_CHECKPOINT}
latest_completed_source_checkpoint_at=2026-08-31T01:40:44+09:00
latest_completed_target_durable_at=2026-08-31T01:40:45+09:00
EOF
cat > "${ADOPT_DIR}/scheduler/active.pid" <<EOF
worker_run_uuid=scheduler-owner-180
EOF
cat > "${ADOPT_DIR}/scheduler/control.ack" <<EOF
state=RUNNING
request_run_uuid=scheduler-owner-180
active_worker_run_uuid=scheduler-owner-180
owner_matched=true
EOF
cat > "${ADOPT_DIR}/scheduler/sequence.state" <<EOF
plan_cycle_sequence=180
reprotect_baseline_sequence=179
EOF
printf 'active_side=TARGET\n' > "${ADOPT_RUN_PATH}"
ftctl_dr_scheduler_active_worker_valid() { return 0; }
ftctl_dr_runtime_adopt_existing_reprotect \
  "${ADOPT_PLAN}" "${ADOPT_PROFILE}" "${ADOPT_RUN_PATH}" "${ADOPT_STATUS}"
grep -q '^reprotect_idempotent_adopted=true$' "${ADOPT_RUN_PATH}"
grep -q '^checkpoint_sequence=180$' "${ADOPT_RUN_PATH}"
grep -q "^manifest_path=${ADOPT_MANIFEST}$" "${ADOPT_RUN_PATH}"

sed -i 's/^latest_completed_checkpoint_sequence=180$/latest_completed_checkpoint_sequence=178/' "${ADOPT_STATUS}"
if ftctl_dr_runtime_adopt_existing_reprotect \
    "${ADOPT_PLAN}" "${ADOPT_PROFILE}" "${ADOPT_RUN_PATH}" "${ADOPT_STATUS}"; then
  echo "ERROR: stale reverse checkpoint was adopted" >&2
  exit 1
fi

# A scheduler activated by a completed Reprotect must retain the immutable
# Cloud authority snapshot. Older installed schedulers omitted those fields,
# so transition preflight may recover them read-only from the matching READY
# Reprotect session while all scheduler ownership proofs remain healthy.
RECOVERY_PLAN="reprotect-authority-recovery-plan"
RECOVERY_RUN="prior-reprotect"
RECOVERY_DIR="${TMP}/run/dr-runtime/plans/${RECOVERY_PLAN}"
RECOVERY_PROFILE="${RECOVERY_DIR}/profile.json"
RECOVERY_STATUS="${RECOVERY_DIR}/status.state"
RECOVERY_ACTIVE="${RECOVERY_DIR}/reprotects/active.json"
RECOVERY_AUTHORITY="${RECOVERY_DIR}/runs/${RECOVERY_RUN}.authority.json"
mkdir -p "${RECOVERY_DIR}/runs" "${RECOVERY_DIR}/reprotects"
printf '{"planUuid":"%s"}\n' "${RECOVERY_PLAN}" > "${RECOVERY_PROFILE}"
cat > "${RECOVERY_STATUS}" <<EOF
plan=${RECOVERY_PLAN}
run=scheduler-owner
action=dr-scheduler-run
state=READY
step=target-checkpoint-ready
progress=100
active_side=TARGET
scheduler_state=RUNNING
scheduler_health=HEALTHY
owner_matched=true
protection_state=READY
EOF
cat > "${RECOVERY_ACTIVE}" <<EOF
{"planUuid":"${RECOVERY_PLAN}","runUuid":"${RECOVERY_RUN}","state":"READY","activeSide":"TARGET"}
EOF
cat > "${RECOVERY_AUTHORITY}" <<EOF
{"expectedActiveSide":"TARGET","authorityGeneration":112,"targetPowerState":"POWERED_ON","sourceFenceState":"VERIFIED","sourcePowerState":"POWERED_OFF"}
EOF
RECOVERY_SHA="$(sha256sum "${RECOVERY_STATUS}" | awk '{print $1}')"
RECOVERY_JSON="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-transition-preflight \
  --config "${CONFIG}" --plan "${RECOVERY_PLAN}" --operation reprotect \
  --expected-authority TARGET --authority-generation 112 --json)"
jq -e '.ready == true
  and .authority_generation == 112
  and .target_power_state == "POWERED_ON"
  and .source_fence_state == "VERIFIED"
  and .source_power_state == "POWERED_OFF"' <<<"${RECOVERY_JSON}" >/dev/null
[[ "$(sha256sum "${RECOVERY_STATUS}" | awk '{print $1}')" == "${RECOVERY_SHA}" ]]

echo "ftctl DR reprotect terminal smoke: PASS"
