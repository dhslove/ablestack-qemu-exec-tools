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
require_cmd jq
require_cmd python3

bash -n lib/v2k/engine.sh

# shellcheck source=/dev/null
source lib/v2k/engine.sh

tmpdir="$(mktemp -d /tmp/v2k-bootstrap-smoke.XXXXXX)"
trap 'rm -rf "${tmpdir}"' EXIT

root="${tmpdir}/root"
k_old="5.14.0-427.el9.x86_64"
k_new="5.14.0-427.13.1.el9_4.x86_64"
moddir="${root}/lib/modules/${k_new}"

mkdir -p "${root}/boot/loader/entries" "${root}/lib/modules/${k_old}" \
  "${moddir}/kernel/drivers/block" \
  "${moddir}/kernel/drivers/scsi" \
  "${moddir}/kernel/drivers/ata" \
  "${moddir}/kernel/drivers/virtio" \
  "${tmpdir}/disks"

: > "${root}/boot/vmlinuz-${k_old}"
: > "${root}/boot/vmlinuz-${k_new}"
cat > "${root}/boot/loader/entries/ablestack-test.conf" <<EOF
title Rocky Linux (${k_new})
linux /vmlinuz-${k_new}
initrd /initramfs-${k_new}.img
EOF

cat > "${root}/boot/config-${k_new}" <<'EOF'
CONFIG_VIRTIO=y
CONFIG_VIRTIO_PCI=y
CONFIG_VIRTIO_BLK=m
CONFIG_SCSI_VIRTIO=m
EOF

touch \
  "${moddir}/kernel/drivers/block/virtio_blk.ko.xz" \
  "${moddir}/kernel/drivers/scsi/virtio_scsi.ko.xz" \
  "${moddir}/kernel/drivers/scsi/scsi_mod.ko.xz" \
  "${moddir}/kernel/drivers/scsi/sd_mod.ko.xz" \
  "${moddir}/kernel/drivers/ata/ahci.ko.xz" \
  "${moddir}/kernel/drivers/ata/libata.ko.xz"

cat > "${moddir}/modules.builtin" <<'EOF'
kernel/drivers/virtio/virtio_pci.ko
kernel/drivers/virtio/virtio_pci_modern_dev.ko
EOF
: > "${moddir}/modules.builtin.modinfo"
: > "${moddir}/modules.alias"

kernel_json="$(v2k_linux_bootstrap_resolve_default_kernel "${root}")"
jq -e --arg kver "${k_new}" '.selected == $kver and .source == "bls_entry"' <<<"${kernel_json}" >/dev/null

[[ "$(v2k_linux_bootstrap_driver_state "${root}" "${k_new}" virtio_pci)" == "builtin" ]]
[[ "$(v2k_linux_bootstrap_driver_state "${root}" "${k_new}" virtio_scsi)" == "module_file" ]]
[[ "$(v2k_linux_bootstrap_virtio_transport_state "${root}" "${k_new}")" == "available_builtin:boot_config" ]]

inventory="$(v2k_linux_bootstrap_collect_driver_inventory "${root}" "${k_new}")"
jq -e '
  .drivers.virtio_pci == "builtin"
  and .drivers.virtio_scsi == "module_file"
  and .drivers.virtio_blk == "module_file"
  and .capabilities.virtio_pci_transport == "available_builtin"
' <<<"${inventory}" >/dev/null

capability="$(v2k_linux_bootstrap_resolve_controller_capability "${inventory}")"
jq -e '.virtio == true and .sata == true and .recommended_controller == "virtio"' <<<"${capability}" >/dev/null

module_drivers="$(v2k_linux_bootstrap_module_file_drivers "${inventory}")"
grep -w 'virtio_scsi' <<<"${module_drivers}" >/dev/null
grep -w 'virtio_blk' <<<"${module_drivers}" >/dev/null
if grep -w 'virtio_pci' <<<"${module_drivers}" >/dev/null; then
  echo "[ERR] builtin virtio_pci must not be written to dracut add_drivers" >&2
  exit 1
fi

touch "${tmpdir}/disks/disk0.qcow2" "${tmpdir}/disks/disk1.qcow2"
manifest="${tmpdir}/manifest.json"
jq -nc \
  --arg d0 "${tmpdir}/disks/disk0.qcow2" \
  --arg d1 "${tmpdir}/disks/disk1.qcow2" \
  '{target:{storage:{type:"file"},format:"qcow2"},disks:[{transfer:{target_path:$d0}},{transfer:{target_path:$d1}}]}' \
  > "${manifest}"

mapfile -t inputs < <(v2k_linux_bootstrap_prepare_inputs "${manifest}")
[[ "${#inputs[@]}" -eq 2 ]]
[[ "${inputs[0]}" == "${tmpdir}/disks/disk0.qcow2"$'\t' ]]
[[ "${inputs[1]}" == "${tmpdir}/disks/disk1.qcow2"$'\t' ]]

set_cfg="$(v2k_linux_bootstrap_lvm_cfg_for_nbd_set /dev/nbd8 /dev/nbd9)"
grep -F 'a|^/dev/nbd8$|' <<<"${set_cfg}" >/dev/null
grep -F 'a|^/dev/nbd8p[0-9]+$|' <<<"${set_cfg}" >/dev/null
grep -F 'a|^/dev/nbd9$|' <<<"${set_cfg}" >/dev/null
grep -F 'a|^/dev/nbd9p[0-9]+$|' <<<"${set_cfg}" >/dev/null

echo "[OK] v2k linux bootstrap multidisk driver smoke"
