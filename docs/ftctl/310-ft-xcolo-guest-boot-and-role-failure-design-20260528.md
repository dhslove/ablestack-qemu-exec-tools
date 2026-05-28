# FT X-COLO Guest Boot And Role Failure Design

## Background

During the FT validation of `r97-link-01`, qemu FTCTL reached the generated primary/secondary runtime phase and the UI briefly looked successful. The VM console later showed the generated primary entering dracut emergency mode:

- `XFS (dm-0): metadata I/O error`
- `Uncorrected metadata errors detected; please run xfs_repair`
- `Failed to mount /sysroot`

At the same time, qemu runtime evidence showed the primary at `query-status.status=finish-migrate`, the secondary at `query-status.status=inmigrate`, primary migration `active`, secondary migration `colo`, and only the secondary reporting a non-`none` COLO role. The state eventually became `error/failed`, but `last_error` was lost while `xcolo_last_runtime_error` remained.

This means the runtime validator must be more explicit about two separate facts:

1. whether both QEMU sides have entered the expected COLO roles
2. whether the generated primary guest has become healthy enough to be treated as an FT source

## Design Principles

1. FT success still means a clone-level secondary that preserves VM identity, network identity, disk state, and memory checkpoint state.
2. Disk baseline completion, NBD graph creation, or migration `active/colo` alone is not FT success.
3. COLO role state is first-class runtime evidence. One-sided role entry must not be collapsed into generic convergence.
4. Guest boot health is observable by default and policy-enforced only when configured as required.
5. Runtime failure causes must survive recovery. If qemu FTCTL restores the original primary, `last_error` and `xcolo_last_runtime_error` must still explain why FT failed.

## Runtime Role Classification

When both runtime XML markers are present and migration reports primary `active` plus secondary `colo`, qemu FTCTL classifies COLO role state as follows:

- both primary and secondary `query-colo-status.mode` are non-empty and not `none`: role-active runtime state
- primary inactive or `none`, secondary active: `primary_colo_role_not_entered`
- primary active, secondary inactive or `none`: `secondary_colo_role_not_entered`
- both inactive or `none`: `colo_role_not_entered`

The previous broad rule, where any one active side meant `runtime_converging`, is too weak. A one-sided role is a specific failed transition after the bounded pending window.

## Guest Boot Health

qemu FTCTL records QGA guest-ping status for runtime validation:

- `xcolo_primary_qga=yes|no|off`
- `xcolo_secondary_qga=yes|no|off`

The profile already has `FTCTL_PROFILE_QGA_POLICY`:

- `optional`: record QGA health, but do not fail solely because guest-ping is unavailable
- `required`: do not declare runtime success unless the generated primary answers guest-ping
- `off`: skip the probe and record `off`

Only the generated primary is used as a hard QGA gate. The secondary may be in `inmigrate` or COLO receiver state where QGA is not a reliable readiness signal.

## Error Preservation

Runtime validation failures must set:

- `last_error=xcolo_runtime_validation_failed:<reason>`
- `xcolo_last_runtime_error=xcolo_runtime_validation_failed:<reason>`

Recovery may destroy the generated primary and restore the original primary XML. That recovery must not clear the failure reason. If a later reconcile sees `protection_state=error`, `conversion_state=error`, or `transport_state=failed` with blank `last_error`, it restores `last_error` from `xcolo_last_runtime_error`.

## Test Coverage

Selftests cover:

- both COLO roles missing: `colo_role_not_entered`
- only secondary role active: `primary_colo_role_not_entered`
- both explicit COLO roles active: runtime accepted
- optional QGA failure: QGA state recorded, runtime success still allowed
- required QGA failure: runtime fails as `primary_guest_boot_unhealthy`
- runtime recovery preserves the specific failure reason

## Operator Impact

If the guest image itself is damaged, qemu FTCTL must not attempt filesystem repair. It should stop the FT attempt, restore the original primary runtime when possible, preserve diagnostic state, and leave image recovery to the operator or cloud image workflow.
