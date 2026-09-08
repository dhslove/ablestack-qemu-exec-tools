# 413. FT XCOLO primary KRBD runtime visibility retry design - 2026-06-26

## Background

The r97-link-02 FT run after design 412 confirmed that the new KRBD extraction
and startup guard executed correctly for the generated primary XML.

The run reached these points:

- baseline seed completed for both disks;
- startup disk graph validation completed;
- guest ABI and generated PCI manifest checks passed;
- `xcolo.primary_krbd_runtime_path` reported stable KRBD paths as ready;
- hold markers were created under `/run/ablestack-vm-ftctl/krbd-hold/<vm>/`.

The remaining failure happened during generated primary `virsh create`:

```text
Could not open '/dev/rbd/rbd/912bc454-...': No such file or directory
```

After the failure, the host namespace still showed the stable KRBD symlinks and
`rbd showmapped` still showed the mapped devices. This means the previous guard
was not simply missing the path. The failure is now specifically between
host-visible KRBD preparation and the libvirt/QEMU process runtime view during
`virsh create`.

## Principles

1. Keep the ABLESTACK stable path rule. Generated FT XML must continue to use
   `/dev/rbd/rbd/<image>` and must not switch to `/dev/rbdN`.
2. Do not treat every QEMU ENOENT as the same problem. Distinguish a real lost
   KRBD path from a libvirt/QEMU runtime visibility gap.
3. Do not mask a primary create failure as a later listener or channel timeout.
4. Retry only once and only for the KRBD ENOENT case after re-preparing the same
   stable KRBD paths.
5. Preserve the original QEMU stderr and retry stderr for evidence.

## Design

### 1. Record create-time KRBD visibility

When QEMU reports `/dev/rbd/...: No such file or directory`, FTCTL re-reads the
KRBD paths from the generated XML and records whether each path is visible from
the host namespace at the failure phase.

The state keys are:

```text
xcolo_primary_krbd_create_visibility_phase
xcolo_primary_krbd_create_visibility_count
xcolo_primary_krbd_create_visible_paths
xcolo_primary_krbd_create_missing_paths
```

The event is:

```text
xcolo.primary_krbd_create_visibility
```

### 2. Classify host-visible ENOENT separately

The classifier now uses the generated XML and the current host view:

- if QEMU reports KRBD ENOENT and the same stable path is missing on the host,
  classify as `xcolo_primary_krbd_path_lost_at_create`;
- if QEMU reports KRBD ENOENT but at least one generated KRBD path is still
  visible on the host, classify as
  `xcolo_primary_krbd_libvirt_runtime_visibility_failed`.

This avoids repeating the same blind analysis cycle. The next failure report can
say whether the path was truly gone or only unavailable to the libvirt/QEMU
create context.

### 3. One controlled retry

For KRBD ENOENT only, generated primary create performs one retry:

1. keep the original stdout/stderr;
2. re-run KRBD preparation from the generated XML;
3. record create-time visibility before retry;
4. sleep briefly to allow udev/libvirt runtime propagation;
5. run `virsh create` once more;
6. append retry stdout/stderr into the same evidence files;
7. record retry state:

```text
xcolo_primary_create_retry
xcolo_primary_create_retry_reason
xcolo_primary_create_retry_rc
```

No retry is performed for permission, PCI topology, XML parse, or generic QEMU
startup errors.

### 4. Listener and channel wait loops must observe create exit

Generated primary startup is asynchronous. A failure can happen after the first
listener appears but before all listener/channel readiness checks finish.

Both wait paths now check the async create result at timeout boundaries:

- listener wait records `create_exited_after_listener_timeout`;
- channel attach wait records `create_exited_after_channel_attach_timeout`.

Both paths set:

```text
xcolo_protocol_failure_phase=primary_create
xcolo_primary_create_error_summary=<compact QEMU stderr>
last_error=<classified error>
```

This prevents Cloud/UI state from remaining in `pairing/planned` with an empty
last error when QEMU has already exited.

## Expected result

The next FT run should either start the generated primary after the controlled
KRBD retry, or fail with an explicit create-stage error that tells us which of
these is true:

- the stable KRBD path was lost on the host;
- the host path was visible but not visible to libvirt/QEMU at create time;
- a non-KRBD create error occurred.

This design intentionally does not change Cloud schema and does not introduce VM
detail keys. It only improves qemu FTCTL runtime preparation, retry behavior,
and evidence quality for the current XCOLO primary create failure.
