#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "${TMP}"' EXIT

export FTCTL_RUN_DIR="${TMP}/run"
export FTCTL_STATE_DIR="${TMP}/run/state"
export FTCTL_LOG_DIR="${TMP}/log"
export FTCTL_PROFILE_DIR="${TMP}/profiles"

# shellcheck source=../lib/ftctl/common.sh
source "${ROOT}/lib/ftctl/common.sh"
# shellcheck source=../lib/ftctl/state.sh
source "${ROOT}/lib/ftctl/state.sh"
# shellcheck source=../lib/ftctl/logging.sh
source "${ROOT}/lib/ftctl/logging.sh"
# shellcheck source=../lib/ftctl/dr_runtime.sh
source "${ROOT}/lib/ftctl/dr_runtime.sh"

PLAN="authority-contract-plan"
CAPABILITIES="$(ftctl_dr_runtime_capabilities 1)"

write_spec() {
  local path=$1 version=$2 run=$3
  cat > "${path}" <<JSON
{
  "contractVersion": "${version}",
  "planUuid": "${PLAN}",
  "runUuid": "${run}",
  "expectedActiveSide": "TARGET",
  "authorityGeneration": 7,
  "cutoverSessionId": "cutover-session-7",
  "checkpointSequence": 5,
  "targetVmId": 256
}
JSON
}

mapfile -t SUPPORTED_VERSIONS < <(
  jq -r '.reprotect_authority_contract_versions[]' <<<"${CAPABILITIES}"
)
[[ "${#SUPPORTED_VERSIONS[@]}" -eq 2 ]]
[[ " ${SUPPORTED_VERSIONS[*]} " == *" 2026-07-23 "* ]]
[[ " ${SUPPORTED_VERSIONS[*]} " == *" 2026-08-26 "* ]]

for version in "${SUPPORTED_VERSIONS[@]}"; do
  run="run-${version}"
  spec="${TMP}/${run}.json"
  write_spec "${spec}" "${version}" "${run}"
  ftctl_dr_runtime_save_authority_spec "${PLAN}" "${run}" "${spec}"
  saved="$(ftctl_dr_runtime_authority_spec_path "${PLAN}" "${run}")"
  jq -e --arg version "${version}" '.contractVersion == $version' "${saved}" >/dev/null
done

INVALID_RUN="run-invalid"
INVALID_SPEC="${TMP}/${INVALID_RUN}.json"
write_spec "${INVALID_SPEC}" "2026-09-01" "${INVALID_RUN}"
if ftctl_dr_runtime_save_authority_spec "${PLAN}" "${INVALID_RUN}" "${INVALID_SPEC}"; then
  echo "ERROR: unsupported reprotect authority contract was accepted" >&2
  exit 1
fi

echo "ftctl DR reprotect authority contract smoke: PASS"
