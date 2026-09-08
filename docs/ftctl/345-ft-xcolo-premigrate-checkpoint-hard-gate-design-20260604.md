# FT XCOLO Pre-Migrate Checkpoint Hard Gate Design - 2026-06-04

## Superseded Capability Note - 2026-06-05

The capability line in the sequence below is superseded by
[362. FT XCOLO QEMU 9.2.4 Return-Path Capability Conflict Design](362-ft-xcolo-qemu-924-return-path-capability-conflict-design-20260605.md).
The current expected sequence is `return-path=off,x-colo=on`.

## Background

Run 68 confirmed the Run 67 failure is a repeated QEMU COLO protocol-role
blocker, not another storage, firewall, socket, baseline seed, secondary RBD
mapping, or generic filter readiness failure.

The new steady-state classifier recorded:

```text
xcolo_handshake_command_state=accepted
xcolo_steady_state_gate=failed
xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate
xcolo_primary_migrate_status=failed
xcolo_secondary_migrate_status=colo
xcolo_primary_colo_mode=none
xcolo_secondary_colo_mode=secondary
```

This means the primary accepted the migrate command path, but did not enter the
COLO primary role.

## Corrected Principle

`x-checkpoint-delay` is no longer treated as an optional post-start tuning
command for the ABLESTACK FT validation path.

For the local qemu-ablestack COLO runtime, the primary migration preconditions
must include a verified checkpoint delay before `primary.migrate` is issued.

The corrected primary sequence is:

```text
primary qmp_capabilities
primary block graph / NBD client setup
primary network filter topology and chardev gate
primary migrate-set-capabilities return-path=off,x-colo=on
primary migrate-set-parameters x-checkpoint-delay=<value>
primary query-migrate-parameters verifies x-checkpoint-delay=<value>
primary pre-migrate evidence capture
primary firewall/socket gates
primary migrate tcp:<secondary>:9998
```

## Behavior

qemu FTCTL must:

1. Read `FTCTL_PROFILE_XCOLO_CHECKPOINT_DELAY`.
2. If unset, keep the legacy no-op behavior.
3. If set to a positive integer, execute
   `migrate-set-parameters x-checkpoint-delay=<value>` before primary migrate.
4. Query `query-migrate-parameters`.
5. Continue only when the actual `x-checkpoint-delay` equals the expected value.
6. Record:
   - `xcolo_primary_checkpoint_delay_expected`
   - `xcolo_primary_checkpoint_delay_actual`
   - `xcolo_primary_checkpoint_delay_ready=yes|no`
   - `xcolo_primary_checkpoint_delay_pre_migrate`
   - `xcolo_premigrate_primary_checkpoint_delay_ready`
7. If set or verification fails, stop before `primary.migrate` with:
   - `last_error=primary_checkpoint_parameter_set_failed`

After successful steady-state validation, qemu FTCTL may re-read the value and
log a warning if it drifted, but it must not re-issue the tuning command as the
normal success path.

## Repetition Control

The next retest is progress if one of these happens:

- `primary.migrate` is blocked before execution with a checkpoint-specific
  error, proving a concrete precondition failure;
- the pair reaches `xcolo_steady_state_gate=ok`;
- the failure still reaches `xcolo_steady_state_gate=failed`, but now records
  `xcolo_primary_checkpoint_delay_ready=yes`.

If the last case occurs together with:

```text
last_error=xcolo_repeated_protocol_invalid_message
xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate
```

then checkpoint setup is no longer an active hypothesis. The next improvement
must move to QEMU COLO role-transition timing, especially filter activation
timing around the primary migrate connection.

## Superseded Design

This design supersedes the checkpoint portion of
[320. FT X-COLO QEMU Procedure Alignment And Checkpoint Defer Design](320-ft-xcolo-qemu-procedure-alignment-and-checkpoint-defer-design-20260530.md).

The official minimal QEMU example was useful for initial procedure alignment,
but the ABLESTACK FT validation evidence now requires a local hard gate before
primary migrate.
