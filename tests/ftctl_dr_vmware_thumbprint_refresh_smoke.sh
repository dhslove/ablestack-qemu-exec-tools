#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=../lib/ftctl/dr_vmware_mover.sh
source "${ROOT}/lib/ftctl/dr_vmware_mover.sh"

ftctl_vmware_mover_fetch_vcenter_thumbprint() {
  printf '%s\n' 'NEW:THUMBPRINT'
}

FTCTL_DR_VMWARE_CONFIGURED_THUMBPRINT_SOURCE='backend-auto'
actual="$(ftctl_vmware_mover_resolve_thumbprint '10.10.21.10' false 'OLD:THUMBPRINT')"
[[ "${actual}" == 'NEW:THUMBPRINT' ]]

FTCTL_DR_VMWARE_CONFIGURED_THUMBPRINT_SOURCE='runtime'
actual="$(ftctl_vmware_mover_resolve_thumbprint '10.10.21.10' false 'PINNED:THUMBPRINT')"
[[ "${actual}" == 'PINNED:THUMBPRINT' ]]

status_path="$(mktemp)"
trap 'rm -f "${status_path}"' EXIT
FTCTL_DR_SOURCE_OPEN_STATUS_PATH="${status_path}"
FTCTL_DR_VMWARE_SOURCE_OPEN_TLS_VERIFY='false'
FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_PRESENT='true'
FTCTL_DR_VMWARE_SOURCE_OPEN_THUMBPRINT_SOURCE='backend-auto-refreshed'
ftctl_vmware_mover_write_source_open_status true '' 'VDDK source open succeeded' \
  'vm-1' 'snapshot-1' '[datastore1] vm/vm-000001.vmdk'

python3 - "${status_path}" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    payload = json.load(handle)

assert payload["ready"] is True
assert payload["error_code"] == ""
assert payload["thumbprintSource"] == "backend-auto-refreshed"
PY

grep -Fq 'ftctl_vmware_mover_write_source_open_status true "" "VMware source cycle completed"' \
  "${ROOT}/lib/ftctl/dr_vmware_mover.sh"

echo 'FTCTL VMware thumbprint refresh smoke: PASS'
