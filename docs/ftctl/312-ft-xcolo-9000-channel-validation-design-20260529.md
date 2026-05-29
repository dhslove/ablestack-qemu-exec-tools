# 312. FT X-COLO 9000-Series Channel Validation Design

Date: 2026-05-29

## Context

After the primary NBD child attach fix, the `r97-link-01` FT run progressed beyond
multi-disk block graph construction. Both sides reached the migration handshake:

- primary QMP status: `finish-migrate`
- primary migration status: `active`
- primary COLO mode: `none`
- secondary QMP status: `inmigrate`
- secondary migration status: `colo`
- secondary COLO mode: `secondary`

This proves the `9998` migration path and `10809` remote NBD export path can be
used, but it does not prove that the COLO network compare path is healthy.

The missing explicit contract is the 9000-series compare/proxy channel:

- `9003`: primary `mirror0` server, connected by secondary `red0`
- `9004`: primary `compare1` server, connected by secondary `red1`
- `9001`: primary local `compare0` / `compare0-0` loopback path
- `9005`: primary local `compare_out` / `compare_out0` loopback path

If those channels are not all established after primary filter objects are
attached, QEMU can have a valid block graph while the primary never enters the
COLO primary role.

## Design

qemu FTCTL must treat the 9000-series channels as a first-class FT readiness
gate.

1. During generated primary/secondary startup, keep the existing passive socket
   checks. Do not use active TCP connect probes because those can consume QEMU
   chardev server sockets.
2. After primary QMP attaches `filter-redirector`, `colo-compare`, and
   `filter-mirror`, verify all 9000-series channels through local socket state:
   `9003`, `9004`, `9001`, and `9005` must be `ESTAB`.
3. Runtime validation must capture the same channel state every time it evaluates
   COLO role convergence.
4. If primary migration is `active`, secondary migration is `colo`, but the
   primary does not enter the COLO role and one of the 9000-series channels is
   not established, report a channel-specific failure instead of the generic
   `primary_colo_role_not_entered`.

## Error Classification

The following errors are more useful than the previous generic role failure:

- `colo_mirror_channel_not_established`
- `colo_compare_peer_channel_not_established`
- `colo_compare_loopback_in_not_established`
- `colo_compare_loopback_out_not_established`
- `primary_colo_role_not_entered` remains valid only when all required channels
  are established and the primary still does not enter the COLO role.

When all four 9000-series channels are established and the failure remains
`primary_colo_role_not_entered`, follow
`313-ft-xcolo-primary-role-diagnostics-design-20260529.md`. At that point the
next useful evidence is primary QMP capability/parameter/filter state, not
additional socket-path probing.

## Desired State

A successful FT protection run must satisfy all of these conditions:

- Cloud/qemu state reaches `colo_running` / `mirroring`.
- Primary and secondary runtime XML contain the expected X-COLO markers.
- Primary and secondary QMP migration states are in the expected COLO pairing
  state.
- Primary and secondary report active COLO roles when the QEMU build exposes
  role state through `query-colo-status`.
- The 9000-series channels are established:
  - mirror peer channel: `9003`
  - compare peer channel: `9004`
  - compare loopback input: `9001`
  - compare loopback output: `9005`

## Cloud-Managed Failure Cleanup Note

When qemu FTCTL performs runtime failure recovery, it can restore the primary
domain and remove the transient secondary domain, but it cannot directly change
Cloud DB VM state. The qemu state must therefore preserve clear evidence that
the secondary runtime was stopped (`standby_state=stopped`) and the exact runtime
error. Cloud-side cleanup/synchronization should use that evidence to avoid a
standby VM remaining displayed as `Running` after qemu has already deactivated
the transient domain.
