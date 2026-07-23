# FTCTL DR VMware Mover NBD Source Graph Design

Date: 2026-07-07

## 1. Problem

The VMware to ABLESTACK DR sync for plan
`987bb250-3b5a-4053-9720-2ff93b4cc88c` reached the bundled VMware mover, loaded
VDDK through nbdkit, and prepared the target RBD image. The mover then failed at
`qemu-img convert`:

```text
qemu-img: Could not open 'json:{"driver":"nbd","server":{"type":"unix","path":"/tmp/.../vddk.sock"}}':
  A block device must be specified for "file"
```

The current code in `lib/ftctl/dr_vmware_mover.sh` builds:

```bash
nbd_source="json:{\"driver\":\"nbd\",\"server\":{\"type\":\"unix\",\"path\":\"${socket_path}\"}}"
qemu-img convert -p -n -f raw -O "${target_format:-raw}" "${nbd_source}" "${target_uri}"
```

This gives QEMU an NBD protocol node while also forcing the source format to
raw. The raw driver expects a child named `file`, so the source graph is invalid.

## 2. Design

Represent the source as raw-over-NBD:

```text
raw
  file -> nbd unix socket
```

Use QEMU image options:

```bash
source_opts="driver=raw,file.driver=nbd,file.server.type=unix,file.server.path=${socket_path}"

qemu-img info --force-share --image-opts "${source_opts}"

qemu-img convert --force-share -p -n --image-opts \
  -O "${target_format:-raw}" \
  "${source_opts}" \
  "${target_uri}"
```

Do not pass `-f raw` with `--image-opts`.

## 3. Code Changes

File: `lib/ftctl/dr_vmware_mover.sh`

Add helpers:

```bash
ftctl_vmware_mover_qemu_opt_escape() {
  local value="${1-}"
  value="${value//\\/\\\\}"
  value="${value//,/\\,}"
  printf '%s' "${value}"
}

ftctl_vmware_mover_source_image_opts() {
  local socket_path="${1-}"
  [[ -n "${socket_path}" ]] || ftctl_vmware_mover_die 72 \
    "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID: nbd socket path is empty"
  printf 'driver=raw,file.driver=nbd,file.server.type=unix,file.server.path=%s\n' \
    "$(ftctl_vmware_mover_qemu_opt_escape "${socket_path}")"
}
```

Then replace the direct NBD JSON convert with:

```bash
source_opts="$(ftctl_vmware_mover_source_image_opts "${socket_path}")"
if ! timeout "${FTCTL_DR_VMWARE_QEMU_INFO_TIMEOUT:-20}" \
    qemu-img info --force-share --image-opts "${source_opts}" >/dev/null; then
  ftctl_vmware_mover_die 72 \
    "DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID: qemu-img cannot open VDDK NBD source for ${label}"
fi

if ! qemu-img convert --force-share -p -n --image-opts \
    -O "${target_format:-raw}" \
    "${source_opts}" \
    "${target_uri}"; then
  ftctl_vmware_mover_die 68 "qemu-img conversion failed for ${label}"
fi
```

The implementation must preserve the existing nbdkit cleanup for both preflight
and convert failures.

## 4. Error Mapping

Update:

- `lib/ftctl/dr_runtime.sh`
- `lib/ftctl/dr_scheduler.sh`

New mapping:

| Exit | Error code |
| --- | --- |
| 72 | `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` |

Exit 68 remains `DR_VMWARE_MOVER_FAILED`.

## 5. Selftests

Add selftests:

| Test | Expected |
| --- | --- |
| `dr-vmware-mover-source-image-opts` | convert command contains `--image-opts` and `driver=raw,file.driver=nbd` |
| `dr-vmware-mover-no-direct-nbd-json` | direct `json:{"driver":"nbd"...}` with `-f raw` is not used |
| `dr-vmware-mover-source-graph-preflight-fail` | failed source probe exits 72 |
| `dr-vmware-mover-source-graph-error-code` | runtime/scheduler status maps 72 to `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` |

## 6. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
| --- | --- | --- |
| Source graph | NBD node passed directly with `-f raw` | raw image node wraps NBD file node |
| Probe | failure appears during convert | `qemu-img info --image-opts` validates before convert |
| Error | generic `DR_VMWARE_MOVER_FAILED` | specific `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` |
| Target | existing RBD URI path | unchanged |

## 7. Follow-up: VDDK Connect Contract

The raw-over-NBD source graph is now valid, but a later VMware-to-ABLESTACK run
failed with:

```text
VixDiskLib_ConnectEx: One of the parameters was invalid
```

That failure must not remain collapsed into the graph error. It indicates that
VDDK rejected source connection parameters, such as vCenter endpoint, VM MoRef,
disk path, snapshot reference, or credential data.

The follow-up design is:

```text
433-ftctl-dr-vmware-vddk-connect-contract-design-20260708.md
```

Error code separation:

| Exit | Error code | Meaning |
| --- | --- | --- |
| 72 | `DR_VMWARE_MOVER_SOURCE_GRAPH_INVALID` | QEMU source graph/probe is invalid |
| 73 | `DR_VMWARE_VDDK_CONNECT_INVALID` | VDDK rejected connect parameters |
| 74 | `DR_VMWARE_VDDK_EXPORT_UNAVAILABLE` | VDDK NBD export is unavailable |
| 75 | `DR_VMWARE_VDDK_SOURCE_LOCKED` | powered-on source VMDK is locked because no run snapshot is used |
| 76 | `DR_VMWARE_VDDK_OPEN_DENIED` | VDDK cannot open the requested VMDK path |

## 8. Follow-up: Deterministic NBD Drain

The raw-over-NBD graph and VDDK connection contract do not by themselves
complete the NBD block-device lifecycle. Live RPO-cycle evidence on
2026-07-23 showed sector-zero reads racing with immediate source/target NBD
disconnect.

The normative follow-up is:

```text
440-ftctl-dr-vmware-nbd-deterministic-drain-and-observability-design-20260723.md
```

All source and target NBD success/failure paths must use the shared deterministic
drain contract defined there. A cycle cannot be committed as completed merely
because the QEMU source graph opened and target writes were flushed; every
cycle-owned NBD device must also reach `DRAINED`.
