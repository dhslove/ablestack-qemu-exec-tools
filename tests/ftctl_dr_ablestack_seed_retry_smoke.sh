#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
latest_completed=""

ftctl_dr_runtime_state_get_from_path() {
  local _path="${1-}" key="${2-}"
  [[ "${key}" == "latest_completed_checkpoint_sequence" ]] && printf '%s\n' "${latest_completed}"
}
ftctl_dr_kvm_vmware_baseline_path() { return 1; }

# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

[[ "$(ftctl_dr_scheduler_cycle_type 1 ABLESTACK /tmp/state ABLESTACK plan)" == "full-seed" ]]
[[ "$(ftctl_dr_scheduler_cycle_type 4 ABLESTACK /tmp/state ABLESTACK plan)" == "full-seed" ]]
latest_completed="3"
[[ "$(ftctl_dr_scheduler_cycle_type 4 ABLESTACK /tmp/state ABLESTACK plan)" == "incremental" ]]
[[ "$(ftctl_dr_scheduler_cycle_type 4 VMWARE /tmp/state ABLESTACK plan)" == "incremental" ]]

grep -q 'failed_component="ablestack-replication-mover"' "${ROOT}/lib/ftctl/dr_scheduler.sh"
printf 'ftctl ABLESTACK seed retry smoke: PASS\n'
