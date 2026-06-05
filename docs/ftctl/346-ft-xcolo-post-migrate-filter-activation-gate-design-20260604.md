# FT XCOLO Post-Migrate Filter Activation Gate Design - 2026-06-04

## Superseded Capability Note - 2026-06-05

The `return-path=on` capability references in this document are superseded by
[362. FT XCOLO QEMU 9.2.4 Return-Path Capability Conflict Design](362-ft-xcolo-qemu-924-return-path-capability-conflict-design-20260605.md).
Current QEMU 9.2.4-aligned FTCTL behavior enables `x-colo` and keeps generic
migration `return-path` disabled.

## Background

Run 69 eliminated the checkpoint-delay hypothesis.

The run verified all of these before `primary.migrate`:

- `xcolo_primary_checkpoint_delay_ready=yes`
- `xcolo_primary_checkpoint_delay_expected=2000`
- `xcolo_primary_checkpoint_delay_actual=2000`
- storage symmetry: `ok`
- firewall readiness: `yes`
- channel/socket readiness: `yes`
- primary filter QOM/cmdline/chardev readiness: `yes`

The failure remained:

```text
Primary QEMU:   Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error

xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate
xcolo_primary_migrate_status=failed
xcolo_primary_colo_mode=none
xcolo_secondary_migrate_status=colo
xcolo_secondary_colo_mode=secondary
```

This means the next active hypothesis is no longer another generic
pre-migrate readiness check. The active question is whether the primary filter
activation timing is corrupting or racing the COLO migration stream.

## Design Principle

The XCOLO path must separate:

1. **Topology creation**
2. **Migration stream establishment**
3. **Primary network filter activation**
4. **Steady-state role validation**

The primary network filters must not be activated before `primary.migrate`.

Pre-migrate is allowed to verify that filter objects, chardevs, sockets,
block graph, migration capabilities, checkpoint delay, and firewall contracts
are ready. It must not require the primary filters to be `status=on`.

## Target Runtime Sequence

```text
secondary qmp_capabilities
secondary migrate-set-capabilities
secondary nbd-server-start / nbd-server-add

primary qmp_capabilities
primary block graph / NBD client setup
primary stop
primary filter topology present with status=off
primary migrate-set-capabilities return-path=off,x-colo=on
primary migrate-set-parameters x-checkpoint-delay=<value>
primary pre-migrate evidence capture with filter status=off
primary firewall/socket preflight

primary migrate tcp:<secondary>:9998

post-migrate pre-activation gate:
  primary migrate status
  secondary migrate status
  primary colo mode
  secondary colo mode
  primary QEMU invalid-message check
  secondary QEMU input/output check
  socket snapshot

activate primary filters:
  redire1 status=on
  m0 status=on
  redire0 status=on

post-activation gate:
  primary migrate status
  secondary migrate status
  primary/secondary colo mode
  QEMU invalid-message check
  socket snapshot

steady-state gate:
  primary colo mode=primary
  secondary colo mode=secondary
```

## Failure Classification

The code must record where the protocol stream fails:

- `xcolo_migrate_stream_failed_before_filter_activation`
  - primary `migrate` was accepted
  - primary QEMU reports `Received invalid message ...`
  - primary filters were still `status=off`
- `xcolo_filter_activation_broke_colo_stream`
  - no invalid message before filter activation
  - invalid message appears after filters are switched to `status=on`
- `xcolo_primary_role_transition_stalled`
  - no invalid message
  - primary does not enter `colo_mode=primary` before timeout
- `xcolo_post_migrate_filter_activation_failed`
  - a QMP `qom-set status=on` command fails
  - or QOM verification does not show all filters `status=on`

## Required State Keys

The next run must expose:

- `xcolo_primary_filter_activation_stage=post_migrate`
- `xcolo_primary_filter_status_pre_migrate=off`
- `xcolo_primary_filter_status_pre_activation=off`
- `xcolo_primary_filter_status_post_activation=on`
- `xcolo_post_migrate_pre_activation_primary_migrate_status`
- `xcolo_post_migrate_pre_activation_secondary_migrate_status`
- `xcolo_post_migrate_pre_activation_primary_colo_mode`
- `xcolo_post_migrate_pre_activation_secondary_colo_mode`
- `xcolo_post_migrate_pre_activation_invalid_message`
- `xcolo_post_migrate_post_activation_invalid_message`
- `xcolo_protocol_failure_phase`

## Repetition Control

If the next run again reports:

```text
Primary QEMU: Received invalid message 0x0000 length 0x0000
```

then it is progress only if `xcolo_protocol_failure_phase` tells whether the
failure happened before or after filter activation.

If the same failure is observed without that phase split, the implementation is
considered incomplete and must not continue cycling through checkpoint,
firewall, storage, or generic readiness changes.

## Supersedes

This design extends:

- [345. FT XCOLO Pre-Migrate Checkpoint Hard Gate Design](345-ft-xcolo-premigrate-checkpoint-hard-gate-design-20260604.md)

The checkpoint hard gate remains valid, but it is no longer the active cause.

## Extension

The activation boundary in this document remains valid, but the original bulk
activation direction was refined after Run 70. The concrete activation order is
now defined by:

- [347. FT XCOLO Staged Filter Activation Order Design](347-ft-xcolo-staged-filter-activation-order-design-20260604.md)

The effective order is `redire1 -> m0 -> redire0`, with a diagnostic gate after
each step.
