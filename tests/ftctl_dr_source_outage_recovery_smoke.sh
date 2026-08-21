#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_now_iso8601() { printf '2026-08-21T00:00:00Z\n'; }

# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"
# shellcheck source=../lib/ftctl/dr_vmware_mover.sh
source "${ROOT}/lib/ftctl/dr_vmware_mover.sh"

ftctl_vmware_mover_is_source_transport_failure 'dial tcp 10.10.21.10:443: connect: no route to host'
ftctl_vmware_mover_is_source_transport_failure 'connection timed out'
ftctl_vmware_mover_is_source_transport_failure 'POST "/sdk": 503 Service Unavailable'
ftctl_vmware_mover_is_source_transport_failure 'no healthy upstream'
if ftctl_vmware_mover_is_source_transport_failure 'VixDiskLib_ConnectEx: One of the parameters was invalid'; then
  echo 'invalid VDDK parameters must not be classified as a source outage' >&2
  exit 1
fi

FTCTL_DR_SOURCE_RETRY_SEC=15
FTCTL_DR_SOURCE_RETRY_MAX_SEC=60
first="$(ftctl_dr_scheduler_source_retry_delay plan-a 1)"
second="$(ftctl_dr_scheduler_source_retry_delay plan-a 2)"
capped="$(ftctl_dr_scheduler_source_retry_delay plan-a 9)"
(( first >= 15 && first <= 30 ))
(( second >= 30 && second <= 45 ))
[[ "${capped}" == '60' ]]

mkdir -p "${TMP}/logs"
printf 'secret\n' > "${TMP}/password"
cat > "${TMP}/govc" <<'EOF'
#!/usr/bin/env bash
echo 'Post "https://10.10.21.10/sdk": dial tcp 10.10.21.10:443: connect: no route to host' >&2
exit 1
EOF
chmod +x "${TMP}/govc"
FTCTL_DR_VMWARE_MOVER_LOG_DIR="${TMP}/logs"
set +e
ftctl_vmware_mover_create_run_snapshot "${TMP}/govc" '10.10.21.10' 'administrator' \
  "${TMP}/password" false 'vm-1' 'ftctl-test-snapshot'
rc=$?
set -e
[[ "${rc}" == '98' ]]

cat > "${TMP}/govc" <<'EOF'
#!/usr/bin/env bash
echo 'POST "/sdk": 503 Service Unavailable' >&2
exit 1
EOF
chmod +x "${TMP}/govc"
set +e
ftctl_vmware_mover_create_run_snapshot "${TMP}/govc" '10.10.21.10' 'administrator' \
  "${TMP}/password" false 'vm-1' 'ftctl-test-snapshot-503'
rc=$?
set -e
[[ "${rc}" == '98' ]]

grep -q 'pending_source_sequence=${sequence}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'state=WAITING_SOURCE' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'source_outage_since=' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'pending_reseed_sequence=${sequence}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'SOURCE_CBT_EPOCH_RESET' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'automatic_reseed_guard_generation=${current_baseline_generation}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'dr.scheduler.baseline.*reseed-blocked' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'DR_CBT_RESEED_REQUIRED: previous VMware CBT changeId is outside the current CBT epoch' \
  "${ROOT}/lib/ftctl/dr_vmware_mover.sh"
grep -q 'FTCTL_DR_AUTOMATIC_RESEED_REASON' "${ROOT}/lib/ftctl/dr_vmware_mover.sh"

cat > "${TMP}/cbt-python" <<'EOF'
#!/usr/bin/env bash
if printf '%s\n' "$@" | grep -qx -- '--verify-current'; then
  printf '%s\n' '{"activation_verified":true,"new_change_id":"current-epoch-change-id"}'
  exit 0
fi
echo 'QueryChangedDiskAreas failed: vim.fault.FileFault' >&2
exit 1
EOF
chmod +x "${TMP}/cbt-python"
printf '# mock helper\n' > "${TMP}/helper.py"
FTCTL_DR_VMWARE_CBT_PYTHON="${TMP}/cbt-python"
FTCTL_DR_VMWARE_CBT_QUERY_HELPER="${TMP}/helper.py"
set +e
(
  ftctl_vmware_mover_query_cbt '10.10.21.10' 'administrator' "${TMP}/password" false '' \
    'vm-1' 'snapshot-1' 'scsi0:0' 'stale-change-id' "${TMP}/cbt-query.json" false '2000'
) >/dev/null 2>&1
rc=$?
set -e
[[ "${rc}" == '85' ]]

python3 - "${ROOT}/lib/ftctl/dr_scheduler.sh" <<'PY'
import pathlib
import sys

source = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
assert 'rc=90' in source
terminal = source.index('return "${rc}"', source.index('dr.scheduler.baseline" "reseed-blocked'))
success = source.index('automatic_reseed_guard_generation=', terminal)
assert terminal < success
PY

echo 'ftctl DR source outage recovery smoke: PASS'
