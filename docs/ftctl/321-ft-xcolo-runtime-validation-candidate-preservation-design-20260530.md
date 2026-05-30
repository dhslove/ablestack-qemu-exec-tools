# 321. FT X-COLO Runtime Validation Candidate Preservation Design

Date: 2026-05-30

## Context

The retest after design 320 still failed with:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

The failure evidence changed the problem boundary. The following were verified:

- generated primary XML was active,
- primary QEMU command line matched the official QEMU COLO filter direction,
- primary filter QOM objects existed,
- primary filter QOM properties were correct:
  - `status=on`
  - `insert=behind`
  - `position=tail`
  - `m0 outdev=mirror0`
  - `redire0 indev=compare_out`
  - `redire1 outdev=compare0`
  - `comp0 primary_in=compare0-0`
  - `comp0 secondary_in=compare1`
  - `comp0 outdev=compare_out0`
- primary migration stayed `active`,
- secondary migration stayed `colo`,
- secondary COLO mode stayed `secondary`.

Only `query-chardev` still reported some primary filter-facing chardev
frontends as closed:

```text
mirror0=false
compare0=false
compare_out0=false
red1=false on secondary
```

The current implementation treats that as a hard configuration failure after
the pending window and immediately destroys/recreates the runtime. That makes
the validation too eager: QOM shows the filters are inserted and enabled, while
the chardev frontend state may remain closed until QEMU actually advances the
COLO role/checkpoint path.

## Principles

1. `frontend-open=false` is not, by itself, proof of an invalid COLO topology.
2. QOM filter health is the stronger topology signal:
   `status=on`, `insert=behind`, and `position=tail` must be treated as a
   valid runtime candidate when migration is still alive.
3. Runtime recovery must be reserved for hard failures such as QMP command
   failure, missing QOM objects, invalid filter properties, failed migration,
   or process loss.
4. A candidate runtime should be preserved long enough for operators and
   diagnostics to observe the live COLO state instead of being destroyed by the
   first validation timeout.

## Design

### QOM Filter Health Gate

Add a live QOM health collector for the primary filter chain. It validates:

```text
m0:      netdev=hostnet0, queue=tx, outdev=mirror0, status=on, insert=behind, position=tail
redire0: netdev=hostnet0, queue=rx, indev=compare_out, outdev="", status=on, insert=behind, position=tail
redire1: netdev=hostnet0, queue=rx, indev="", outdev=compare0, status=on, insert=behind, position=tail
comp0:   primary_in=compare0-0, secondary_in=compare1, outdev=compare_out0, iothread=iothread1
```

The collector stores:

```text
xcolo_primary_filter_qom_ready=yes|no
xcolo_primary_filter_qom_reason=<comma-separated detail>
```

and records every checked property in the runtime state file.

### Pending Preservation

When all of the following are true:

- primary XML markers are present,
- secondary XML markers are present,
- primary migration is `active`,
- secondary migration is `colo`,
- primary filter QOM health is `yes`,
- 9000-series channel paths are established,

then validation must return pending (`rc=10`) even if `query-chardev` still
reports closed frontends.

The pending reason becomes:

```text
colo_established_candidate
```

This preserves the primary/secondary runtime for further observation instead of
triggering runtime recovery.

### Hard Failure Conditions

The runtime should still fail immediately when a hard failure is observed:

- primary migration status is `failed`,
- secondary migration status is `failed`,
- QOM filter health is `no`,
- required channel paths are not established after the pending window,
- primary or secondary XML markers are missing,
- secondary is not in COLO migration,
- required QGA policy is not satisfied.

## Expected Result

The next retest should no longer destroy the runtime solely because
`mirror0`, `compare0`, `compare_out0`, or `red1` still report
`frontend-open=false`.

If QOM and migration remain healthy, the UI/backend state should stay in a
pending/converging state and the runtime should remain available for manual
QMP inspection. If the runtime later fails for a hard reason, the error should
name that hard reason instead of `primary_filter_chardev_frontend_incomplete`.
