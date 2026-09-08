# FT XCOLO Post-Migrate Role Transition Gate Design

Date: 2026-06-10

## Background

Run 109 moved past the previous secondary QEMU memory-region assertion. The
pre-migrate runtime topology gate passed and `primary.migrate` was accepted.
The new failure is:

```text
last_error=xcolo_colo_chardev_contract_not_ready
xcolo_protocol_failure_phase=post_migrate_chardev_contract
```

The failure was raised during post-migrate chardev contract validation when
secondary `query-chardev` became unavailable:

```text
mirror_path_secondary_red0=query_failed
compare_path_secondary_red1=query_failed/query_failed
```

## QEMU 9.2.4 Code Findings

QEMU distinguishes chardev backend connectivity from frontend-open state.

- `query-chardev` reports `frontend-open` from `chr->be && chr->be->fe_is_open`
  in `chardev/char.c`.
- `qemu_chr_fe_set_handlers_full()` toggles `fe_is_open` based on frontend read
  handlers in `chardev/char-fe.c`.
- `qemu_chr_be_event()` tracks socket backend open/closed state separately via
  `be_open`.
- `filter-redirector` output path uses the chardev backend path for writes.
  Therefore `frontend-open=false` on an output chardev is not automatically a
  COLO failure when the backend socket is connected.

QEMU COLO migration also has an explicit role-transition window:

- source migration changes `ACTIVE -> COLO` only after migration completion;
- secondary incoming changes `ACTIVE -> COLO`, starts replication, starts the
  VM, then sends `COLO_MESSAGE_CHECKPOINT_READY`;
- checkpoint exchange starts after those role changes.

Therefore FTCTL must not treat a transient post-`migrate` secondary
`query-chardev` failure as the final COLO failure until the role-transition
window has been observed and retried.

## Design

Add a post-migrate role transition gate before the final chardev contract gate.

The gate repeatedly captures:

- primary/secondary `query-migrate`;
- primary/secondary `query-status`;
- primary/secondary COLO mode;
- primary/secondary `query-chardev`;
- socket snapshots for ports `9003`, `9004`, and `9998`;
- QEMU invalid-message and assertion evidence.

The gate succeeds when:

- no invalid COLO protocol message is observed;
- both QMP endpoints respond;
- primary and secondary migration status reach `active` or `colo`;
- directional chardev contract is ready.

Documented transitional states, such as temporary `query-chardev` failures or
closed output frontends with connected backends, are retried during the
transition window instead of being treated as immediate final failures.

The gate fails only when:

- invalid COLO protocol message is observed;
- migration status becomes `failed`;
- secondary QMP/chardev query remains unavailable for the full transition
  timeout;
- the directional chardev path remains disconnected after the transition
  timeout.

## Runtime State

New or clarified state keys:

```text
xcolo_post_migrate_role_transition_gate=ready|failed
xcolo_post_migrate_role_transition_attempts
xcolo_post_migrate_role_transition_reason
xcolo_post_migrate_role_transition_primary_migrate
xcolo_post_migrate_role_transition_secondary_migrate
xcolo_post_migrate_role_transition_primary_status
xcolo_post_migrate_role_transition_secondary_status
xcolo_chardev_contract_query_transient=yes|no
```

If the transition times out on repeated secondary chardev query failures, use:

```text
xcolo_protocol_failure_phase=post_migrate_role_transition
last_error=xcolo_secondary_chardev_query_unstable_after_migrate
```

If sockets are connected but frontend-open is closed on output chardevs, do not
fail only for that reason. This matches the QEMU 9.2.4 frontend/backend split.

## Non-Goals

This change does not alter:

- generated primary/secondary XML topology;
- RBD stable path policy;
- startup disk graph;
- pre-migrate topology gate;
- COLO filter object order;
- the rule that guest-visible devices must not be hot-plugged dynamically.
