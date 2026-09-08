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
2. Add a primary filter/chardev binding observation using QMP `query-chardev`.
3. Observe the following primary chardev labels before continuing to `migrate`:
   - `mirror0`
   - `compare1`
   - `compare0`
   - `compare0-0`
   - `compare_out`
   - `compare_out0`
4. Retry for a bounded interval to absorb short QEMU binding delays.
5. If all frontends are open, emit a `primary.filter_chardev_binding` ok event.
6. If some filter-facing frontends remain missing or closed before `cont`,
   preserve the reason and emit a `primary.filter_chardev_binding` defer event.
   Do not set `last_error` at this boundary. Design 317 supersedes the original
   hard-gate behavior because QEMU can defer opening some packet-filter
   frontends until after `cont` and migration setup.

## Error Preservation

The block-backed cold-conversion path wraps the low-level handshake. It must not
overwrite a specific runtime or migration failure with the generic
`xcolo_block_handshake_failed` error. The outer handler should preserve the
existing `last_error` when one exists.

## Desired Result

The next failed run should not stop merely because pre-`cont` packet-filter
frontends are not open. It should move forward to `cont`, migration setup, and
runtime validation. If QEMU still cannot bind the filter path, the failure will
be reported with runtime evidence rather than as a premature pre-`cont`
assertion.

## Follow-up Recovery

Design 316 adds rollback for handshake failures after generated primary and
secondary runtimes exist.

Design 317 changes this boundary from a hard pre-`cont` gate into an observation
because the next retest showed that QEMU may keep `mirror0`, `compare0`, and
`compare_out0` frontends closed until later runtime progress. Runtime validation
remains the hard failure boundary.
