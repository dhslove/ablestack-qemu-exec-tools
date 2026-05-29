# 315. FT X-COLO Primary Filter Binding Gate Design

Date: 2026-05-29

## Context

The latest `r97-link-01` FT run failed after the primary and secondary QEMU
instances reached the COLO convergence boundary:

- primary status: `finish-migrate`
- primary migration: `active`
- primary COLO mode: `none`
- secondary status: `inmigrate`
- secondary migration: `colo`
- secondary COLO mode: `secondary`

The new diagnostics from design 314 narrowed the failure from a generic primary
role transition problem to an incomplete primary filter/chardev binding:

- `mirror0:frontend_closed`
- `compare0:frontend_closed`
- `compare_out0:frontend_closed`

This means the 9000-series TCP paths can be established while QEMU still has
not bound the chardev frontends required by the primary-side `filter-mirror`,
`filter-redirector`, and `colo-compare` chain.

## Principle

The FT protect path must not treat QMP `object-add` success as proof that the
primary COLO datapath is usable. `object-add` only proves that QEMU accepted the
object creation request. Before allowing `cont` and `migrate`, qemu FTCTL must
verify that the primary filter objects have actually opened their required
chardev frontends.

This is still qemu FTCTL responsibility. Cloud and Mold Agent remain outside the
runtime datapath: they can request FT protection and read state/events, but they
must not directly assemble or validate the QEMU COLO datapath.

## Design

After primary `filter-redirector`, `colo-compare`, and `filter-mirror` objects
are attached:

1. Keep the existing TCP channel-path gate.
2. Add a primary filter/chardev binding gate using QMP `query-chardev`.
3. Require the following primary chardev labels to be frontend-open before
   continuing to `migrate`:
   - `mirror0`
   - `compare1`
   - `compare0`
   - `compare0-0`
   - `compare_out`
   - `compare_out0`
4. Retry for a bounded interval to absorb short QEMU binding delays.
5. If any required frontend remains missing or closed:
   - stop before `cont` and `migrate`,
   - set `last_error=primary_filter_chardev_frontend_incomplete`,
   - record `xcolo_primary_filter_chardev_reason`,
   - emit a `primary.filter_chardev_binding` failure event.

## Error Preservation

The block-backed cold-conversion path wraps the low-level handshake. It must not
overwrite a specific filter-binding failure with the generic
`xcolo_block_handshake_failed` error. The outer handler should preserve the
existing `last_error` when one exists.

## Desired Result

The next failed run should fail earlier and more honestly if QEMU still does
not bind the primary COLO chardev frontends. It should no longer spend minutes
in runtime convergence only to report the same root cause after migration has
already been attempted.

If the gate passes but the primary still remains outside COLO mode, the failure
will move forward to the next boundary: primary QEMU accepted the filter
bindings and block graph, but still did not enter the COLO primary role.

## Follow-up Recovery

Design 316 adds rollback for the early handshake failure introduced here. The
binding gate is intentionally early, but it still runs after generated primary
and secondary runtimes exist. Therefore a gate failure must restore the primary
runtime and stop the generated secondary runtime before returning the preserved
error to Cloud.
