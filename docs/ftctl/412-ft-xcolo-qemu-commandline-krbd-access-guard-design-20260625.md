# 412. FT XCOLO qemu-commandline KRBD access guard design - 2026-06-25

> Note: generated qemu commandline RBD backend rules in this document are
> superseded by
> [414. FT XCOLO RBD commandline backend contract](414-ft-xcolo-rbd-commandline-backend-contract-design-20260626.md).
> The access guard is part of the default KRBD path.  Default generated XCOLO
> args/XML must keep `/dev/rbd/rbd/<image>` and must reject `rbd:rbd/...` or
> `file=rbd:` URI leakage.

## Background

The r97-link-02 FT run advanced past the earlier stable KRBD URI issue:

- stable KRBD contract passed after primary stop;
- baseline seed for both disks completed;
- startup disk graph validation passed;
- generated guest ABI and PCI manifests matched.

The failure moved to generated primary startup. QEMU opened the COLO listener
sockets, then failed to open the primary RBD parent path:

```text
Could not open '/dev/rbd/rbd/912bc454-...': No such file or directory
```

After the failure, the host still had the stable paths:

```text
/dev/rbd/rbd/912bc454-... -> ../../rbd2
/dev/rbd/rbd/9cbba512-... -> ../../rbd3
```

This means the remaining problem is not a return to `rbd:rbd/...` and not a
different long-term path. The generated primary XML removes libvirt managed disk
devices and passes the COLO disk graph through `qemu:commandline`. As a result,
libvirt does not prepare those `/dev/rbd/...` paths as ordinary domain disks.
FTCTL must therefore prepare and verify the KRBD paths that appear in
`qemu:commandline`, not only the paths that remain in XML `<disk>` elements.

## Principles

1. Keep the ABLESTACK stable path rule: generated FT XML must keep using
   `/dev/rbd/rbd/<image>` for KRBD references.
2. Do not switch to `/dev/rbdN` as a persistent or generated XML path.
3. Do not convert stable KRBD paths to `rbd:rbd/...` or `file=rbd:` URIs.
4. Treat QEMU command-line KRBD access as a first-class startup preflight.
5. Do not report a generic channel timeout when QEMU already reported a KRBD
   open failure.

## Design

### 1. Extract KRBD paths from generated XML and qemu:commandline

The primary startup guard must inspect both places:

- XML disk sources, for legacy or non-startup-graph paths;
- every `qemu:arg` value, especially `file.filename=/dev/rbd/rbd/<image>`.

This closes the gap where `ftctl_primary_map_local_krbd_paths_from_xml` sees no
protected disk because the disks were intentionally moved to qemu command line.

### 2. Prepare primary KRBD runtime paths before `virsh create`

Before starting the generated primary domain, FTCTL must:

- map the stable path with the existing `ftctl_blockcopy_krbd_map_local` helper;
- wait for udev;
- verify the stable path still exists;
- ensure the qemu user can read and write the resolved block device, preferably
  with POSIX ACLs;
- verify qemu-user access with `runuser -u qemu -- test -r/-w` when the qemu
  account exists.

The existing RBD map helper remains the common map primitive. The new XCOLO
guard adds qemu-commandline extraction and qemu process access verification.

### 3. Hold marker

FTCTL records runtime hold markers under:

```text
/run/ablestack-vm-ftctl/krbd-hold/<vm>/
```

The marker is diagnostic today and provides a stable integration point for any
host-side unmap hook to skip FT-owned mappings. The marker must include the
stable path and resolved device for post-failure analysis.

### 4. Precise failure classification

If generated primary create exits before listener/channel attach, FTCTL must
classify QEMU stderr:

- `xcolo_primary_krbd_path_lost_at_create` for `/dev/rbd/` plus
  `No such file or directory`;
- `xcolo_primary_krbd_access_denied_at_create` for `/dev/rbd/` plus
  permission errors;
- existing PCI and parse classifications otherwise.

The outer channel attach flow must preserve this specific error instead of
overwriting it with `xcolo_channel_attach_timeout`.

### 5. Rollback visibility

Rollback can still fail independently. State must preserve the primary cause in
`xcolo_last_runtime_error` and `last_error`, and events must include the primary
create log directory so evidence is not lost.

## Expected result

The next run should either:

- pass generated primary startup with qemu-visible KRBD paths; or
- fail before/at primary create with a precise KRBD access error that includes
  whether the host path, resolved device, ACL, and qemu-user access were ready.

This design does not claim to solve later COLO migration or guest health issues;
it removes the current blind spot between stable KRBD path verification and the
actual generated QEMU startup.
