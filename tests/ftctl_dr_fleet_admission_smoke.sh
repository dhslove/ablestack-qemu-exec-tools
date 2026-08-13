#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

FTCTL_RUN_DIR="${TMP}/run"
FTCTL_DR_FULL_SEED_MAX_CONCURRENT=1
FTCTL_DR_INCREMENTAL_MAX_CONCURRENT=2
FTCTL_DR_INITIAL_JITTER_MAX_SEC=30

ftctl_ensure_dir() { mkdir -p "$1"; }
ftctl_now_iso8601() { printf '2026-08-13T00:00:00Z\n'; }
ftctl_dr_scheduler_profile_int() { printf '%s\n' "$3"; }

# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

[[ "$(ftctl_dr_scheduler_slot_class full-reseed)" == "full-seed" ]]
[[ "$(ftctl_dr_scheduler_slot_class incremental)" == "incremental" ]]
[[ "$(ftctl_dr_scheduler_initial_jitter plan-a /dev/null 300)" =~ ^[0-9]+$ ]]

ftctl_dr_scheduler_slot_acquire plan-a /dev/null full-seed 210
set +e
(exec 210>&-; ftctl_dr_scheduler_slot_acquire plan-b /dev/null full-seed 211)
busy_rc=$?
set -e
if [[ "${busy_rc}" == "0" ]]; then
  echo "second full-seed slot unexpectedly admitted" >&2
  exit 1
fi
[[ "${busy_rc}" == "97" ]]
ftctl_dr_scheduler_slot_release 210
ftctl_dr_scheduler_slot_acquire plan-b /dev/null full-seed 211
ftctl_dr_scheduler_slot_release 211

run_fleet_case() {
  local count="$1" slot_class="$2" cycle_type="$3" limit="$4"
  local state_dir="${TMP}/fleet-${count}-${slot_class}" pid
  mkdir -p "${state_dir}"
  printf '0\n' > "${state_dir}/active"
  printf '0\n' > "${state_dir}/maximum"
  printf '0\n' > "${state_dir}/completed"
  printf '0\n' > "${state_dir}/retries"

  for ((pid=1; pid<=count; pid++)); do
    (
      local retries=0 active maximum
      while ! ftctl_dr_scheduler_slot_acquire "fleet-${count}-${pid}" /dev/null "${cycle_type}" 220; do
        retries=$((retries + 1))
        sleep 0.01
      done
      exec 221>"${state_dir}/counter.lock"
      flock -x 221
      active=$(( $(<"${state_dir}/active") + 1 ))
      maximum="$(<"${state_dir}/maximum")"
      printf '%s\n' "${active}" > "${state_dir}/active"
      (( active > maximum )) && printf '%s\n' "${active}" > "${state_dir}/maximum"
      flock -u 221
      sleep 0.02
      flock -x 221
      printf '%s\n' "$(( $(<"${state_dir}/active") - 1 ))" > "${state_dir}/active"
      printf '%s\n' "$(( $(<"${state_dir}/completed") + 1 ))" > "${state_dir}/completed"
      printf '%s\n' "$(( $(<"${state_dir}/retries") + retries ))" > "${state_dir}/retries"
      flock -u 221
      ftctl_dr_scheduler_slot_release 220
    ) &
  done
  wait

  [[ "$(<"${state_dir}/completed")" == "${count}" ]]
  (( $(<"${state_dir}/maximum") <= limit ))
  (( $(<"${state_dir}/maximum") > 0 ))
  (( count <= limit || $(<"${state_dir}/retries") > 0 ))
  printf '[OK] %s requests queued through %s slots (max=%s retries=%s)\n' \
    "${count}" "${slot_class}" "$(<"${state_dir}/maximum")" "$(<"${state_dir}/retries")"
}

for fleet_size in 10 30 100; do
  run_fleet_case "${fleet_size}" full-seed full-reseed "${FTCTL_DR_FULL_SEED_MAX_CONCURRENT}"
  run_fleet_case "${fleet_size}" incremental incremental "${FTCTL_DR_INCREMENTAL_MAX_CONCURRENT}"
done

echo "[OK] FTCTL DR fleet admission smoke"
