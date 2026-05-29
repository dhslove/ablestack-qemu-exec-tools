# 313. FT X-COLO Primary Role Diagnostics Design

Date: 2026-05-29

## Context

The `r97-link-01` FT run now proves that the 9000-series X-COLO compare
channels are established:

- `9003`: primary mirror peer channel
- `9004`: primary compare peer channel
- `9001`: primary compare loopback input
- `9005`: primary compare loopback output

The remaining failure is more specific than a network path problem. The primary
QEMU stays in `finish-migrate` / migration `active`, the secondary reaches
`inmigrate` / migration `colo`, and the secondary reports COLO role
`secondary`, but the primary does not report COLO role `primary`.

## Design

qemu FTCTL must preserve the runtime evidence needed to distinguish a QEMU
COLO role transition problem from earlier graph or channel failures.

1. Keep the existing runtime validation gate. Do not mark FT protection
   successful unless primary/secondary runtime state reaches the expected COLO
   pairing.
2. When the final validation reason is `primary_colo_role_not_entered`, capture
   QMP diagnostics for both primary and secondary domains under
   `/run/ablestack-vm-ftctl/debug/xcolo/<vm>/`.
3. Capture these QMP snapshots:
   - `query-status`
   - `query-migrate`
   - `query-colo-status`
   - `query-migrate-capabilities`
   - `query-migrate-parameters`
   - `query-named-block-nodes`
   - `query-chardev`
   - `query-iothreads`
4. Capture the primary QEMU process command line for generated domain argument
   verification.
5. Preserve the debug directory and derived capability/parameter booleans in
   the FTCTL state file so Cloud/UI can expose or relay the root cause without
   scraping host logs.
6. Remove the X-COLO debug directory during force cleanup/unprotect so stale
   diagnostics do not pollute the next test run.

## Error Classification

The runtime validator must refine `primary_colo_role_not_entered` when the
captured diagnostics identify a stronger cause:

- `primary_colo_capability_missing`: primary `x-colo` migration capability is
  explicitly disabled.
- `primary_return_path_capability_missing`: primary `return-path` migration
  capability is explicitly disabled.
- `primary_checkpoint_parameter_missing`: primary `x-checkpoint-delay` parameter
  is explicitly unset.
- `primary_colo_filter_objects_not_attached`: FTCTL did not record successful
  primary filter object attachment.
- `primary_qemu_colo_role_transition_failed`: channels, filters, capabilities,
  and checkpoint parameter look valid, but primary QEMU still does not enter the
  COLO primary role.

## Desired State

The next failed run, if it still fails, should no longer stop at the generic
`primary_colo_role_not_entered` label. It should leave enough host-local
evidence to answer whether:

- the primary capability setup was lost,
- the checkpoint parameter was not applied,
- primary filter objects were not attached,
- QEMU accepted all setup but failed the final COLO primary role transition.

This keeps the FT target intact: primary and secondary are clones at the service
identity level, and successful FT must allow secondary takeover without changing
guest identity such as IP address.
