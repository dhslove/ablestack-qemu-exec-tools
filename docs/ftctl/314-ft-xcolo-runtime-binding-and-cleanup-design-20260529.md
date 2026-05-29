# 314. FT X-COLO Runtime Binding And Cleanup Design

Date: 2026-05-29

## Context

The latest `r97-link-01` FT run reached the runtime convergence stage:

- primary status: `finish-migrate`
- primary migration: `active`
- primary COLO mode: `none`
- secondary status: `inmigrate`
- secondary migration: `colo`
- secondary COLO mode: `secondary`

The previous diagnostic work proved that the basic prerequisites were present:

- `x-colo` migration capability enabled
- `return-path` migration capability enabled
- `x-checkpoint-delay` set
- 9000-series compare/mirror sockets connected

The remaining failure is therefore not a simple port or capability omission.
The next boundary is whether QEMU has actually bound the COLO filter chardevs
and block graph nodes into the live primary runtime.

## Design

qemu FTCTL must distinguish "socket connected" from "QEMU frontend bound".

1. On `primary_colo_role_not_entered`, collect primary `query-chardev` state and
   record whether the required frontend labels are open:
   - `mirror0`
   - `compare1`
   - `compare0`
   - `compare0-0`
   - `compare_out`
   - `compare_out0`
2. Collect primary `query-named-block-nodes` state and verify each FT disk has
   the expected runtime nodes:
   - `ftctl-colo-<target>`
   - `ftctl-primary-active-<target>`
   - `<nbd-node-base>-<target>`
3. Refine the runtime validation error before falling back to generic QEMU role
   transition failure:
   - `primary_filter_chardev_frontend_incomplete`
   - `primary_block_graph_incomplete`
   - `primary_qemu_colo_role_transition_failed`
4. Preserve the raw QMP snapshots under
   `/run/ablestack-vm-ftctl/debug/xcolo/<vm>/` for postmortem comparison.

## Failure Cleanup

Runtime validation failure must leave the primary domain usable and must not
leave a transient secondary runtime running accidentally.

The existing recovery path already restores the primary from backup XML. It now
also treats secondary cleanup as a stronger operation:

1. `destroy` the secondary runtime domain.
2. `undefine` the secondary runtime domain when libvirt still has a definition.
3. Verify the secondary domain is absent or shut off.
4. Record `standby_state=stop_failed` if the runtime is still active.

Cloud DB synchronization remains a Cloud-side responsibility. qemu FTCTL should
not directly mutate Cloud DB rows, but it must leave unambiguous local evidence
for Cloud/Mold Agent reconciliation.

## Desired State

The next failed FT attempt should identify one of these narrower causes:

- primary chardev frontend binding is incomplete,
- primary block graph node construction is incomplete,
- QEMU accepted both but still did not transition the primary COLO role.

If the attempt fails, secondary runtime cleanup should not leave
`i-2-<standby>-VM` running on the compute host.
