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

FTCTL_DR_KEY_ROOT="${FTCTL_DR_KEY_ROOT:-/root/.ssh/ftctl-dr}"

ftctl_dr_key_profile() {
  local profile="${1-}"
  [[ -n "${profile}" ]] || profile="${CLI_VM:-}"
  [[ -n "${profile}" ]] || profile="default"
  printf '%s' "${profile//[^A-Za-z0-9_.-]/_}"
}

ftctl_dr_key_comment() {
  local profile="${1-}"
  printf 'ftctl-dr:%s' "$(ftctl_dr_key_profile "${profile}")"
}

ftctl_dr_key_private_key_path() {
  local profile="${1-}"
  local normalized key_path

  if [[ -n "${FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE:-}" ]]; then
    [[ -s "${FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE}" ]] || return 1
    printf '%s' "${FTCTL_PROFILE_SECONDARY_SSH_KEY_FILE}"
    return 0
  fi

  normalized="$(ftctl_dr_key_profile "${profile}")"
  key_path="${FTCTL_DR_KEY_ROOT}/${normalized}/id_ed25519"
  [[ -s "${key_path}" ]] || return 1
  printf '%s' "${key_path}"
}

ftctl_dr_key_uri_with_keyfile() {
  local uri="${1-}"
  local profile="${2-}"
  local key_path separator

  [[ "${uri}" == qemu+ssh://* ]] || {
    printf '%s' "${uri}"
    return 0
  }
  [[ "${uri}" == *\?keyfile=* || "${uri}" == *\&keyfile=* ]] && {
    printf '%s' "${uri}"
    return 0
  }

  key_path="$(ftctl_dr_key_private_key_path "${profile}" 2>/dev/null || true)"
  [[ -n "${key_path}" ]] || {
    printf '%s' "${uri}"
    return 0
  }

  separator="?"
  [[ "${uri}" == *\?* ]] && separator="&"
  printf '%s%skeyfile=%s' "${uri}" "${separator}" "${key_path}"
}

ftctl_dr_key_emit() {
  local command="${1-}"
  local result="${2-}"
  local profile="${3-}"
  local public_key="${4-}"
  local key_comment="${5-}"
  local rc="${6-0}"
  local private_key_path=""

  if [[ -n "${profile}" ]]; then
    private_key_path="${FTCTL_DR_KEY_ROOT}/$(ftctl_dr_key_profile "${profile}")/id_ed25519"
  fi

  if [[ "${CLI_JSON:-0}" == "1" ]]; then
    printf '{"command":"%s","result":"%s","profile":"%s","public_key":"%s","key_comment":"%s","private_key_path":"%s","exit_code":%s}\n' \
      "$(ftctl__json_escape "${command}")" \
      "$(ftctl__json_escape "${result}")" \
      "$(ftctl__json_escape "${profile}")" \
      "$(ftctl__json_escape "${public_key}")" \
      "$(ftctl__json_escape "${key_comment}")" \
      "$(ftctl__json_escape "${private_key_path}")" \
      "${rc}"
  else
    printf '%s result=%s profile=%s key_comment=%s exit_code=%s\n' \
      "${command}" "${result}" "${profile}" "${key_comment}" "${rc}"
  fi
}

ftctl_dr_key_ensure() {
  local profile="${1-}"
  local normalized key_dir key_path pub_path comment public_key

  normalized="$(ftctl_dr_key_profile "${profile}")"
  key_dir="${FTCTL_DR_KEY_ROOT}/${normalized}"
  key_path="${key_dir}/id_ed25519"
  pub_path="${key_path}.pub"
  comment="$(ftctl_dr_key_comment "${normalized}")"

  umask 077
  mkdir -p "${key_dir}"
  chmod 0700 "${FTCTL_DR_KEY_ROOT}" "${key_dir}" 2>/dev/null || true
  if [[ ! -s "${key_path}" || ! -s "${pub_path}" ]]; then
    rm -f "${key_path}" "${pub_path}" 2>/dev/null || true
    ssh-keygen -q -t ed25519 -N "" -C "${comment}" -f "${key_path}"
  fi
  chmod 0600 "${key_path}" 2>/dev/null || true
  chmod 0644 "${pub_path}" 2>/dev/null || true
  public_key="$(awk '{print $1" "$2}' "${pub_path}") ${comment}"
  ftctl_dr_key_emit "dr-key-ensure" "ok" "${normalized}" "${public_key}" "${comment}" 0
}

ftctl_dr_key_install() {
  local profile="${1-}"
  local public_key="${2-}"
  local key_comment="${3-}"
  local ssh_user="${4-root}"
  local normalized home_dir ssh_dir auth_file key_body tmp_file

  normalized="$(ftctl_dr_key_profile "${profile}")"
  [[ -n "${key_comment}" ]] || key_comment="$(ftctl_dr_key_comment "${normalized}")"
  [[ -n "${ssh_user}" ]] || ssh_user="root"
  if [[ -z "${public_key}" || ! "${public_key}" =~ ^ssh-(rsa|ed25519|ecdsa)[[:space:]] ]]; then
    echo "ERROR: valid SSH public key is required" >&2
    return 2
  fi
  key_body="$(awk '{print $1" "$2}' <<< "${public_key}") ${key_comment}"
  home_dir="$(getent passwd "${ssh_user}" | cut -d: -f6)"
  [[ -n "${home_dir}" ]] || {
    echo "ERROR: unable to resolve home directory for ${ssh_user}" >&2
    return 2
  }
  ssh_dir="${home_dir}/.ssh"
  auth_file="${ssh_dir}/authorized_keys"
  tmp_file="${auth_file}.ftctl.$$"

  umask 077
  mkdir -p "${ssh_dir}"
  touch "${auth_file}"
  chmod 0700 "${ssh_dir}" 2>/dev/null || true
  chmod 0600 "${auth_file}" 2>/dev/null || true
  grep -Fv " ${key_comment}" "${auth_file}" > "${tmp_file}" || true
  printf '%s\n' "${key_body}" >> "${tmp_file}"
  cat "${tmp_file}" > "${auth_file}"
  rm -f "${tmp_file}" 2>/dev/null || true
  chown -R "${ssh_user}:${ssh_user}" "${ssh_dir}" 2>/dev/null || true
  ftctl_dr_key_emit "dr-key-install" "ok" "${normalized}" "" "${key_comment}" 0
}

ftctl_dr_key_remove() {
  local profile="${1-}"
  local key_comment="${2-}"
  local ssh_user="${3-root}"
  local normalized home_dir auth_file tmp_file

  normalized="$(ftctl_dr_key_profile "${profile}")"
  [[ -n "${key_comment}" ]] || key_comment="$(ftctl_dr_key_comment "${normalized}")"
  [[ -n "${ssh_user}" ]] || ssh_user="root"
  home_dir="$(getent passwd "${ssh_user}" | cut -d: -f6)"
  [[ -n "${home_dir}" ]] || return 0
  auth_file="${home_dir}/.ssh/authorized_keys"
  [[ -f "${auth_file}" ]] || return 0
  tmp_file="${auth_file}.ftctl.$$"
  grep -Fv " ${key_comment}" "${auth_file}" > "${tmp_file}" || true
  cat "${tmp_file}" > "${auth_file}"
  rm -f "${tmp_file}" 2>/dev/null || true
  chmod 0600 "${auth_file}" 2>/dev/null || true
  ftctl_dr_key_emit "dr-key-remove" "ok" "${normalized}" "" "${key_comment}" 0
}
