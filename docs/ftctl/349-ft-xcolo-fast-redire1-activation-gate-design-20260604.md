# FT XCOLO Fast Redire1 Activation Gate Design - 2026-06-04

## Background

Run 72 disproved the strict pre-redire1 wait model from design 348.

The post-migrate pre-activation snapshot was still valid:

- `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
- `xcolo_post_migrate_pre_activation_secondary_migrate_status=active`
- `xcolo_post_migrate_pre_activation_invalid_message=no`
- `xcolo_socket_post_migrate_pre_activation_primary_9998=established`

But the strict pre-redire1 gate waited until secondary migration reported
`colo`. During that wait the primary migration stream failed before
`redire1` was activated:

- no event showed `primary.filter_status_on.redire1`
- `xcolo_pre_redire1_gate_reason=invalid_message_before_redire1`
- primary QEMU reported `Received invalid message 0x0000 length 0x0000`
- secondary QEMU reported `Can't receive COLO message: Input/output error`

This means delaying `redire1` until secondary `colo` is not a safe readiness
strategy. The system enters an unsupported transition window where migration is
active but the primary RX compare path is still disabled.

## Design Principle

The redire1 gate is not a polling wait. It is a fast validation of the
immediately preceding post-migrate pre-activation evidence.

The implementation must activate `redire1` while the cached state still shows a
valid stream:

- primary migrate status is `active`
- secondary migrate status is `active` or `colo`
- no invalid-message has been observed
- COLO channel sockets are already established

The gate must not re-query migrate status, wait for secondary `colo`, or require
strict chardev frontend readiness before `redire1`. With filters still
`status=off`, frontend chardevs can legitimately appear closed; strict chardev
readiness remains a post-activation validation signal.

## Gate Behavior

Before `qom-set /objects/redire1 status=on`, read only the cached
`xcolo_post_migrate_pre_activation_*` state produced by the previous gate.

Allow activation when:

- `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
- `xcolo_post_migrate_pre_activation_secondary_migrate_status=active|colo`
- `xcolo_post_migrate_pre_activation_invalid_message=no`
- `xcolo_channel_mirror_established=yes`
- `xcolo_channel_compare_established=yes`
- `xcolo_channel_compare_local_established=yes`
- `xcolo_channel_compare_out_established=yes`

Reject activation immediately when any cached prerequisite is missing. Do not
sleep and retry in this gate; a retry here would only make the cached transition
window stale.

## Required State Keys

The gate records:

- `xcolo_pre_redire1_gate=ready|failed`
- `xcolo_pre_redire1_gate_mode=fast_cached_post_migrate`
- `xcolo_pre_redire1_gate_attempts=1`
- `xcolo_pre_redire1_primary_migrate_status`
- `xcolo_pre_redire1_secondary_migrate_status`
- `xcolo_pre_redire1_primary_colo_mode`
- `xcolo_pre_redire1_secondary_colo_mode`
- `xcolo_pre_redire1_invalid_message`
- `xcolo_pre_redire1_strict_chardev_deferred=yes`
- `xcolo_pre_redire1_chardev_ready`
- `xcolo_pre_redire1_chardev_reason`
- `xcolo_pre_redire1_channel_mirror_established`
- `xcolo_pre_redire1_channel_compare_established`
- `xcolo_pre_redire1_channel_compare_local_established`
- `xcolo_pre_redire1_channel_compare_out_established`
- `xcolo_pre_redire1_gate_reason`

When the fast gate fails:

- `xcolo_protocol_failure_phase=pre_redire1_fast_gate`
- `xcolo_filter_activation_failed_step=redire1`
- `last_error=xcolo_redire1_fast_activation_prerequisite_failed`

## Repetition Control

If the next run fails with the same primary and secondary QEMU messages, the
first question is whether `primary.filter_status_on.redire1` was issued:

- If it was not issued, this design did not reach its intended activation
  point and the cached prerequisite state must be inspected.
- If it was issued and the stream still fails at `redire1`, the repeated error
  is no longer a timing/wait problem. The next design target must be the
  `redire1` topology or compare channel direction itself.

## Supersedes

This document supersedes the strict wait requirement in:

- [348. FT XCOLO Pre-Redire1 Activation Gate Design](348-ft-xcolo-pre-redire1-activation-gate-design-20260604.md)

The staged activation order remains:

1. `redire1`
2. `m0`
3. `redire0`

## Superseded By Active Startup Topology

Run 73 proved that the fast gate reached `redire1` and that the COLO stream
failed at the first post-migrate filter activation. Therefore the normal
cloud-managed enable path no longer uses this staged activation model.

[350. FT XCOLO Premigrate Active Filter Topology Design](350-ft-xcolo-premigrate-active-filter-topology-design-20260604.md)
supersedes this document for the normal path. The primary and secondary network
filter topology must be active before `primary.migrate`; post-migrate
`qom-set status=on` is retained only as historical diagnostic context or a
separate dormant-filter repair experiment.
