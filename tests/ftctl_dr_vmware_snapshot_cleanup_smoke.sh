#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../lib/ftctl/dr_vmware_mover.sh
source "${ROOT}/lib/ftctl/dr_vmware_mover.sh"

mkdir -p "${TMP}/logs"
printf 'secret\n' > "${TMP}/password"
touch "${TMP}/snapshot-present"
cat > "${TMP}/govc" <<EOF
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "\$*" >> '${TMP}/govc.calls'
case "\$1 \$2" in
  'object.collect -json')
    if [[ -f '${TMP}/snapshot-present' ]]; then
      printf '%s\n' '{"Name":"durable-cycle-snapshot","Snapshot":{"Value":"snapshot-42"},"childSnapshotList":[{"Name":"durable-cycle-snapshot","Snapshot":{"Value":"snapshot-43"}}]}'
    else
      printf '%s\n' '{}'
    fi
    ;;
  'snapshot.tree -vm')
    if [[ -f '${TMP}/snapshot-present' ]]; then
      printf '%s\n' '{"Name":"durable-cycle-snapshot","Snapshot":{"Value":"snapshot-42"}}'
    else
      printf '%s\n' '{}'
    fi
    ;;
  'snapshot.remove -vm')
    [[ "\${4-}" == '-r=true' ]]
    [[ "\${5-}" == 'snapshot-42' ]]
    rm -f '${TMP}/snapshot-present'
    ;;
  *) exit 1 ;;
esac
EOF
chmod +x "${TMP}/govc"

FTCTL_DR_VMWARE_MOVER_LOG_DIR="${TMP}/logs"
FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH="${TMP}/source-snapshot.json"
cat > "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH}" <<'EOF'
{"cleanupRequired":true,"lifecycleState":"CLEANUP_FAILED","vmRef":"vm-1","lastSnapshotName":"next-cycle-wrong-name","lastSnapshotRef":"snapshot-42"}
EOF

ftctl_vmware_mover_cleanup_pending_snapshot "${TMP}/govc" '10.10.21.10' 'administrator' \
  "${TMP}/password" false

jq -e '.cleanupRequired == false and .lifecycleState == "CLEANED"
  and .lastSnapshotRef == "snapshot-42"
  and .lastSnapshotName == "durable-cycle-snapshot"' "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH}" >/dev/null
grep -q 'snapshot.remove -vm vm-1 -r=true snapshot-42' "${TMP}/govc.calls"

cat > "${TMP}/foreign-subtree.json" <<'EOF'
{"Name":"durable-cycle-snapshot","Snapshot":{"Value":"snapshot-42"},"childSnapshotList":[{"Name":"operator-snapshot","Snapshot":{"Value":"snapshot-99"}}]}
EOF
if ftctl_vmware_mover_snapshot_subtree_is_owned "${TMP}/foreign-subtree.json" \
    'snapshot-42' 'durable-cycle-snapshot'; then
  echo 'foreign snapshot descendant was incorrectly accepted' >&2
  exit 1
fi

# A missing object is an idempotently completed cleanup.
python3 - "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH}" <<'PY'
import json
import sys
path = sys.argv[1]
with open(path, "r", encoding="utf-8") as handle:
    data = json.load(handle)
data["cleanupRequired"] = True
data["lifecycleState"] = "CLEANUP_FAILED"
with open(path, "w", encoding="utf-8") as handle:
    json.dump(data, handle)
PY
ftctl_vmware_mover_cleanup_pending_snapshot "${TMP}/govc" '10.10.21.10' 'administrator' \
  "${TMP}/password" false
jq -e '.cleanupRequired == false and .lifecycleState == "CLEANED"' \
  "${FTCTL_DR_SOURCE_SNAPSHOT_STATUS_PATH}" >/dev/null

grep -q 'trap '\''ftctl_vmware_mover_on_exit'\'' EXIT' "${ROOT}/lib/ftctl/dr_vmware_mover.sh"
grep -q 'pending_cleanup_sequence=${sequence}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'cycle_state=WAITING_CLEANUP' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q '99) error_code="DR_VMWARE_SNAPSHOT_CLEANUP_PENDING"' "${ROOT}/lib/ftctl/dr_scheduler.sh"

echo 'ftctl DR VMware snapshot cleanup smoke: PASS'
