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

echo 'FTCTL VMware thumbprint refresh smoke: PASS'
