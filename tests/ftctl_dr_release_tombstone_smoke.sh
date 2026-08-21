#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

PLAN="release-contract-plan"
RUN="release-contract-run"
CONFIG="${TMP}/ftctl.conf"
PLAN_DIR="${TMP}/run/dr-runtime/plans/${PLAN}"

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
FTCTL_DR_SCHEDULER_INTERVAL_SEC="300"
EOF

mkdir -p "${PLAN_DIR}/runs"
cat > "${PLAN_DIR}/status.state" <<EOF
plan=${PLAN}
run=${RUN}
action=dr-release
state=RELEASED
step=release-completed
progress=100
accepted=true
active_side=TARGET
scheduler_state=STOPPED
scheduler_desired_state=STOPPED
protection_state=UNPROTECTED
profile_removed=true
released_at=2026-08-21T00:00:00Z
updated_at=2026-08-21T00:00:00Z
EOF
cat > "${PLAN_DIR}/release.json" <<EOF
{"schema_version":1,"contract_version":"dr-release-tombstone-v1","plan_uuid":"${PLAN}","run_uuid":"${RUN}","state":"RELEASED","step":"release-completed","protection_state":"UNPROTECTED","active_side":"TARGET","authority_generation":12,"scheduler_state":"STOPPED","worker_state":"IDLE","profile_removed":true,"runtime_removed":false,"vm_mutated":false,"storage_mutated":false,"network_mutated":false,"released_at":"2026-08-21T00:00:00Z"}
EOF

status_json="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status --config "${CONFIG}" --plan "${PLAN}" --json)"
jq -e '.state == "RELEASED" and .step == "release-completed" and .protection_state == "UNPROTECTED" and .profile_exists == false and .target_rpo_seconds == 300' <<<"${status_json}" >/dev/null

# Rebuild the terminal status from the tombstone after simulated runtime loss.
rm -f "${PLAN_DIR}/status.state"
restored_json="$(bash "${ROOT}/bin/ablestack_vm_ftctl.sh" dr-status --config "${CONFIG}" --plan "${PLAN}" --json)"
jq -e '.state == "RELEASED" and .step == "release-completed" and .protection_state == "UNPROTECTED" and .scheduler_state == "STOPPED" and .active_side == "TARGET" and .profile_exists == false' <<<"${restored_json}" >/dev/null
[[ -f "${PLAN_DIR}/status.state" ]]
[[ ! -f "${PLAN_DIR}/profile.json" ]]

echo "ftctl DR release tombstone smoke: PASS"
