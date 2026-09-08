#!/usr/bin/env bash
set -euo pipefail

run_root="${FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}"
code_path="/usr/local/lib/ablestack-qemu-exec-tools/ftctl/dr_scheduler.sh"
code_sha="$(sha256sum "${code_path}" | awk '{print $1}')"
restarted=0
deferred=0
failed=0

state_value() {
  local path="$1" key="$2"
  awk -F= -v key="${key}" '$1 == key { value=substr($0, index($0,"=")+1) } END { print value }' "${path}" 2>/dev/null || true
}

while IFS= read -r unit; do
  [[ -n "${unit}" ]] || continue
  plan="${unit#ablestack-vm-ftctl-dr@}"
  plan="${plan%.service}"
  status_path="${run_root}/dr-runtime/plans/${plan}/status.state"
  cycle_state="$(state_value "${status_path}" cycle_state)"
  activity="$(state_value "${status_path}" replication_activity)"
  if [[ "${cycle_state:-IDLE}" != "IDLE" || "${activity:-IDLE}" == "TRANSFERRING" ]]; then
    printf 'DEFERRED %s cycle=%s activity=%s\n' "${unit}" "${cycle_state:-unknown}" "${activity:-unknown}"
    deferred=$((deferred + 1))
    continue
  fi
  if ! systemctl restart "${unit}" || ! systemctl is-active --quiet "${unit}"; then
    printf 'FAILED %s restart\n' "${unit}" >&2
    failed=$((failed + 1))
    continue
  fi
  for _ in $(seq 1 20); do
    observed_sha="$(state_value "${status_path}" scheduler_code_sha256)"
    [[ "${observed_sha}" == "${code_sha}" ]] && break
    sleep 1
  done
  if [[ "${observed_sha:-}" != "${code_sha}" ]]; then
    printf 'FAILED %s code-sha expected=%s observed=%s\n' "${unit}" "${code_sha}" "${observed_sha:-missing}" >&2
    failed=$((failed + 1))
    continue
  fi
  printf 'RESTARTED %s code-sha=%s started=%s\n' "${unit}" "${observed_sha}" \
    "$(state_value "${status_path}" scheduler_started_at)"
  restarted=$((restarted + 1))
done < <(systemctl list-units --type=service --state=active 'ablestack-vm-ftctl-dr@*.service' --no-legend --plain | awk '{print $1}')

printf 'SUMMARY restarted=%s deferred=%s failed=%s\n' "${restarted}" "${deferred}" "${failed}"
[[ "${failed}" -eq 0 ]]
