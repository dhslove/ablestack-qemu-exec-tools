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

echo "ftctl DR reprotect terminal smoke: PASS"
