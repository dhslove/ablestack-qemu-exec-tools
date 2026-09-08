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

FTCTL_SCAN_ID=""

ftctl_new_scan_id() {
  printf "%s-%s\n" "$(date +"%Y%m%d-%H%M%S")" "$(ftctl_rand_id)"
}

ftctl_set_scan_id() {
  FTCTL_SCAN_ID="${1-}"
}

ftctl_get_scan_id() {
  echo "${FTCTL_SCAN_ID}"
}

ftctl__json_escape() {
  local s="${1-}"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  echo -n "${s}"
}

ftctl__details_kv_to_json() {
  local kvs="${1-}"
  [[ -n "${kvs}" ]] || return 0
  local out="{"
  local first="1"
  local token key val
  for token in ${kvs}; do
    key="${token%%=*}"
    val="${token#*=}"
    [[ -n "${key}" ]] || continue
    if [[ "${first}" == "1" ]]; then
      first="0"
    else
      out+=","
    fi
    out+="\"$(ftctl__json_escape "${key}")\":\"$(ftctl__json_escape "${val}")\""
  done
  out+="}"
  echo -n "${out}"
}

ftctl_log_event() {
  local stage="${1-}"
  local event="${2-}"
  local result="${3-}"
  local vm="${4-}"
  local rc="${5-}"
  local details_kv="${6-}"
  local ts scan_id json details_json parent event_seq token detail_key detail_value plan_uuid plan_key plan_log

  ts="$(ftctl_now_iso8601)"
  scan_id="$(ftctl_get_scan_id)"
  if [[ -z "${scan_id}" ]]; then
    scan_id="$(ftctl_new_scan_id)"
    ftctl_set_scan_id "${scan_id}"
  fi

  parent="$(dirname "${FTCTL_EVENTS_LOG}")"
  [[ -d "${parent}" ]] || mkdir -p "${parent}" 2>/dev/null || true
  if [[ -f "${FTCTL_EVENTS_LOG}" ]]; then
    event_seq="$(( $(wc -l < "${FTCTL_EVENTS_LOG}" 2>/dev/null || echo 0) + 1 ))"
  else
    event_seq="1"
  fi

  json="{"
  json+="\"ts\":\"$(ftctl__json_escape "${ts}")\""
  json+=",\"scan_id\":\"$(ftctl__json_escape "${scan_id}")\""
  json+=",\"event_seq\":${event_seq}"
  if [[ -n "${vm}" ]]; then
    json+=",\"vm\":\"$(ftctl__json_escape "${vm}")\""
  fi
  json+=",\"stage\":\"$(ftctl__json_escape "${stage}")\""
  json+=",\"event\":\"$(ftctl__json_escape "${event}")\""
  json+=",\"result\":\"$(ftctl__json_escape "${result}")\""
  if [[ -n "${rc}" ]]; then
    json+=",\"rc\":${rc}"
  fi
  details_json="$(ftctl__details_kv_to_json "${details_kv}")"
  if [[ -n "${details_json}" ]]; then
    json+=",\"details\":${details_json}"
  fi
  json+="}"

  printf "%s\n" "${json}" >> "${FTCTL_EVENTS_LOG}"

  # DR status consumes a plan-owned stream. Keep the global log for existing
  # operators, but never make a DR plan read unrelated VM/plan events.
  if [[ "${stage}" == "dr-runtime" && -n "${FTCTL_RUN_DIR:-}" ]]; then
    plan_uuid=""
    for token in ${details_kv}; do
      detail_key="${token%%=*}"
      detail_value="${token#*=}"
      if [[ "${detail_key}" == "plan" ]]; then
        plan_uuid="${detail_value}"
        break
      fi
    done
    if [[ -n "${plan_uuid}" ]]; then
      plan_key="$(printf '%s' "${plan_uuid}" | tr -c 'A-Za-z0-9._-' '_')"
      plan_log="${FTCTL_RUN_DIR}/dr-runtime/plans/${plan_key}/events.jsonl"
      mkdir -p "$(dirname "${plan_log}")" 2>/dev/null || true
      printf "%s\n" "${json}" >> "${plan_log}"
      chmod 0644 "${plan_log}" 2>/dev/null || true
    fi
  fi
}
