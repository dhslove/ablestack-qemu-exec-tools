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

ftctl_standby_generated_xml_path() {
  local vm="${1-}"
  local seed
  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  if [[ -n "${seed}" ]]; then
    printf '%s\n' "$(dirname "${seed}")/standby.generated.xml"
    return 0
  fi
  printf '%s\n' "${FTCTL_XML_BACKUP_DIR}/$(ftctl_state_vm_key "${vm}")/standby.generated.xml"
}

ftctl_primary_generated_xml_path() {
  local vm="${1-}"
  local primary
  primary="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  if [[ -n "${primary}" ]]; then
    printf '%s\n' "$(dirname "${primary}")/primary.generated.xml"
    return 0
  fi
  printf '%s\n' "${FTCTL_XML_BACKUP_DIR}/$(ftctl_state_vm_key "${vm}")/primary.generated.xml"
}

ftctl_standby_blockcopy_records() {
  local vm="${1-}"
  local out_array_name="${2}"
  local path line
  local -n _out_array="${out_array_name}"

  _out_array=()
  path="$(ftctl_blockcopy_state_path "${vm}")"
  [[ -f "${path}" ]] || return 1
  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    _out_array+=("${line}")
  done < "${path}"
  ((${#_out_array[@]} > 0))
}

ftctl_standby__source_attr_for_dest() {
  local dest="${1-}"
  if [[ "${dest}" == rbd:* ]]; then
    printf '%s\n' "rbd"
    return 0
  fi
  if [[ "${dest}" == /dev/* ]]; then
    printf '%s\n' "dev"
  else
    printf '%s\n' "file"
  fi
}

ftctl_standby__rewrite_xml() {
  local xml_path="${1-}"
  local target="${2-}"
  local dest="${3-}"
  local attr="${4-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for standby XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" TARGET_DEV="${target}" DEST_PATH="${dest}" SOURCE_ATTR="${attr}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
target_dev = os.environ["TARGET_DEV"]
dest_path = os.environ["DEST_PATH"]
source_attr = os.environ["SOURCE_ATTR"]

tree = ET.parse(xml_path)
root = tree.getroot()

for child in list(root):
    if child.tag in {"uuid", "id"}:
        root.remove(child)

devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in standby xml")

for disk in devices.findall("disk"):
    target = disk.find("target")
    if target is None or target.get("dev") != target_dev:
        continue
    if source_attr == "rbd":
        if not dest_path.startswith("rbd:"):
            raise SystemExit(f"invalid rbd dest: {dest_path}")
        body = dest_path[4:]
        pool, image = body.split("/", 1)
        disk.set("type", "network")
        source = disk.find("source")
        if source is None:
            source = ET.Element("source")
            disk.insert(0, source)
        hosts = [child for child in list(source) if child.tag == "host"]
        source.attrib.clear()
        source.set("protocol", "rbd")
        source.set("name", f"{pool}/{image}")
        for child in list(source):
            source.remove(child)
        for host in hosts:
            source.append(host)
    else:
        if source_attr == "dev":
            disk.set("type", "block")
        elif source_attr == "file":
            disk.set("type", "file")
        source = disk.find("source")
        if source is None:
            source = ET.Element("source")
            disk.insert(0, source)
        source.attrib.clear()
        source.set(source_attr, dest_path)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_standby__rewrite_domain_name() {
  local xml_path="${1-}"
  local domain_name="${2-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for standby XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" DOMAIN_NAME="${domain_name}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
domain_name = os.environ["DOMAIN_NAME"]

tree = ET.parse(xml_path)
root = tree.getroot()

name = root.find("name")
if name is None:
    name = ET.Element("name")
    root.insert(0, name)
name.text = domain_name

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_standby_krbd_paths() {
  local vm="${1-}"
  local out_array_name="${2}"
  local records=()
  local -n _out_array="${out_array_name}"
  local record target source dest format job_state ready secondary_dest path existing

  _out_array=()
  ftctl_standby_blockcopy_records "${vm}" records || return 0
  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"
    record="${record#*|}"
    job_state="${record%%|*}"
    record="${record#*|}"
    if [[ "${record}" == *"|"* ]]; then
      ready="${record%%|*}"
      secondary_dest="${record##*|}"
    else
      ready="${record}"
      secondary_dest=""
    fi
    : "${target}${source}${format}${job_state}${ready}"
    [[ -n "${secondary_dest}" ]] && dest="${secondary_dest}"
    [[ "${dest}" == /dev/rbd/* ]] || continue
    existing="0"
    for path in "${_out_array[@]}"; do
      if [[ "${path}" == "${dest}" ]]; then
        existing="1"
        break
      fi
    done
    [[ "${existing}" == "1" ]] || _out_array+=("${dest}")
  done
}

ftctl_standby_map_remote_krbd_path() {
  local host="${1-}"
  local user="${2-}"
  local path="${3-}"
  local spec q_path q_spec remote_cmd out err rc

  ftctl_blockcopy_krbd_spec_from_path "${path}" spec || return 1
  printf -v q_path '%q' "${path}"
  printf -v q_spec '%q' "${spec}"
  remote_cmd=$(cat <<EOF
set -euo pipefail
path=${q_path}
spec=${q_spec}
if [[ -b "\${path}" ]]; then
  exit 0
fi
command -v rbd >/dev/null 2>&1
rbd map "\${spec}" >/dev/null
udevadm settle >/dev/null 2>&1 || true
[[ -b "\${path}" ]]
EOF
)
  out=""
  err=""
  rc=0
  ftctl_blockcopy_remote_exec "${host}" "${user}" out err rc "${remote_cmd}" || true
  : "${out}"
  if [[ "${rc}" != "0" ]]; then
    echo "ERROR: peer rbd map failed for ${path}: ${err}" >&2
    return "${rc}"
  fi
}

ftctl_standby_map_peer_krbd_paths() {
  local vm="${1-}"
  local paths=()
  local path host user

  [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" != "cloud-managed" ]] || return 0
  ftctl_standby_krbd_paths "${vm}" paths
  ((${#paths[@]} > 0)) || return 0

  if ftctl_blockcopy_secondary_uri_is_local_system; then
    for path in "${paths[@]}"; do
      ftctl_blockcopy_krbd_map_local "${path}" || return $?
    done
  else
    host=""
    user=""
    ftctl_blockcopy_remote_target_host_user host user || return $?
    for path in "${paths[@]}"; do
      ftctl_standby_map_remote_krbd_path "${host}" "${user}" "${path}" || return $?
    done
  fi
  ftctl_log_event "standby" "standby.rbd-map" "ok" "${vm}" "" \
    "count=${#paths[@]} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_primary_krbd_paths_from_xml() {
  local xml_path="${1-}"
  local out_array_name="${2}"
  local payload line
  local -n _out_array="${out_array_name}"

  _out_array=()
  [[ -n "${xml_path}" && -f "${xml_path}" ]] || return 1
  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for primary KRBD XML inspection" >&2
    return 2
  }

  payload="$(python3 - "${xml_path}" <<'PY'
import sys
import xml.etree.ElementTree as ET

xml_path = sys.argv[1]
root = ET.parse(xml_path).getroot()
devices = root.find("devices")
seen = set()

if devices is not None:
    for disk in devices.findall("disk"):
        source = disk.find("source")
        if source is None:
            continue
        for attr in ("dev", "file", "name"):
            value = source.get(attr, "")
            if value.startswith("/dev/rbd/") and value not in seen:
                seen.add(value)
                print(value)
PY
)" || return $?

  while IFS= read -r line; do
    [[ -n "${line}" ]] || continue
    _out_array+=("${line}")
  done <<< "${payload}"
  return 0
}

ftctl_primary_map_local_krbd_paths_from_xml() {
  local vm="${1-}"
  local primary_xml="${2-}"
  local paths=()
  local path

  ftctl_primary_krbd_paths_from_xml "${primary_xml}" paths || return $?
  ((${#paths[@]} > 0)) || return 0

  for path in "${paths[@]}"; do
    if ! ftctl_blockcopy_krbd_map_local "${path}"; then
      ftctl_state_set "${vm}" "last_error=primary_rbd_map_failed"
      ftctl_log_event "primary" "primary.rbd-map" "fail" "${vm}" "" \
        "path=${path} primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
      return 1
    fi
  done

  ftctl_log_event "primary" "primary.rbd-map" "ok" "${vm}" "" \
    "count=${#paths[@]} primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
}

ftctl_xml_apply_qemu_commandline() {
  local xml_path="${1-}"
  local args_string="${2-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for qemu:commandline XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" QEMU_ARGS="${args_string}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
args_raw = os.environ.get("QEMU_ARGS", "")
args = [a for a in args_raw.split(";") if a]

if not args:
    raise SystemExit(0)

qemu_ns = "http://libvirt.org/schemas/domain/qemu/1.0"
ET.register_namespace("qemu", qemu_ns)

tree = ET.parse(xml_path)
root = tree.getroot()

qcmd = root.find(f"{{{qemu_ns}}}commandline")
if qcmd is not None:
    root.remove(qcmd)

qcmd = ET.Element(f"{{{qemu_ns}}}commandline")
for arg in args:
    node = ET.SubElement(qcmd, f"{{{qemu_ns}}}arg")
    node.set("value", arg)
root.append(qcmd)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_remove_qemu_commandline() {
  local xml_path="${1-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for qemu:commandline XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
qemu_ns = "http://libvirt.org/schemas/domain/qemu/1.0"
tree = ET.parse(xml_path)
root = tree.getroot()
qcmd = root.find(f"{{{qemu_ns}}}commandline")
if qcmd is not None:
    root.remove(qcmd)
tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_ensure_iothread_id() {
  local xml_path="${1-}"
  local iothread_id="${2-1}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for iothread XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" IOTHREAD_ID="${iothread_id}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
iothread_id = os.environ.get("IOTHREAD_ID", "1") or "1"

tree = ET.parse(xml_path)
root = tree.getroot()

def local_name(tag):
    return tag.rsplit("}", 1)[-1] if tag.startswith("{") else tag

children = list(root)
names = [local_name(child.tag) for child in children]

def find_child(name):
    for child in children:
        if local_name(child.tag) == name:
            return child
    return None

def insert_after_domain_identity(node):
    preferred_before = {"os", "features", "cpu", "clock", "on_poweroff", "on_reboot", "on_crash", "pm", "devices"}
    insert_at = len(list(root))
    for idx, child in enumerate(list(root)):
        if local_name(child.tag) in preferred_before:
            insert_at = idx
            break
    root.insert(insert_at, node)

iothreads = find_child("iothreads")
if iothreads is None:
    iothreads = ET.Element("iothreads")
    insert_after_domain_identity(iothreads)

iothreadids = find_child("iothreadids")
if iothreadids is None:
    iothreadids = ET.Element("iothreadids")
    root.insert(list(root).index(iothreads) + 1, iothreadids)

ids = []
for child in list(iothreadids):
    if local_name(child.tag) != "iothread":
        continue
    value = child.get("id")
    if value:
        ids.append(value)

if iothread_id not in ids:
    node = ET.Element("iothread")
    node.set("id", iothread_id)
    iothreadids.append(node)
    ids.append(iothread_id)

try:
    current_count = int((iothreads.text or "0").strip() or "0")
except ValueError:
    current_count = 0
required_count = max(current_count, len(set(ids)), int(iothread_id))
iothreads.text = str(required_count)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_validate_xcolo_iothread_contract() {
  local xml_path="${1-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for iothread XML validation" >&2
    return 2
  }

  XML_PATH="${xml_path}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
qemu_ns = "http://libvirt.org/schemas/domain/qemu/1.0"

tree = ET.parse(xml_path)
root = tree.getroot()

def local_name(tag):
    return tag.rsplit("}", 1)[-1] if tag.startswith("{") else tag

args = [
    node.get("value", "")
    for node in root.findall(f".//{{{qemu_ns}}}arg")
]

for value in args:
    if value.startswith("iothread") and "id=iothread" in value:
        print("x-colo iothread must be declared through libvirt native XML, not qemu:commandline", file=sys.stderr)
        raise SystemExit(1)

needs_iothread1 = any("iothread=iothread1" in value for value in args)
if not needs_iothread1:
    raise SystemExit(0)

iothreads = None
iothreadids = None
for child in list(root):
    name = local_name(child.tag)
    if name == "iothreads":
        iothreads = child
    elif name == "iothreadids":
        iothreadids = child

native_count = 0
if iothreads is not None:
    try:
        native_count = int((iothreads.text or "0").strip() or "0")
    except ValueError:
        native_count = 0

has_id1 = False
if iothreadids is not None:
    for child in list(iothreadids):
        if local_name(child.tag) == "iothread" and child.get("id") == "1":
            has_id1 = True
            break

if native_count < 1 or not has_id1:
    print("colo-compare references iothread1 but native libvirt iothread id=1 is missing", file=sys.stderr)
    raise SystemExit(1)
PY
}

ftctl_xml_apply_xcolo_network_runtime() {
  local xml_path="${1-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for x-colo network XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")

for iface in devices.findall("interface"):
    model = iface.find("model")
    if model is None or model.get("type") != "virtio":
        continue
    driver = iface.find("driver")
    if driver is None:
        driver = ET.Element("driver")
        insert_at = 0
        for idx, child in enumerate(list(iface)):
            if child.tag in {"mac", "source", "target", "model"}:
                insert_at = idx + 1
        iface.insert(insert_at, driver)
    driver.set("name", "qemu")
    for attr in ("vhost", "vhostfd"):
        if attr in driver.attrib:
            del driver.attrib[attr]

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_apply_standby_host_runtime() {
  local xml_path="${1-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for standby host XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")

for graphics in devices.findall("graphics"):
    if graphics.get("type") != "vnc":
        continue
    if graphics.get("listen"):
        graphics.set("listen", "0.0.0.0")
    for listen in graphics.findall("listen"):
        if listen.get("type") == "address" and listen.get("address"):
            listen.set("address", "0.0.0.0")

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_rewrite_first_disk_block_runtime() {
  local xml_path="${1-}"
  local dest_path="${2-}"
  local disk_format="${3-qcow2}"
  local disk_mode="${4-rw}"
  local boot_order="${5-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for block-backed runtime XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" DEST_PATH="${dest_path}" DISK_FORMAT="${disk_format}" DISK_MODE="${disk_mode}" BOOT_ORDER="${boot_order}" python3 - <<'PY'
import os
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
dest_path = os.environ["DEST_PATH"]
disk_format = os.environ["DISK_FORMAT"] or "qcow2"
disk_mode = os.environ["DISK_MODE"] or "rw"
boot_order = os.environ.get("BOOT_ORDER", "")

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")
os_node = root.find("os")
if os_node is not None and boot_order:
    for child in list(os_node):
        if child.tag == "boot":
            os_node.remove(child)

disk = None
for candidate in devices.findall("disk"):
    if candidate.get("device") == "disk":
        disk = candidate
        break

if disk is None:
    raise SystemExit("missing first disk device in xml")

disk.set("type", "block")
driver = disk.find("driver")
if driver is None:
    driver = ET.Element("driver")
    disk.insert(0, driver)
driver.set("name", "qemu")
driver.set("type", disk_format)
driver.set("discard", "unmap")

source = disk.find("source")
if source is None:
    source = ET.Element("source")
    disk.insert(1, source)
source.attrib.clear()
source.set("dev", dest_path)

target = disk.find("target")
if target is None:
    target = ET.Element("target")
    disk.append(target)
target_dev = target.get("dev") or "sda"
target_bus = target.get("bus") or "scsi"
target.set("dev", target_dev)
target.set("bus", target_bus)

for child in list(disk):
    if child.tag in {"readonly", "shareable", "boot", "alias", "address"}:
        disk.remove(child)

if disk_mode in {"ro", "ro-shareable"}:
    disk.append(ET.Element("readonly"))
if disk_mode in {"shareable", "ro-shareable"}:
    disk.append(ET.Element("shareable"))
if boot_order:
    boot = ET.Element("boot")
    boot.set("order", boot_order)
    disk.append(boot)

has_scsi = False
for controller in devices.findall("controller"):
    if controller.get("type") == "scsi":
        controller.set("model", "virtio-scsi")
        has_scsi = True
        break
if not has_scsi:
    controller = ET.Element("controller")
    controller.set("type", "scsi")
    controller.set("index", "0")
    controller.set("model", "virtio-scsi")
    devices.insert(1, controller)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_rewrite_disk_map_block_runtime() {
  local xml_path="${1-}"
  local disk_map="${2-}"
  local disk_format="${3-qcow2}"
  local disk_mode="${4-rw}"
  local boot_order="${5-}"
  local disk_metadata="${6-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for block-backed runtime XML rewrite" >&2
    return 2
  }

  XML_PATH="${xml_path}" DISK_MAP="${disk_map}" DISK_METADATA="${disk_metadata}" DISK_FORMAT="${disk_format}" DISK_MODE="${disk_mode}" BOOT_ORDER="${boot_order}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
disk_map_raw = os.environ["DISK_MAP"]
disk_metadata_raw = os.environ.get("DISK_METADATA", "")
disk_format = os.environ["DISK_FORMAT"] or ""
disk_mode = os.environ["DISK_MODE"] or "rw"
boot_order = os.environ.get("BOOT_ORDER", "")

disk_map = {}
for entry in disk_map_raw.split(";"):
    if not entry:
        continue
    if "=" not in entry:
        print(f"invalid disk map entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    target, dest = entry.split("=", 1)
    target = target.strip()
    dest = dest.strip()
    if not target or not dest:
        print(f"invalid disk map entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    disk_map[target] = dest

if not disk_map:
    print("empty disk map", file=sys.stderr)
    raise SystemExit(2)

disk_metadata = {}
for entry in disk_metadata_raw.split(";"):
    if not entry:
        continue
    if "=" not in entry:
        print(f"invalid disk metadata entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    target, rest = entry.split("=", 1)
    parts = rest.split("|")
    if len(parts) != 4:
        print(f"invalid disk metadata entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    dest, fmt, source_attr, disk_type = [part.strip() for part in parts]
    if not target or not dest or not fmt or source_attr not in {"dev", "file"} or disk_type not in {"block", "file"}:
        print(f"invalid disk metadata entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    disk_metadata[target.strip()] = {
        "dest": dest,
        "format": fmt,
        "source_attr": source_attr,
        "disk_type": disk_type,
    }

tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")
os_node = root.find("os")
if os_node is not None and boot_order:
    for child in list(os_node):
        if child.tag == "boot":
            os_node.remove(child)

seen_targets = set()
rewritten = 0
boot_written = False
for disk in devices.findall("disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    if target is None or not target.get("dev"):
        raise SystemExit("disk target is missing in xml")
    target_dev = target.get("dev")
    seen_targets.add(target_dev)
    if target_dev not in disk_map:
        raise SystemExit(f"disk target missing from FTCTL_PROFILE_DISK_MAP: {target_dev}")
    meta = disk_metadata.get(target_dev) or {
        "dest": disk_map[target_dev],
        "format": disk_format or "qcow2",
        "source_attr": "dev",
        "disk_type": "block",
    }
    if meta["dest"] != disk_map[target_dev]:
        raise SystemExit(f"disk metadata destination mismatch for {target_dev}")

    disk.set("type", meta["disk_type"])
    driver = disk.find("driver")
    if driver is None:
        driver = ET.Element("driver")
        disk.insert(0, driver)
    driver.set("name", "qemu")
    driver.set("type", meta["format"])
    driver.set("discard", "unmap")

    source = disk.find("source")
    if source is None:
        source = ET.Element("source")
        disk.insert(1, source)
    source.attrib.clear()
    source.set(meta["source_attr"], meta["dest"])

    if not target.get("bus"):
        target.set("bus", "scsi")

    for child in list(disk):
        if child.tag in {"readonly", "shareable", "boot", "alias", "address"}:
            disk.remove(child)

    if disk_mode in {"ro", "ro-shareable"}:
        disk.append(ET.Element("readonly"))
    if disk_mode in {"shareable", "ro-shareable"}:
        disk.append(ET.Element("shareable"))
    if boot_order and not boot_written:
        boot = ET.Element("boot")
        boot.set("order", boot_order)
        disk.append(boot)
        boot_written = True
    rewritten += 1

missing = sorted(set(disk_map) - seen_targets)
if missing:
    raise SystemExit("FTCTL_PROFILE_DISK_MAP target not found in xml: " + ",".join(missing))
if rewritten == 0:
    raise SystemExit("no disk devices rewritten")

has_scsi = False
for controller in devices.findall("controller"):
    if controller.get("type") == "scsi":
        controller.set("model", "virtio-scsi")
        has_scsi = True
        break
if not has_scsi:
    controller = ET.Element("controller")
    controller.set("type", "scsi")
    controller.set("index", "0")
    controller.set("model", "virtio-scsi")
    devices.insert(1, controller)

tree.write(xml_path, encoding="unicode")
PY
}

ftctl_xml_validate_disk_map_sources() {
  local xml_path="${1-}"
  local disk_map="${2-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for disk map source validation" >&2
    return 2
  }

  XML_PATH="${xml_path}" DISK_MAP="${disk_map}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
disk_map_raw = os.environ["DISK_MAP"]

expected = {}
for entry in disk_map_raw.split(";"):
    if not entry:
        continue
    if "=" not in entry:
        print(f"invalid disk map entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    target, dest = entry.split("=", 1)
    target = target.strip()
    dest = dest.strip()
    if not target or not dest:
        print(f"invalid disk map entry: {entry}", file=sys.stderr)
        raise SystemExit(2)
    expected[target] = dest

if not expected:
    print("empty disk map", file=sys.stderr)
    raise SystemExit(2)

root = ET.parse(xml_path).getroot()
devices = root.find("devices")
if devices is None:
    print("missing <devices> in xml", file=sys.stderr)
    raise SystemExit(2)

seen = set()
for disk in devices.findall("disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    source = disk.find("source")
    if target is None or not target.get("dev"):
        print("disk target is missing in xml", file=sys.stderr)
        raise SystemExit(2)
    target_dev = target.get("dev")
    if target_dev not in expected:
        continue
    if source is None:
        print(f"disk source is missing for {target_dev}", file=sys.stderr)
        raise SystemExit(2)
    actual = source.get("dev") or source.get("file") or ""
    if actual != expected[target_dev]:
        print(
            f"disk source mismatch for {target_dev}: expected {expected[target_dev]} got {actual}",
            file=sys.stderr,
        )
        raise SystemExit(1)
    seen.add(target_dev)

missing = sorted(set(expected) - seen)
if missing:
    print("disk map target not found in xml: " + ",".join(missing), file=sys.stderr)
    raise SystemExit(1)
PY
}

ftctl_xml_validate_unique_disk_targets() {
  local xml_path="${1-}"

  command -v python3 >/dev/null 2>&1 || {
    echo "ERROR: python3 is required for disk target XML validation" >&2
    return 2
  }

  XML_PATH="${xml_path}" python3 - <<'PY'
import os
import sys
import xml.etree.ElementTree as ET

xml_path = os.environ["XML_PATH"]
tree = ET.parse(xml_path)
root = tree.getroot()
devices = root.find("devices")
if devices is None:
    raise SystemExit("missing <devices> in xml")

seen = {}
duplicates = []
for disk in devices.findall("disk"):
    if disk.get("device") != "disk":
        continue
    target = disk.find("target")
    if target is None:
        continue
    dev = target.get("dev", "")
    bus = target.get("bus", "")
    if not dev:
        continue
    key = (dev, bus)
    source = disk.find("source")
    source_repr = ""
    if source is not None:
        source_repr = source.get("dev") or source.get("file") or source.get("name") or ""
    if key in seen:
        duplicates.append(f"{dev}/{bus or '-'}:{seen[key]}:{source_repr}")
    else:
        seen[key] = source_repr

if duplicates:
    print("duplicate disk target(s): " + "; ".join(duplicates), file=sys.stderr)
    raise SystemExit(1)
PY
}

ftctl_standby_materialize_primary_xml() {
  local vm="${1-}"
  local primary_xml generated

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" ]] || return 1

  generated="$(ftctl_primary_generated_xml_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${generated}")" "0755"
  cp -f "${primary_xml}" "${generated}"
  if [[ "${FTCTL_PROFILE_MODE}" == "ft" && -n "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY}" ]]; then
    if [[ "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY}" == *"iothread=iothread1"* ]]; then
      ftctl_xml_ensure_iothread_id "${generated}" "1" || return 1
    fi
    ftctl_xml_apply_qemu_commandline "${generated}" "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_PRIMARY}"
    ftctl_xml_validate_xcolo_iothread_contract "${generated}" || return 1
  fi
  ftctl_state_set "${vm}" "primary_xml_generated=${generated}"
}

ftctl_standby_materialize_xml() {
  local vm="${1-}"
  local seed out_path standby_vm_name
  local records=()
  local record target source dest format job_state ready secondary_dest attr

  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"
  [[ -n "${seed}" && -f "${seed}" ]] || {
    echo "ERROR: standby_xml_seed not found for ${vm}" >&2
    return 2
  }
  out_path="$(ftctl_standby_generated_xml_path "${vm}")"
  ftctl_ensure_dir "$(dirname "${out_path}")" "0755"
  cp -f "${seed}" "${out_path}"
  standby_vm_name="$(ftctl_profile_secondary_vm_name_resolved "${vm}")"
  ftctl_standby__rewrite_domain_name "${out_path}" "${standby_vm_name}"

  ftctl_standby_blockcopy_records "${vm}" records || {
    echo "ERROR: blockcopy state records not found for ${vm}" >&2
    return 2
  }

  for record in "${records[@]}"; do
    target="${record%%|*}"
    record="${record#*|}"
    source="${record%%|*}"
    record="${record#*|}"
    dest="${record%%|*}"
    record="${record#*|}"
    format="${record%%|*}"
    record="${record#*|}"
    job_state="${record%%|*}"
    record="${record#*|}"
    if [[ "${record}" == *"|"* ]]; then
      ready="${record%%|*}"
      secondary_dest="${record##*|}"
    else
      ready="${record}"
      secondary_dest=""
    fi
    : "${source}${format}${job_state}${ready}"

    if [[ -n "${secondary_dest}" ]]; then
      dest="${secondary_dest}"
    fi

    attr="$(ftctl_standby__source_attr_for_dest "${dest}")"
    ftctl_standby__rewrite_xml "${out_path}" "${target}" "${dest}" "${attr}"
  done

  if [[ "${FTCTL_PROFILE_MODE}" == "ft" && -n "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY}" ]]; then
    ftctl_xml_apply_qemu_commandline "${out_path}" "${FTCTL_PROFILE_XCOLO_QEMU_ARGS_SECONDARY}"
  fi

  ftctl_state_set "${vm}" \
    "standby_xml_generated=${out_path}" \
    "secondary_vm_name=${standby_vm_name}" \
    "standby_last_prepare_ts=$(ftctl_now_iso8601)"
  ftctl_log_event "standby" "standby.materialize" "ok" "${vm}" "" \
    "path=${out_path}"
}

ftctl_standby_prepare() {
  local vm="${1-}"
  local out err rc generated_xml persistence

  ftctl_standby_materialize_xml "${vm}"
  generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"
  if [[ "${persistence}" == "unknown" && ( "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ) ]]; then
    persistence="${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
    ftctl_state_set "${vm}" "primary_persistence=${persistence}"
  fi

  if [[ "${persistence}" != "yes" ]]; then
    if [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" ]]; then
      ftctl_state_set "${vm}" \
        "standby_state=prepared-transient" \
        "standby_domain_state=not-defined-expected" \
        "peer_domain_expected=false"
    else
      ftctl_state_set "${vm}" "standby_state=prepared-transient"
    fi
    ftctl_log_event "standby" "standby.prepare" "ok" "${vm}" "" \
      "mode=transient path=${generated_xml}"
    return 0
  fi

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "standby_state=define-dry-run"
    ftctl_log_event "standby" "standby.prepare" "skip" "${vm}" "" \
      "reason=dry_run path=${generated_xml}"
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" define "${generated_xml}" || true
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=define-failed" \
      "last_error=standby_define_failed"
    ftctl_log_event "standby" "standby.prepare" "fail" "${vm}" "${rc}" \
      "path=${generated_xml} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return "${rc}"
  fi

  ftctl_state_set "${vm}" \
    "standby_state=defined" \
    "standby_domain_state=defined" \
    "peer_domain_expected=true"
  ftctl_log_event "standby" "standby.prepare" "ok" "${vm}" "" \
    "mode=persistent path=${generated_xml} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_standby_activate() {
  local vm="${1-}"
  local persistence generated_xml out err rc secondary_vm_name

  generated_xml="$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)"
  [[ -n "${generated_xml}" ]] || {
    echo "ERROR: standby_xml_generated not found for ${vm}" >&2
    return 2
  }
  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"
  secondary_vm_name="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  if [[ "${persistence}" == "unknown" && ( "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "yes" || "${FTCTL_PROFILE_DOMAIN_PERSISTENCE:-auto}" == "no" ) ]]; then
    persistence="${FTCTL_PROFILE_DOMAIN_PERSISTENCE}"
    ftctl_state_set "${vm}" "primary_persistence=${persistence}"
  fi

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=start-dry-run" \
      "active_side=secondary"
    ftctl_log_event "standby" "standby.activate" "skip" "${vm}" "" \
      "reason=dry_run path=${generated_xml}"
    return 0
  fi

  if [[ "${FTCTL_PROFILE_BACKEND_MODE}" == "remote-nbd" ]]; then
    ftctl_blockcopy_stop_remote_nbd_exports "${vm}" || true
    ftctl_blockcopy_wait_remote_nbd_release "${vm}" || {
      ftctl_state_set "${vm}" \
        "standby_state=release-timeout" \
        "last_error=remote_nbd_release_timeout"
      return 1
    }
  fi

  ftctl_standby_map_peer_krbd_paths "${vm}" || {
    ftctl_state_set "${vm}" \
      "standby_state=activate-failed" \
      "last_error=standby_rbd_map_failed"
    ftctl_log_event "standby" "standby.rbd-map" "fail" "${vm}" "" \
      "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return 1
  }

  out=""
  err=""
  rc=0
  if [[ "${persistence}" == "yes" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" start "${secondary_vm_name}" || true
  else
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" create "${generated_xml}" || true
  fi
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    case "$(printf '%s %s' "${out}" "${err}" | tr '[:upper:]' '[:lower:]')" in
      *"already active"*|*"domain is already running"*|*"operation invalid"*"running"*|*"already exists with uuid"*)
        ftctl_state_set "${vm}" \
          "standby_state=running" \
          "active_side=secondary"
        ftctl_log_event "standby" "standby.activate" "ok" "${vm}" "" \
          "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} already_running=1"
        return 0
        ;;
    esac
    ftctl_state_set "${vm}" \
      "standby_state=activate-failed" \
      "last_error=standby_activate_failed"
    ftctl_log_event "standby" "standby.activate" "fail" "${vm}" "${rc}" \
      "path=${generated_xml} secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return "${rc}"
  fi

  ftctl_state_set "${vm}" \
    "standby_state=running" \
    "active_side=secondary"
  ftctl_log_event "standby" "standby.activate" "ok" "${vm}" "" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
}

ftctl_standby_deactivate_cloud_managed() {
  local vm="${1-}"
  shift || true
  local candidates=("$@")
  local secondary_vm_name seed out err rc state seen candidate

  secondary_vm_name="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  seed="$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"

  seen=" "
  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    [[ "${seen}" == *" ${candidate} "* ]] && continue
    seen="${seen}${candidate} "

    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" destroy "${candidate}" || true
    : "${out}${err}"
    if [[ "${rc}" != "0" ]]; then
      case "${err}" in
        *"failed to get domain"*|*"domain is not running"*|*"Domain not found"*)
          rc=0
          ;;
      esac
    fi
    if [[ "${rc}" != "0" ]]; then
      ftctl_log_event "standby" "standby.deactivate.destroy" "warn" "${vm}" "${rc}" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${candidate} cloud_managed=true"
    else
      ftctl_log_event "standby" "standby.deactivate.destroy" "ok" "${vm}" "" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${candidate} cloud_managed=true"
    fi
  done

  [[ -n "${seed}" && -f "${seed}" ]] || {
    ftctl_state_set "${vm}" \
      "standby_state=runtime_restore_failed" \
      "cloud_runtime_state_mismatch=true" \
      "cloud_runtime_restore=failed" \
      "cloud_runtime_restore_reason=standby_xml_seed_missing"
    ftctl_log_event "standby" "standby.deactivate.cloud_restore" "fail" "${vm}" "" \
      "reason=standby_xml_seed_missing secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return 1
  }

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" domstate "${secondary_vm_name}" || true
  state="$(printf '%s' "${out}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n1)"
  if [[ "${rc}" == "0" && -n "${state}" && "${state}" != "shut off" && "${state}" != "shutoff" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=running" \
      "peer_domain_expected=true" \
      "cloud_runtime_state_mismatch=false" \
      "cloud_runtime_restore=already_running"
    ftctl_log_event "standby" "standby.deactivate.cloud_restore" "ok" "${vm}" "" \
      "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${secondary_vm_name} state=${state} already_running=1"
    return 0
  fi

  out=""
  err=""
  rc=0
  if [[ "${state}" == "shut off" || "${state}" == "shutoff" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" start "${secondary_vm_name}" || true
  else
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" create "${seed}" || true
  fi
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=runtime_restore_failed" \
      "cloud_runtime_state_mismatch=true" \
      "cloud_runtime_restore=failed" \
      "cloud_runtime_restore_reason=restore_command_failed"
    ftctl_log_event "standby" "standby.deactivate.cloud_restore" "fail" "${vm}" "${rc}" \
      "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${secondary_vm_name} path=${seed}"
    return "${rc}"
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" domstate "${secondary_vm_name}" || true
  state="$(printf '%s' "${out}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n1)"
  if [[ "${rc}" != "0" || -z "${state}" || "${state}" == "shut off" || "${state}" == "shutoff" ]]; then
    ftctl_state_set "${vm}" \
      "standby_state=runtime_restore_failed" \
      "cloud_runtime_state_mismatch=true" \
      "cloud_runtime_restore=failed" \
      "cloud_runtime_restore_reason=restore_verify_failed"
    ftctl_log_event "standby" "standby.deactivate.cloud_restore.verify" "fail" "${vm}" "${rc}" \
      "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${secondary_vm_name} state=${state}"
    return 1
  fi

  ftctl_state_set "${vm}" \
    "standby_state=running" \
    "peer_domain_expected=true" \
    "cloud_runtime_state_mismatch=false" \
    "cloud_runtime_restore=ok"
  ftctl_log_event "standby" "standby.deactivate.cloud_restore" "ok" "${vm}" "" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${secondary_vm_name} path=${seed}"
}

ftctl_standby_deactivate() {
  local vm="${1-}"
  local secondary_vm_name out err rc state
  local candidates=() candidate xml xml_name seen name active_found

  secondary_vm_name="$(ftctl_state_get "${vm}" "secondary_vm_name" 2>/dev/null || ftctl_profile_secondary_vm_name_resolved "${vm}")"
  candidates+=("${secondary_vm_name}")
  candidates+=("$(ftctl_profile_secondary_vm_name_resolved "${vm}")")
  for xml in \
    "$(ftctl_state_get "${vm}" "standby_xml_generated" 2>/dev/null || true)" \
    "$(ftctl_state_get "${vm}" "standby_xml_seed" 2>/dev/null || true)"; do
    if [[ -n "${xml}" && -f "${xml}" ]]; then
      xml_name="$(sed -n 's:.*<name>\([^<]*\)</name>.*:\1:p' "${xml}" | head -n1)"
      [[ -n "${xml_name}" ]] && candidates+=("${xml_name}")
    fi
  done

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_state_set "${vm}" "standby_state=stopped-dry-run"
    ftctl_log_event "standby" "standby.deactivate" "skip" "${vm}" "" \
      "reason=dry_run secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    return 0
  fi

  if [[ "${FTCTL_PROFILE_PROVISIONING_BACKEND:-libvirt-managed}" == "cloud-managed" && "${FTCTL_PROFILE_MODE:-}" == "ft" ]]; then
    ftctl_standby_deactivate_cloud_managed "${vm}" "${candidates[@]}"
    return $?
  fi

  seen=" "
  for candidate in "${candidates[@]}"; do
    [[ -n "${candidate}" ]] || continue
    [[ "${seen}" == *" ${candidate} "* ]] && continue
    seen="${seen}${candidate} "

    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" destroy "${candidate}" || true
    : "${out}${err}"
    if [[ "${rc}" != "0" ]]; then
      case "${err}" in
        *"failed to get domain"*|*"domain is not running"*|*"Domain not found"*)
          rc=0
          ;;
      esac
    fi
    if [[ "${rc}" != "0" ]]; then
      ftctl_log_event "standby" "standby.deactivate.destroy" "warn" "${vm}" "${rc}" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${candidate}"
    else
      ftctl_log_event "standby" "standby.deactivate.destroy" "ok" "${vm}" "" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${candidate}"
    fi

    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" undefine "${candidate}" || true
    : "${out}${err}"
    if [[ "${rc}" != "0" ]]; then
      case "${err}" in
        *"failed to get domain"*|*"Domain not found"*|*"not found"*)
          rc=0
          ;;
      esac
    fi
    if [[ "${rc}" != "0" ]]; then
      ftctl_log_event "standby" "standby.deactivate.undefine" "warn" "${vm}" "${rc}" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${candidate}"
    else
      ftctl_log_event "standby" "standby.deactivate.undefine" "ok" "${vm}" "" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${candidate}"
    fi
  done

  active_found="0"
  seen=" "
  for name in "${candidates[@]}"; do
    [[ -n "${name}" ]] || continue
    [[ "${seen}" == *" ${name} "* ]] && continue
    seen="${seen}${name} "
    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_SECONDARY_URI}" domstate "${name}" || true
    state="$(printf '%s' "${out}" | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | head -n1)"
    if [[ "${rc}" == "0" && -n "${state}" && "${state}" != "shut off" && "${state}" != "shutoff" ]]; then
      active_found="1"
      ftctl_log_event "standby" "standby.deactivate.verify" "fail" "${vm}" "" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domain=${name} state=${state}"
    fi
  done
  if [[ "${active_found}" == "1" ]]; then
    ftctl_state_set "${vm}" "standby_state=stop_failed"
    return 1
  fi

  if declare -F ftctl_xcolo_unmap_secondary_runtime_rbd >/dev/null 2>&1; then
    ftctl_xcolo_unmap_secondary_runtime_rbd "${vm}" || {
      ftctl_log_event "standby" "standby.deactivate.runtime_rbd_unmap" "warn" "${vm}" "" \
        "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI}"
    }
  fi

  ftctl_state_set "${vm}" "standby_state=stopped"
  ftctl_log_event "standby" "standby.deactivate" "ok" "${vm}" "" \
    "secondary_uri=${FTCTL_PROFILE_SECONDARY_URI} domains=$(printf '%s,' "${candidates[@]}")"
}

ftctl_primary_activate_from_backup() {
  local vm="${1-}"
  local primary_xml persistence out err rc

  primary_xml="$(ftctl_state_get "${vm}" "primary_xml_backup" 2>/dev/null || true)"
  [[ -n "${primary_xml}" && -f "${primary_xml}" ]] || {
    echo "ERROR: primary_xml_backup not found for ${vm}" >&2
    return 2
  }

  persistence="$(ftctl_state_get "${vm}" "primary_persistence" 2>/dev/null || echo "unknown")"

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    ftctl_log_event "primary" "primary.activate" "skip" "${vm}" "" \
      "reason=dry_run primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
    return 0
  fi

  ftctl_primary_map_local_krbd_paths_from_xml "${vm}" "${primary_xml}" || return $?

  out=""
  err=""
  rc=0
  if [[ "${persistence}" == "yes" ]]; then
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" define "${primary_xml}" || true
    : "${out}${err}"
    if [[ "${rc}" != "0" ]]; then
      ftctl_log_event "primary" "primary.define" "fail" "${vm}" "${rc}" \
        "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
      return "${rc}"
    fi
    out=""
    err=""
    rc=0
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" start "${vm}" || true
  else
    ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${FTCTL_PROFILE_PRIMARY_URI}" create "${primary_xml}" || true
  fi
  : "${out}${err}"
  if [[ "${rc}" != "0" ]]; then
    case "${out}${err}" in
      *"domain is already running"*|*"Domain is already active"*|*"domain already active"*|*"already active"*)
        rc=0
        ;;
    esac
  fi
  if [[ "${rc}" != "0" ]]; then
    ftctl_log_event "primary" "primary.activate" "fail" "${vm}" "${rc}" \
      "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
    return "${rc}"
  fi

  ftctl_log_event "primary" "primary.activate" "ok" "${vm}" "" \
    "primary_uri=${FTCTL_PROFILE_PRIMARY_URI}"
}

ftctl_activate_domain_from_xml() {
  local uri="${1-}"
  local vm_name="${2-}"
  local xml_path="${3-}"
  local out err rc

  [[ -n "${xml_path}" && -f "${xml_path}" ]] || return 2

  if [[ "${FTCTL_DRY_RUN}" == "1" ]]; then
    return 0
  fi

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" destroy "${vm_name}" || true
  : "${out}${err}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" undefine "${vm_name}" || true
  : "${out}${err}"

  out=""
  err=""
  rc=0
  ftctl_virsh "${FTCTL_BLOCKCOPY_WAIT_TIMEOUT_SEC}" out err rc -- -c "${uri}" create "${xml_path}" || true
  : "${out}${err}"
  return "${rc}"
}
