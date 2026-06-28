# FT XCOLO Parent NBD QEMU Identity Contract Design

## Context

Document 428 introduced a QEMU-runtime-user probe for the primary parent NBD
adapter. The next retest correctly moved the failure from `virsh create` into
the new pre-create gate, but the gate failed with empty identity evidence:

```text
xcolo.primary_parent_nbd.permission result=ok user="" group=""
xcolo.primary_parent_nbd.qemu_user_probe result=fail user=""
last_error=xcolo_primary_parent_nbd_permission_failed
```

This showed that the permission model was directionally correct, but the
helper that resolves the libvirt QEMU runtime user/group did not reliably
return values to its caller.

## Root Cause

The original helper and its callers both used local variables named
`qemu_user` and `qemu_group`.

Bash uses dynamic scoping for local variables. When the helper called:

```bash
printf -v "${out_user}" '%s' "${qemu_user}"
```

with `out_user=qemu_user`, it could write to the helper's own local
`qemu_user` variable instead of the caller's variable with the same name. The
caller therefore continued with empty user/group values.

## Design Principles

- QEMU runtime identity is a hard precondition for the parent NBD adapter path.
- Empty user/group values must never produce a successful permission event.
- Identity failure and socket permission failure must be distinguishable.
- The fix must not alter the COLO topology, disk graph, machine type, or the
  already-successful `r97-link-01` runtime.

## AS-IS

| Layer | Behavior |
| --- | --- |
| Identity helper locals | Uses `qemu_user` / `qemu_group` internally. |
| Caller locals | Also commonly uses `qemu_user` / `qemu_group`. |
| Bash scoping | Same-name locals can hide the caller output variables. |
| Empty identity handling | Could log permission `ok` with empty user/group. |
| Probe failure | Reported as generic parent NBD permission failure. |

## TO-BE

| Layer | Behavior |
| --- | --- |
| Identity helper locals | Uses collision-resistant `resolved_user` / `resolved_group`. |
| Identity validation | Requires non-empty user and group, and validates both through system identity lookup. |
| Permission helper | Fails hard with `xcolo_primary_parent_nbd_identity_failed` if identity is unresolved or empty. |
| QEMU-user probe | Fails hard with the same identity error before trying `runuser` with an empty user. |
| Evidence | `xcolo.primary_parent_nbd.permission` and `xcolo.primary_parent_nbd.qemu_user_probe` must include real user/group values. |

## Code Changes

### `lib/ftctl/xcolo.sh`

Update `ftctl_xcolo_libvirt_qemu_identity`:

- rename internal variables to `resolved_user` and `resolved_group`
- validate output variable names are present
- validate user and group are non-empty
- validate both identity records exist before writing output variables
- use `id -gn <user>` as the group fallback when configured group is missing

Update callers:

- `ftctl_xcolo_fix_parent_nbd_socket_permissions`
  - identity failure sets `last_error=xcolo_primary_parent_nbd_identity_failed`
  - empty identity is a hard failure
  - permission `ok` is logged only with concrete user/group values
- `ftctl_xcolo_probe_parent_nbd_as_qemu_user`
  - identity failure sets `last_error=xcolo_primary_parent_nbd_identity_failed`
  - does not call `runuser` with an empty user
  - success evidence includes both user and group

### `bin/ablestack_vm_ftctl_selftest.sh`

Add `selftest_case_xcolo_libvirt_qemu_identity_avoids_local_name_collision`:

- declares caller locals named exactly `qemu_user` and `qemu_group`
- calls `ftctl_xcolo_libvirt_qemu_identity qemu_user qemu_group`
- verifies the caller locals are populated
- verifies unresolved identities fail hard and leave outputs empty

## Validation Plan

1. Syntax:
   - `bash -n lib/ftctl/xcolo.sh`
   - `bash -n bin/ablestack_vm_ftctl_selftest.sh`
2. Targeted selftests:
   - `selftest_case_xcolo_libvirt_qemu_identity_avoids_local_name_collision`
   - `selftest_case_xcolo_primary_parent_nbd_qemu_user_probe`
3. Existing related selftests:
   - startup disk graph KRBD tests
   - primary parent NBD seed test
4. Host smoke after deployment:
   - source the installed `xcolo.sh`
   - confirm `ftctl_xcolo_libvirt_qemu_identity qemu_user qemu_group`
     returns `qemu/qemu` on the 32.x hosts
5. Retest `r97-link-02`:
   - expected:
     - `xcolo.primary_parent_nbd.permission result=ok user=qemu group=qemu`
     - `xcolo.primary_parent_nbd.qemu_user_probe result=ok user=qemu group=qemu`
   - next milestone:
     - `primary.create_generated.listeners result=ok`

## Non-Goals

- Do not change storage backend policy.
- Do not introduce librbd.
- Do not change the COLO network filter order.
- Do not modify Cloud DB schema or VM details for this fix.
