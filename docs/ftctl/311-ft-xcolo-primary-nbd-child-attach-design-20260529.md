# FT X-COLO Primary NBD Child Attach Design

## Background

During the `r97-link-01` FT retest, qemu FTCTL proved that the source image was not permanently corrupted. While FT protection was active, the generated primary VM stayed paused in `finish-migrate`, the secondary stayed paused in `inmigrate`, and only the secondary reported a COLO role:

- primary `query-status.status=finish-migrate`
- primary `query-colo-status.mode=none`
- secondary `query-status.status=inmigrate`
- secondary `query-colo-status.mode=secondary`
- primary migration `active`
- secondary migration `colo`

After runtime recovery restored the original primary XML, the VM returned to `running` and its disks again pointed directly at the original RBD devices. Therefore the failure is not an image corruption problem. It is a runtime X-COLO graph/transition problem.

## Design Correction

The primary-side remote disk child must follow the QEMU COLO sequence:

1. start the secondary NBD export before primary migration
2. add the primary-side NBD client node
3. build the primary quorum node around the local active child
4. replace the primary disk device with the quorum node
5. attach the remote NBD child with `x-blockdev-change`
6. attach COLO network filters
7. enable `x-colo` migration capability and run `migrate`

The previous cloud-managed multi-disk path created the primary quorum with both children already present:

```text
quorum children = [local-active-qcow2, remote-nbd]
```

That graph looked similar after inspection, but it skipped the explicit `x-blockdev-change` transition used by QEMU's COLO procedure. The corrected graph build is:

```text
blockdev-add local active qcow2
blockdev-add quorum children=[local-active-qcow2]
startup transient XML already contains the quorum disk
runtime device_del/device_add is forbidden
x-blockdev-change parent=quorum node=remote-nbd
```

## Failure Classification

The role classifier introduced in document 310 remains valid. If the secondary enters `mode=secondary` but the primary remains `mode=none`, qemu FTCTL reports:

```text
xcolo_runtime_validation_failed:primary_colo_role_not_entered
```

This error means "primary COLO transition failed", not "guest disk is corrupt".

If the 9000-series COLO compare/proxy channel is not established, qemu FTCTL
must report the channel-specific error defined in
[312. FT X-COLO 9000-Series Channel Validation Design](312-ft-xcolo-9000-channel-validation-design-20260529.md)
before falling back to this generic role-transition error.

## Error Preservation

When FT runtime is already in `error/failed`, generic reconcile must not clear `last_error`. qemu FTCTL must preserve the runtime failure and status JSON must use `xcolo_last_runtime_error` as the fallback if `last_error` is blank.

This is required because Cloud uses the qemu status output to publish `ftctl.last.error`.

## Cloud-Managed Cleanup Boundary

qemu FTCTL may deactivate/destroy transient runtime domains during recovery, but Cloud still owns the standby VM and volume lifecycle. After qemu reports an FT runtime failure, Cloud must reconcile the cloud-managed standby VM and volumes instead of assuming a libvirt domain still exists.

This document does not move VM or volume lifecycle ownership into qemu FTCTL. It only makes qemu's runtime state and failure reason accurate enough for Cloud cleanup.

## Test Coverage

Selftests must assert:

- primary NBD nodes are created before primary migrate
- primary quorum is first created with the local active child only
- primary remote NBD child is attached through `x-blockdev-change` against a startup-created quorum node
- runtime guest-visible disk replacement is superseded by [363. FT X-COLO Startup Disk Graph And No Hot Plug Design](363-ft-xcolo-startup-disk-graph-no-hotplug-design-20260605.md)
- status JSON emits sticky runtime errors when `last_error` is blank in an error state
