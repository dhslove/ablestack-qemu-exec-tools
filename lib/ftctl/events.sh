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

ftctl_events_limit_valid() {
  local limit="${1-}"
  [[ -z "${limit}" || "${limit}" =~ ^[0-9]+$ ]]
}

ftctl_events_collect_lines() {
  local vm="${1-}"
  local limit="${2-}"
  local pattern file
  file="${FTCTL_EVENTS_LOG}"

  [[ -f "${file}" ]] || return 0

  if [[ -n "${vm}" ]]; then
    pattern="\"vm\":\"${vm}\""
    if [[ -n "${limit}" && "${limit}" != "0" ]]; then
      grep -F "${pattern}" "${file}" | tail -n "${limit}" || true
    else
      grep -F "${pattern}" "${file}" || true
    fi
    return 0
  fi

  if [[ -n "${limit}" && "${limit}" != "0" ]]; then
    tail -n "${limit}" "${file}" || true
  else
    cat "${file}" || true
  fi
}

ftctl_events_print() {
  local vm="${1-}"
  local limit="${2-}"
  local json="${3-0}"
  local -a lines=()
  local line first="1"

  ftctl_events_limit_valid "${limit}" || {
    echo "ERROR: --limit must be an unsigned integer" >&2
    return 2
  }

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    lines+=("${line}")
  done < <(ftctl_events_collect_lines "${vm}" "${limit}")

  if [[ "${json}" == "1" ]]; then
    printf '{"command":"events","result":"ok"'
    if [[ -n "${vm}" ]]; then
      printf ',"vm":"%s"' "$(ftctl__json_escape "${vm}")"
    fi
    printf ',"items":['
    for line in "${lines[@]}"; do
      if [[ "${first}" == "1" ]]; then
        first="0"
      else
        printf ','
      fi
      printf '%s' "${line}"
    done
    printf '],"count":%s}\n' "${#lines[@]}"
    return 0
  fi

  if ((${#lines[@]} == 0)); then
    if [[ -n "${vm}" ]]; then
      printf '%s: no events found\n' "${vm}"
    else
      printf 'no events found\n'
    fi
    return 0
  fi

  for line in "${lines[@]}"; do
    printf '%s\n' "${line}"
  done
}
