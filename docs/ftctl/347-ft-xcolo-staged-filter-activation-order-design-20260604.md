# FT XCOLO Staged Filter Activation Order Design - 2026-06-04

## Background

Run 70 proved that the COLO stream survives through `primary.migrate` and the
post-migrate pre-activation gate:

- primary migrate status: `active`
- secondary migrate status: `active`
- primary filter status: `off`
- invalid COLO message: `no`
- migration socket: `established`

The stream failed only after the primary network filters were switched to
`status=on` as one block. The repeated QEMU messages remained:

```text
Primary QEMU: Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```

This means checkpoint delay, storage symmetry, firewall preflight, socket
reachability, and pre-activation migration establishment are not the current
active hypotheses. The active hypothesis is the primary x-colo filter activation
semantics after migration.

## Design Principle

The x-colo primary network filter topology must be activated in a controlled
order that keeps packet paths coherent while the migration stream is already
active.

The implementation must also expose the exact activation step that breaks COLO.
If the same invalid-message error appears again, it must be tied to one of the
filter activation steps rather than reported as a generic post-activation
failure.

## Target Activation Order

The previous activation order was:

```text
redire0 -> redire1 -> m0
```

That order enables the compare-output return path first. In this environment it
can route traffic back into the primary RX path before the compare input and TX
mirror paths are both stable.

The new activation order is:

```text
redire1 -> m0 -> redire0
```

Step meaning:

- `redire1`: primary RX to compare input
- `m0`: primary TX mirror to secondary
- `redire0`: compare output back to primary RX

The return path is intentionally enabled last.

## Runtime Sequence

```text
post-migrate pre-activation gate
  verify primary migrate stream active
  verify secondary migrate stream active or colo
  verify invalid-message is absent
  verify primary filters are off

activate redire1
  qom-set /objects/redire1 status=on
  capture primary/secondary migrate status
  capture primary/secondary colo mode
  capture invalid-message state
  capture socket snapshot

activate m0
  qom-set /objects/m0 status=on
  capture primary/secondary migrate status
  capture primary/secondary colo mode
  capture invalid-message state
  capture socket snapshot

activate redire0
  qom-set /objects/redire0 status=on
  capture primary/secondary migrate status
  capture primary/secondary colo mode
  capture invalid-message state
  capture socket snapshot

post-activation gate
  verify all primary filters are on
  verify invalid-message is absent
  continue to steady-state role validation
```

## Required State Keys

The implementation must record:

- `xcolo_primary_net_filters_activation_order=redire1,m0,redire0`
- `xcolo_filter_activation_step`
- `xcolo_filter_activation_failed_step`
- `xcolo_filter_activation_<step>_primary_migrate_status`
- `xcolo_filter_activation_<step>_secondary_migrate_status`
- `xcolo_filter_activation_<step>_primary_colo_mode`
- `xcolo_filter_activation_<step>_secondary_colo_mode`
- `xcolo_filter_activation_<step>_primary_migrate_error_desc`
- `xcolo_filter_activation_<step>_secondary_migrate_error_desc`
- `xcolo_filter_activation_<step>_invalid_message`
- `xcolo_protocol_failure_phase=filter_activation_<step>`

where `<step>` is one of `redire1`, `m0`, or `redire0`.

## Failure Classification

If a QMP `qom-set` fails:

- `xcolo_filter_activation_failed_step=<step>`
- `xcolo_primary_filter_activation_failed_reason=<step>_qom_set_failed`
- `last_error=primary_filter_activation_failed`

If the invalid-message protocol failure appears immediately after a step:

- `xcolo_filter_activation_failed_step=<step>`
- `xcolo_protocol_failure_phase=filter_activation_<step>`
- `last_error=xcolo_filter_activation_<step>_broke_colo_stream`

If all steps succeed but the final all-on QOM validation fails:

- `xcolo_protocol_failure_phase=filter_activation_post_verify`
- `last_error=xcolo_post_migrate_filter_activation_failed`

## Repetition Control

If the next run again reports:

```text
Received invalid message 0x0000 length 0x0000
```

then it is useful progress only if the evidence identifies the failed activation
step. A result without `xcolo_filter_activation_failed_step` is incomplete.

The next diagnosis must not return to storage, firewall, checkpoint-delay, or
generic socket preconditions unless the new per-step evidence shows those
previously verified conditions regressed.

## Supersedes

This document extends and narrows:

- [346. FT XCOLO Post-Migrate Filter Activation Gate Design](346-ft-xcolo-post-migrate-filter-activation-gate-design-20260604.md)

Document 346 remains valid for the post-migrate activation boundary, but its
bulk activation order is superseded by the staged order defined here.
