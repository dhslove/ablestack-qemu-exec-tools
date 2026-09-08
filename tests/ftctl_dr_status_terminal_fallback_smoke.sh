#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PLAN="terminal-fallback-plan"
RUN="terminal-fallback-run"
CONFIG="${TMP}/ftctl.conf"
PLAN_DIR="${TMP}/run/dr-runtime/plans/${PLAN}"
RUN_PATH="${PLAN_DIR}/runs/${RUN}.state"

mkdir -p "${PLAN_DIR}/runs" "${TMP}/log"
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
FTCTL_DR_STATUS_MAX_BYTES=512
EOF

cat > "${RUN_PATH}" <<EOF
plan=${PLAN}
run=${RUN}
action=dr-test-failover
state=ERROR
step=test-materialization-failed
progress=100
accepted=false
worker_state=FAILED
worker_exit_code=46
test_session_state=CLEANED
test_artifacts_state=
test_cleanup_state=CLEANED
cleanup_required=false
checkpoint_lease_state=RELEASED
error_code=DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT
EOF
printf 'error_message=' >> "${RUN_PATH}"
head -c 8192 /dev/zero | tr '\0' x >> "${RUN_PATH}"
printf '\n' >> "${RUN_PATH}"
cp "${RUN_PATH}" "${PLAN_DIR}/status.state"

status_json="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status \
  --config "${CONFIG}" --plan "${PLAN}" --run "${RUN}" --json)"

jq -e '.state == "ERROR"
  and .step == "test-materialization-failed"
  and .worker_state == "FAILED"
  and .terminal_authoritative == true
  and .terminal_source == "ENGINE_TERMINAL"
  and .error_code == "DR_TEST_CHECKPOINT_GUEST_FS_INCONSISTENT"
  and .test_session_state == "CLEANED"
  and .test_artifacts_state == "CLEANED"
  and .test_cleanup_state == "CLEANED"
  and .cleanup_required == false
  and .checkpoint_lease_state == "RELEASED"
  and .status_payload_truncated == true
  and (.error_message | length) == 4096' <<<"${status_json}" >/dev/null

rm -f "${RUN_PATH}"
missing_run_status="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status \
  --config "${CONFIG}" --plan "${PLAN}" --run "new-operation-run" --json)"

jq -e '.result == "run_not_found"
  and .status_scope == "OPERATION"
  and .run_uuid == "new-operation-run"
  and .state == "QUEUED"
  and .step == "run-pending"
  and .run_exists == false
  and .accepted == false
  and .terminal_authoritative == false
  and .error_code == "not_found"
  and .error_message == ""
  and .action == "dr-status"
  and (.worker_state | not)
  and (.cycle_state | not)' <<<"${missing_run_status}" >/dev/null

echo "ftctl DR terminal status fallback smoke: PASS"
