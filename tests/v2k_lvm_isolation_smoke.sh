#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[ERR] Missing command: $1" >&2
    exit 2
  }
}

require_cmd bash
require_cmd grep

bash -n lib/v2k/engine.sh

# shellcheck source=/dev/null
source lib/v2k/engine.sh

cfg="$(v2k_linux_bootstrap_lvm_cfg_for_nbd /dev/nbd8)"
grep -F 'use_devicesfile=0' <<<"${cfg}" >/dev/null
grep -F 'a|^/dev/nbd8$|' <<<"${cfg}" >/dev/null
grep -F 'a|^/dev/nbd8p[0-9]+$|' <<<"${cfg}" >/dev/null
grep -F 'r|.*|' <<<"${cfg}" >/dev/null

range_cfg="$(v2k_linux_bootstrap_lvm_range_cfg 'nbd8|nbd9')"
grep -F 'use_devicesfile=0' <<<"${range_cfg}" >/dev/null
grep -F 'a|^/dev/(nbd8|nbd9)(p[0-9]+)?$|' <<<"${range_cfg}" >/dev/null

lvm_dir=""
v2k_linux_bootstrap_setup_lvm_system_dir /dev/nbd8 lvm_dir
trap '[[ -n "${lvm_dir:-}" ]] && rm -rf "${lvm_dir}"' EXIT

test -d "${lvm_dir}/devices"
test -f "${lvm_dir}/lvm.conf"
grep -F 'use_devicesfile = 0' "${lvm_dir}/lvm.conf" >/dev/null
grep -F 'a|^/dev/nbd8$|' "${lvm_dir}/lvm.conf" >/dev/null
grep -F 'a|^/dev/nbd8p[0-9]+$|' "${lvm_dir}/lvm.conf" >/dev/null

grep -F 'v2k_linux_bootstrap_dev_under_nbd "${lv}" "${nbd_dev}"' lib/v2k/engine.sh >/dev/null
grep -F 'mounted_source_not_on_nbd' lib/v2k/engine.sh >/dev/null
grep -F 'root_dev_not_on_nbd' lib/v2k/engine.sh >/dev/null
grep -F -- "--separator '|'" lib/v2k/engine.sh >/dev/null
grep -F 'vg_name,lv_name,lv_path,devices' lib/v2k/engine.sh >/dev/null

echo "[OK] v2k LVM initramfs isolation smoke"

