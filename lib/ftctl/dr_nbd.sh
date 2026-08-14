#!/usr/bin/env bash
# Shared NBD capacity contract for VMware-to-KVM DR data paths.

ftctl_dr_nbd_device_is_quarantined() {
  local device="${1-}" root="${FTCTL_DR_NBD_QUARANTINE_ROOT:-/run/ablestack-vm-ftctl/dr-runtime/nbd-quarantine}"
  local name record
  name="${device#/dev/}"
  [[ -d "${root}" ]] || return 1
  while IFS= read -r record; do
    [[ -n "${record}" ]] && return 0
  done < <(find "${root}" -mindepth 2 -maxdepth 2 -type f -name "${name}.json" -print 2>/dev/null | head -n 1)
  return 1
}

ftctl_dr_nbd_device_is_free() {
  local device="${1-}" sysfs_root="${FTCTL_DR_NBD_SYSFS_ROOT:-/sys/class/block}"
  local name pid="" sectors=0 holders=0 partitions=0 mounted=0
  name="${device#/dev/}"
  [[ -b "${device}" && -d "${sysfs_root}/${name}" ]] || return 1
  pid="$(cat "${sysfs_root}/${name}/pid" 2>/dev/null || true)"
  sectors="$(cat "${sysfs_root}/${name}/size" 2>/dev/null || printf '0')"
  holders="$(find "${sysfs_root}/${name}/holders" -mindepth 1 -maxdepth 1 -print 2>/dev/null | wc -l | tr -d ' ')"
  partitions="$(find "${sysfs_root}" -mindepth 1 -maxdepth 1 -name "${name}p*" -print 2>/dev/null | wc -l | tr -d ' ')"
  if command -v lsblk >/dev/null 2>&1; then
    mounted="$(lsblk -nrpo MOUNTPOINT "${device}" 2>/dev/null | awk 'NF {count++} END {print count + 0}')"
  fi
  [[ -z "${pid}" && "${sectors:-0}" == "0" && "${holders:-0}" == "0" &&
    "${partitions:-0}" == "0" && "${mounted:-0}" == "0" ]]
}

ftctl_dr_nbd_capacity_json() {
  local start="${FTCTL_DR_NBD_DEVICE_START:-16}" end="${FTCTL_DR_NBD_DEVICE_END:-31}"
  local module_max=0 expected=0 present=0 free=0 quarantined=0 idx dev configured=false ready=false error_code=""
  [[ "${start}" =~ ^[0-9]+$ ]] || start=16
  [[ "${end}" =~ ^[0-9]+$ ]] || end=31
  (( start <= end )) || { start=16; end=31; }
  expected=$((end - start + 1))
  modprobe nbd "nbds_max=${FTCTL_DR_NBD_MODULE_MAX_DEVICES:-32}" \
    "max_part=${FTCTL_DR_NBD_MODULE_MAX_PARTITIONS:-16}" >/dev/null 2>&1 || true
  module_max="$(cat /sys/module/nbd/parameters/nbds_max 2>/dev/null || printf '0')"
  [[ "${module_max}" =~ ^[0-9]+$ ]] || module_max=0
  for ((idx = start; idx <= end; idx++)); do
    dev="/dev/nbd${idx}"
    [[ -b "${dev}" ]] || continue
    present=$((present + 1))
    if ftctl_dr_nbd_device_is_quarantined "${dev}"; then
      quarantined=$((quarantined + 1))
    elif ftctl_dr_nbd_device_is_free "${dev}"; then
      free=$((free + 1))
    fi
  done
  if (( module_max >= end + 1 && present == expected )); then
    configured=true
    if (( free > 0 )); then
      ready=true
    else
      error_code="DR_RESOURCE_BUSY"
    fi
  else
    error_code="DR_NBD_CAPACITY_INVALID"
  fi
  printf '{"schemaVersion":1,"reservedRangeOnly":true,"deviceStart":%s,"deviceEnd":%s,"moduleMaxDevices":%s,"expectedDeviceCount":%s,"presentDeviceCount":%s,"freeDeviceCount":%s,"quarantinedDeviceCount":%s,"configured":%s,"ready":%s,"errorCode":"%s"}\n' \
    "${start}" "${end}" "${module_max}" "${expected}" "${present}" "${free}" "${quarantined}" \
    "${configured}" "${ready}" "${error_code}"
}
