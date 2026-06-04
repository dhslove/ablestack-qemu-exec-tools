# FT XCOLO Pre-Redire1 Activation Gate Design - 2026-06-04

> Superseded note: Run 72 disproved the strict wait requirement in this
> document. The current design is the fast cached gate in
> [349. FT XCOLO Fast Redire1 Activation Gate Design](349-ft-xcolo-fast-redire1-activation-gate-design-20260604.md).
> Keep this document as the historical design that led to Run 72 evidence.

## Background

Run 71 proved that the staged activation classifier works.

The post-migrate stream was valid before any primary filter was activated:

- `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
- `xcolo_post_migrate_pre_activation_secondary_migrate_status=active`
- `xcolo_post_migrate_pre_activation_invalid_message=no`
- `xcolo_socket_post_migrate_pre_activation_primary_9998=established`

The first activation step broke the stream:

- `xcolo_filter_activation_failed_step=redire1`
- `xcolo_protocol_failure_phase=filter_activation_redire1`
- `xcolo_filter_activation_redire1_primary_migrate_status=failed`
- `xcolo_filter_activation_redire1_secondary_migrate_status=colo`
- `xcolo_filter_activation_redire1_primary_migrate_error_desc=Received invalid message 0x0000 length 0x0000`

The active hypothesis is now narrower than filter activation ordering. The
problem is the readiness boundary for `redire1`, the RX redirector that forwards
primary RX packets into the compare input path.

## Design Principle

`redire1` must not be switched on just because the migration stream is open.
It should be enabled only when the receiving COLO/compare side is already in a
state that can consume primary RX packets without corrupting the COLO migration
protocol.

The implementation should prefer a controlled prerequisite failure over a QEMU
protocol failure. If the prerequisite is not met, it must not activate
`redire1`.

## Pre-Redire1 Gate

Before `qom-set /objects/redire1 status=on`, the code must wait for:

- primary migrate status: `active`
- secondary migrate status: `colo`
- secondary COLO mode: `secondary`
- no primary invalid-message error
- primary compare channels strictly ready:
  - mirror channel established
  - compare peer channel established
  - compare local loopback established
  - compare output loopback established
- primary chardev binding strictly ready:
  - `mirror0=yes`
  - `compare1=yes`
  - `compare0=yes`
  - `compare0-0=yes`
  - `compare_out=yes`
  - `compare_out0=yes`

The pre-migrate relaxed `accepted_closed` state is not sufficient for this
gate. It is valid before migration, but not valid immediately before redirecting
primary RX packets into the compare path.

## Required State Keys

The gate must record:

- `xcolo_pre_redire1_gate=ready|timeout|failed`
- `xcolo_pre_redire1_gate_attempts`
- `xcolo_pre_redire1_primary_migrate_status`
- `xcolo_pre_redire1_secondary_migrate_status`
- `xcolo_pre_redire1_primary_colo_mode`
- `xcolo_pre_redire1_secondary_colo_mode`
- `xcolo_pre_redire1_invalid_message`
- `xcolo_pre_redire1_chardev_ready`
- `xcolo_pre_redire1_chardev_reason`
- `xcolo_pre_redire1_channel_mirror_established`
- `xcolo_pre_redire1_channel_compare_established`
- `xcolo_pre_redire1_channel_compare_local_established`
- `xcolo_pre_redire1_channel_compare_out_established`
- `xcolo_pre_redire1_gate_reason`

When the gate fails:

- `xcolo_protocol_failure_phase=pre_redire1_gate`
- `xcolo_filter_activation_failed_step=redire1`
- `last_error=xcolo_redire1_activation_prerequisite_timeout`

If an invalid-message is already present before `redire1`, use:

- `last_error=xcolo_redire1_activation_prerequisite_failed`
- `xcolo_pre_redire1_gate_reason=invalid_message_before_redire1`

## Repetition Control

If the next run fails before `redire1`, it is progress only if the gate reason
identifies which prerequisite was missing. That result must not be treated as
the same `Received invalid message` loop.

If the gate passes and `redire1` still breaks the stream, the next active
hypothesis becomes the topology of `redire1 outdev=compare0` itself rather than
timing/readiness.

## Supersedes

This document extends:

- [347. FT XCOLO Staged Filter Activation Order Design](347-ft-xcolo-staged-filter-activation-order-design-20260604.md)

The staged order remains `redire1 -> m0 -> redire0`, but `redire1` now has a
strict pre-activation gate.

## Superseded By Run 72

Run 72 showed that waiting for secondary migrate status `colo` and strict
chardev readiness before `redire1` can let the COLO stream fail before any
filter is activated. The effective successor design is 349, which validates the
cached post-migrate pre-activation state and enables `redire1` without a fresh
polling wait.
