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

grep -q 'pending_source_sequence=${sequence}' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'state=WAITING_SOURCE' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'source_outage_since=' "${ROOT}/lib/ftctl/dr_scheduler.sh"

echo 'ftctl DR source outage recovery smoke: PASS'
