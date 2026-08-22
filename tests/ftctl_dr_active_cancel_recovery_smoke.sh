#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

bash -n "${ROOT}/lib/ftctl/dr_scheduler.sh"
bash -n "${ROOT}/lib/ftctl/dr_runtime.sh"

grep -q 'KillMode=control-group' "${ROOT}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service"
grep -q 'TimeoutStopSec=20s' "${ROOT}/lib/ftctl/systemd/ablestack-vm-ftctl-dr@.service"
grep -q 'ftctl_dr_scheduler_cancel_active_transfer' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'pending_reseed_reason=OPERATOR_CANCELED_TRANSFER' "${ROOT}/lib/ftctl/dr_scheduler.sh"
grep -q 'state=CANCEL_REQUESTED' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'terminal_authoritative=true' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q 'runtime_endpoints_drained=true' "${ROOT}/lib/ftctl/dr_runtime.sh"
grep -q '"state":"CANCELED","terminal_authoritative":true,"runtime_endpoints_drained":true' "${ROOT}/lib/ftctl/dr_runtime.sh"

echo 'ftctl DR active cancel recovery smoke: PASS'
