# FT xCOLO Primary Role Activation Preflight Design - 2026-05-31

## Superseded Capability Note - 2026-06-05

The migration capability contract in this document is superseded by
[362. FT XCOLO QEMU 9.2.4 Return-Path Capability Conflict Design](362-ft-xcolo-qemu-924-return-path-capability-conflict-design-20260605.md).

Current FTCTL behavior must enable `x-colo` and must not enable the generic
migration `return-path` capability for COLO.

## Context

The previous success-gate change correctly stopped FT from being reported as
`colo_running/mirroring` when QEMU had not entered a real COLO role pair. The
next run reached:

```text
primary query-status=finish-migrate
primary query-migrate=active
primary query-colo-status=none
secondary query-status=inmigrate
secondary query-migrate=colo
secondary query-colo-status=secondary
transport_state=activation_stalled
```

Secondary block graph construction and the 9000-series transport channels were
valid. The remaining failure is primary-side COLO role activation.

The primary runtime state also recorded:

```text
xcolo_primary_filter_chardev_ready=no
xcolo_primary_filter_chardev_reason=mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed
```

That means the generated command line contains the required COLO filter
objects, but the filter-facing chardev frontends are not actually bound in the
running QEMU process.

## Principle

`qemu:commandline` presence is only a topology declaration. It is not enough to
prove primary COLO readiness.

FT success requires a runtime role pair:

- primary QEMU reports COLO mode `primary`
- secondary QEMU reports COLO mode `secondary`
- primary migration remains `active`
- secondary migration is `colo`
- primary filter chardev frontends are open
- primary/secondary block graph checks pass
- transport channels are established

If primary filter chardev frontends remain closed after the activation window,
the failure must be classified as `primary_filter_chardev_frontend_incomplete`,
not as a generic `activation_stalled`.

## Design

### Migration Capability Verification

Every xCOLO startup path must use a single helper for:

1. `migrate-set-capabilities return-path=false,x-colo=true`
2. `query-migrate-capabilities`
3. state/event recording for `x-colo` and `return-path`

This applies to both primary and secondary roles before `migrate` is issued.

### Primary Chardev Runtime Gate

Runtime validation must collect `query-chardev` on each validation pass and
record:

```text
xcolo_primary_filter_chardev_ready=yes|no|unknown
xcolo_primary_filter_chardev_reason=<reason>
xcolo_primary_chardev_<label>=yes|no|missing|unknown
```

The success gate requires `xcolo_primary_filter_chardev_ready=yes`.

### Candidate Gate

`colo_established_candidate` is valid only if the primary filter chardev
frontends are ready. If they are closed, the state is not a candidate; it is an
activation failure waiting for the observation window to expire.

### Failure Classification

When primary/secondary migration reaches the COLO handshake shape but the
primary role does not become `primary`:

- if primary filter chardev frontends are closed:
  `primary_filter_chardev_frontend_incomplete`
- if migration capabilities are missing:
  `primary_colo_capability_missing`
- if generic migration return-path is enabled:
  `xcolo_migration_return_path_conflict`
- otherwise:
  `primary_qemu_colo_role_transition_failed`

The resulting state is an error state, not `colo_running`.

## Expected Result

The next run should either:

- reach a real `primary/secondary` COLO role pair and become
  `colo_running/mirroring`, or
- fail with `xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete`
  if the primary QEMU process still leaves COLO filter chardev frontends closed.
