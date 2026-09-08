# FT XCOLO Steady-State Gate And Protocol Subreason Design - 2026-06-04

## Background

Run 67 for `r97-link-01` fixed the previous cloud-managed RBD runtime mapping
blocker and reached the COLO runtime path:

- both baseline seed copies completed;
- secondary runtime RBD mappings were prepared;
- secondary transient domain started;
- `primary.migrate` returned `ok`;
- `block_conversion.handshake` returned `ok`;
- firewall, socket, storage symmetry, pre-migrate filter, chardev, and channel
  evidence were all ready.

The terminal failure repeated the known protocol signature:

```text
Primary QEMU:   Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```

The runtime state showed:

```text
xcolo_primary_migrate_status=failed
xcolo_secondary_migrate_status=colo
xcolo_primary_colo_mode=none
xcolo_secondary_colo_mode=secondary
```

This means the `migrate` command was accepted, but the pair did not reach the
required steady state where the primary reports COLO primary role and the
secondary reports COLO secondary role.

## Principle

`block_conversion.handshake=ok` must mean only that the QMP commands were
accepted. It must not be interpreted as FT protection success.

FT success is gated by an explicit post-migrate steady-state check:

- primary migration status is active;
- secondary migration status is colo;
- primary COLO mode is primary;
- secondary COLO mode is secondary;
- primary/secondary runtime XML markers are present;
- primary filter topology and chardev bindings are ready;
- required channels and secondary block graph are ready.

## Design

Add a dedicated steady-state gate after the block conversion handshake:

- emit `block_conversion.steady_state_gate=start` immediately after the
  handshake command path;
- emit `block_conversion.steady_state_gate=ok` only after runtime validation
  proves both COLO roles are active;
- emit `block_conversion.steady_state_gate=pending` when the pair is still in a
  bounded convergence window;
- emit `block_conversion.steady_state_gate=fail` when runtime validation
  produces a terminal error.

Persist state:

- `xcolo_handshake_command_state=accepted`
- `xcolo_steady_state_gate=pending|ok|failed`
- `xcolo_protocol_steady_state_required=true`

When the repeated invalid-message signature appears after all pre-migrate
evidence is ready, preserve the stable top-level error:

```text
last_error=xcolo_repeated_protocol_invalid_message
```

Also persist a subreason:

```text
xcolo_protocol_invalid_message_reason=<reason>
xcolo_protocol_invalid_message_scope=post_migrate_steady_state
```

Supported subreasons:

- `firewall_not_ready`
- `storage_symmetry_not_ok`
- `premigrate_chardev_not_ready`
- `premigrate_filter_topology_not_ready`
- `runtime_channel_not_ready`
- `secondary_block_graph_not_ready`
- `runtime_socket_snapshot_missing`
- `primary_role_not_entered_after_migrate`
- `qemu_colo_protocol_invalid_message`

For Run 67 evidence the expected subreason is:

```text
xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate
```

## Repetition Control

The next test is progress only if it changes one of these facts:

- the pair reaches `xcolo_steady_state_gate=ok`;
- the failure moves to a new earlier gate with a specific missing precondition;
- the protocol subreason changes and identifies a new concrete blocker.

If the next run again reports:

```text
last_error=xcolo_repeated_protocol_invalid_message
xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate
```

with firewall, socket, storage, filter, chardev, and block graph evidence still
ready, it must be reported as the same repeated protocol-role blocker. Do not
continue another generic filter-order or storage-selection iteration without a
new QEMU-level hypothesis.

## Non-Goals

- Do not change Cloud lifecycle ownership.
- Do not change DR/HA behavior.
- Do not treat command acceptance as success.
- Do not suppress QEMU logs or rollback behavior.
