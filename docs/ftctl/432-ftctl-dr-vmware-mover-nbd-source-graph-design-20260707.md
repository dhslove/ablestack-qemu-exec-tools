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
