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

ftctl_dr_vddk_json_value() {
  local path="${1-}" expr="${2-}" default_value="${3-}"
  [[ -n "${path}" && -f "${path}" ]] || {
    printf '%s\n' "${default_value}"
    return 0
  }
  command -v jq >/dev/null 2>&1 || {
    printf '%s\n' "${default_value}"
    return 0
  }
  jq -er "${expr} // empty" "${path}" 2>/dev/null || printf '%s\n' "${default_value}"
}

ftctl_dr_vddk_profile_env_libdir() {
  local profile="/etc/profile.d/v2k-vddk.sh"
  [[ -f "${profile}" ]] || return 0
  bash -c 'source /etc/profile.d/v2k-vddk.sh >/dev/null 2>&1 || true; printf "%s\n" "${VDDK_LIBDIR:-}"' 2>/dev/null || true
}

ftctl_dr_vddk_candidate_dirs() {
  local credentials_file="${1-}"
  ftctl_dr_vddk_json_value "${credentials_file}" '.credentials.source.vddkLibdir // .credentials.source.libdir' ''
  [[ -n "${FTCTL_DR_VMWARE_VDDK_LIBDIR:-}" ]] && printf '%s\n' "${FTCTL_DR_VMWARE_VDDK_LIBDIR}"
  [[ -n "${VDDK_LIBDIR:-}" ]] && printf '%s\n' "${VDDK_LIBDIR}"
  ftctl_dr_vddk_profile_env_libdir
  printf '%s\n' \
    "/opt/vmware-vix-disklib-distrib" \
    "/usr/share/ablestack/v2k/compat/vsphere80/vddk" \
    "/usr/share/ablestack/v2k/compat/vsphere67/vddk" \
    "/usr/share/ablestack/v2k/compat/vsphere60/vddk"
  find /usr/share/ablestack/v2k/compat -maxdepth 3 -type d -name vddk 2>/dev/null || true
}

ftctl_dr_vddk_has_library() {
  local libdir="${1-}"
  [[ -n "${libdir}" && -d "${libdir}/lib64" ]] || return 1
  compgen -G "${libdir}/lib64/libvixDiskLib.so*" >/dev/null
}

ftctl_dr_vddk_nbdkit_loads() {
  local libdir="${1-}"
  ftctl_dr_vddk_has_library "${libdir}" || return 1
  command -v nbdkit >/dev/null 2>&1 || return 1
  nbdkit --dump-plugin vddk "libdir=${libdir}" >/dev/null 2>&1
}

ftctl_dr_vddk_resolve_libdir() {
  local credentials_file="${1-}"
  local candidate seen=""
  while IFS= read -r candidate; do
    candidate="${candidate%/}"
    [[ -n "${candidate}" ]] || continue
    [[ "${seen}" == *$'\n'"${candidate}"$'\n'* ]] && continue
    seen="${seen}"$'\n'"${candidate}"$'\n'
    ftctl_dr_vddk_nbdkit_loads "${candidate}" || continue
    printf '%s\n' "${candidate}"
    return 0
  done < <(ftctl_dr_vddk_candidate_dirs "${credentials_file}")
  return 1
}

ftctl_dr_vddk_library_version() {
  local libdir="${1-}"
  [[ -n "${libdir}" ]] || return 1
  nbdkit --dump-plugin vddk "libdir=${libdir}" 2>/dev/null \
    | awk -F= '/^vddk_library_version=/{print $2; exit}'
}
