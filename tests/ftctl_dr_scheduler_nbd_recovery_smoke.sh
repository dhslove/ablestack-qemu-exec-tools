#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

# shellcheck source=../lib/ftctl/dr_scheduler.sh
source "${ROOT}/lib/ftctl/dr_scheduler.sh"

state_path="${TMP}/state"
status_path="${TMP}/status"
printf 'nbd_teardown_state=QUARANTINED\n' > "${state_path}"
cp "${state_path}" "${status_path}"

ftctl_now_iso8601() { printf '2026-08-24T00:00:00Z\n'; }
ftctl_dr_runtime_state_get_from_path() {
  awk -F= -v key="${2-}" '$1 == key { value=substr($0, index($0, "=") + 1) } END { print value }' "${1-}"
}
ftctl_dr_scheduler_update_state() {
  local state="${1-}" status="${2-}" target key value pair
  shift 2
  for target in "${state}" "${status}"; do
    for pair in "$@"; do
      key="${pair%%=*}"
      value="${pair#*=}"
      if grep -q "^${key}=" "${target}"; then
        sed -i "s|^${key}=.*|${key}=${value}|" "${target}"
      else
        printf '%s=%s\n' "${key}" "${value}" >> "${target}"
      fi
    done
  done
}

recovery_tool="${TMP}/recover-nbd"
cat > "${recovery_tool}" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "${FTCTL_DR_RECOVERY_TEST_LOG}"
EOF
chmod +x "${recovery_tool}"

export FTCTL_DR_RECOVERY_TEST_LOG="${TMP}/recovery.log"
export FTCTL_DR_NBD_RECOVERY_TOOL="${recovery_tool}"
ftctl_dr_scheduler_recover_nbd_quarantine plan-1 "${state_path}" "${status_path}"
grep -qx -- '--recover-nbd plan-1' "${TMP}/recovery.log"
grep -q '^nbd_teardown_state=DRAINED$' "${status_path}"
grep -q '^scheduler_recovery_stage=NBD_RECOVERY_COMPLETED$' "${status_path}"
grep -q '^scheduler_recovery_rc=0$' "${status_path}"

printf 'nbd_teardown_state=QUARANTINED\n' > "${state_path}"
cp "${state_path}" "${status_path}"
unset FTCTL_DR_NBD_RECOVERY_TOOL
FTCTL_LIB_BASE="${TMP}/missing"
if ftctl_dr_scheduler_recover_nbd_quarantine plan-1 "${state_path}" "${status_path}"; then
  echo 'missing recovery tool unexpectedly succeeded' >&2
  exit 1
else
  rc=$?
fi
[[ "${rc}" == "65" ]]
grep -q '^scheduler_recovery_stage=NBD_RECOVERY_TOOL_RESOLUTION$' "${status_path}"
grep -q '^error_code=DR_NBD_RECOVERY_TOOL_UNAVAILABLE$' "${status_path}"

echo 'ftctl DR scheduler NBD recovery smoke: PASS'
