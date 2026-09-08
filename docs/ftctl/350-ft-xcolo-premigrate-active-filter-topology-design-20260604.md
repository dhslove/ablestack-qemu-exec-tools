# FT XCOLO Premigrate Active Filter Topology Design - 2026-06-04

## Background

Run 73 reached the first post-migrate filter activation step and failed exactly
when `redire1` was enabled:

- `xcolo_pre_redire1_gate=ready`
- `primary.filter_status_on.redire1` was issued
- `xcolo_protocol_failure_phase=filter_activation_redire1`
- primary QEMU reported `Received invalid message 0x0000 length 0x0000`
- secondary QEMU reported `Can't receive COLO message: Input/output error`

This proves the remaining failure is not another wait-loop or readiness gate
problem. The repeated QEMU protocol signature is now tied to changing the
primary network filter path after `primary.migrate` has already started the
COLO session.

## QEMU COLO Alignment

The QEMU COLO procedure defines the primary network filter topology before
starting migration. The primary command line contains the active objects:

- `filter-mirror m0`
- `filter-redirector redire0`
- `filter-redirector redire1`
- `colo-compare comp0`

The secondary also starts with its redirector/rewriter topology present. After
both sides are ready, `migrate` starts the COLO session. The `migrate` command is
the COLO runtime synchronization control path; it must not be used first and
then followed by a mid-stream RX filter insertion.

## Design Principle

For cloud-managed cold conversion, FTCTL must start the generated primary and
secondary runtimes with a complete COLO network topology already active.

Therefore:

- generated primary QEMU args must not include `status=off` for `m0`,
  `redire0`, or `redire1`
- QMP fallback object creation must create filters active by default, not as
  dormant filters later enabled by `qom-set`
- pre-migrate validation must require primary filter QOM status `on`
- `primary.migrate` must be issued only after active filter topology validation
- post-migrate handling must validate the already-active topology and must not
  call `qom-set status=on`

## Implementation Contract

### Startup Args

`ftctl_xcolo_build_primary_qemu_args` builds:

- primary chardev socket topology
- active `filter-mirror`
- active `filter-redirector redire0`
- active `filter-redirector redire1`
- active `colo-compare`

The generated command line omits `status=off`. This follows QEMU's documented
examples and lets QEMU use the default active filter state.

### QMP Fallback

The fallback paths remain available for non-generated or repair scenarios, but
they must follow the same contract:

- add the filter objects active by default
- verify QOM status `on`
- set `xcolo_primary_net_filters_activation_mode=startup-active`
- never rely on post-migrate staged activation for the normal initial enable
  path

### Post-Migrate Validation

`ftctl_xcolo_activate_primary_filters_after_migrate` becomes a compatibility
wrapper that validates the active topology after `primary.migrate`. It records:

- `xcolo_primary_filter_activation_stage=premigrate_active`
- `xcolo_primary_filter_status_pre_migrate=on`
- `xcolo_primary_filter_status_post_migrate=on`
- `xcolo_primary_net_filters_activated=true`
- `xcolo_primary_net_filters_activation_mode=startup-active`

It must not emit:

- `primary.filter_status_on.redire1`
- `primary.filter_status_on.m0`
- `primary.filter_status_on.redire0`

## Repetition Control

The next run must show one of these outcomes:

1. No `primary.filter_status_on.*` events occur and the COLO stream progresses
   beyond the previous `redire1` activation boundary. This is progress.
2. The same QEMU protocol signature occurs without post-migrate qom-set. Then
   the active hypothesis moves from activation timing to concrete topology:
   chardev direction, compare in/out wiring, or QEMU-side COLO commandline
   semantics.
3. The failure occurs before `primary.migrate`. Then this change did not reach
   its intended boundary and pre-migrate active topology validation keys must be
   inspected first.

## Supersedes

This design supersedes the normal-path staged post-migrate activation
assumption in:

- [348. FT XCOLO Pre-Redire1 Activation Gate Design](348-ft-xcolo-pre-redire1-activation-gate-design-20260604.md)
- [349. FT XCOLO Fast Redire1 Activation Gate Design](349-ft-xcolo-fast-redire1-activation-gate-design-20260604.md)

Those gates remain useful only as historical diagnostics or for an explicitly
separate dormant-filter repair path. They are no longer the normal
cloud-managed FT enable path.
