#!/usr/bin/env bash
# ---------------------------------------------------------------------
# Copyright 2026 ABLECLOUD
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
# ---------------------------------------------------------------------

hangctl_ftctl__vm_key() {
  local vm="${1-}"
  echo "${vm//[^a-zA-Z0-9_.-]/_}"
}

hangctl_ftctl__read_kv() {
  local path="${1-}"
  local key="${2-}"
  [[ -f "${path}" ]] || return 1
  awk -F= -v k="${key}" '$1==k {sub(/^[^=]+=/,""); print; found=1; exit} END{if (!found) exit 1}' "${path}"
}

hangctl_ftctl_guard_should_skip_action() {
  # usage:
  #   hangctl_ftctl_guard_should_skip_action <vm> <confirm_reason> <out_reason> <out_detail>
  local vm="${1-}"
  local confirm_reason="${2-}"
  local -n _out_reason="${3}"
  local -n _out_detail="${4}"

  _out_reason=""
  _out_detail=""

  [[ "${HANGCTL_FTCTL_GUARD_ENABLE-1}" == "1" ]] || return 1
  [[ -n "${vm}" ]] || return 1

  local ftctl_run_dir ftctl_state_dir ftctl_profile_dir key
  ftctl_run_dir="${HANGCTL_FTCTL_RUN_DIR:-/run/ablestack-vm-ftctl}"
  ftctl_state_dir="${HANGCTL_FTCTL_STATE_DIR:-${ftctl_run_dir}/state}"
  ftctl_profile_dir="${HANGCTL_FTCTL_PROFILE_DIR:-/etc/ablestack/ftctl.d}"
  key="$(hangctl_ftctl__vm_key "${vm}")"

  local profile_path state_path lock_path
  profile_path="${ftctl_profile_dir}/${vm}.conf"
  state_path="${ftctl_state_dir}/${key}.state"
  lock_path="${ftctl_run_dir}/locks/${key}.lock"

  local has_profile=0 has_state=0 has_lock=0 has_copy=0
  [[ -f "${profile_path}" ]] && has_profile=1
  [[ -f "${state_path}" ]] && has_state=1
  [[ -e "${lock_path}" ]] && has_lock=1
  if [[ -f "${state_path}.blockcopy" || -f "${state_path}.blockcopy.reverse" || -f "${state_path}.blockcopy.progress" ]]; then
    has_copy=1
  fi

  if [[ "${has_profile}" != "1" && "${has_state}" != "1" && "${has_lock}" != "1" && "${has_copy}" != "1" ]]; then
    return 1
  fi

  local protection_state transport_state active_side admin_state mode
  protection_state="$(hangctl_ftctl__read_kv "${state_path}" "protection_state" 2>/dev/null || true)"
  transport_state="$(hangctl_ftctl__read_kv "${state_path}" "transport_state" 2>/dev/null || true)"
  active_side="$(hangctl_ftctl__read_kv "${state_path}" "active_side" 2>/dev/null || true)"
  admin_state="$(hangctl_ftctl__read_kv "${state_path}" "admin_state" 2>/dev/null || true)"
  mode="$(hangctl_ftctl__read_kv "${state_path}" "mode" 2>/dev/null || true)"

  _out_reason="ftctl_runtime_active"
  _out_detail="confirm_reason=${confirm_reason} mode=${mode:-unknown} protection=${protection_state:-unknown} transport=${transport_state:-unknown} active_side=${active_side:-unknown} admin=${admin_state:-unknown} profile=${has_profile} state=${has_state} lock=${has_lock} blockcopy=${has_copy}"
  return 0
}
