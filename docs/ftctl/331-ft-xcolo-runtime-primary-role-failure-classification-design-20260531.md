# 331. FT X-COLO Runtime Primary Role Failure Classification Design

Date: 2026-05-31

## Context

After design 330, the FT protection run passed the pre-migrate chardev gate and
started the COLO migration path:

```text
primary.migrate ok
primary query-status: finish-migrate
primary query-migrate: active, remaining=0
secondary query-status: inmigrate
secondary query-migrate: colo
secondary query-colo-status: secondary
```

All important transport channels were established:

- mirror channel `9003`: `ESTABLISHED`
- compare peer channel `9004`: `ESTABLISHED`
- migration channel `9998`: `ESTABLISHED`
- NBD channel `10809`: `ESTABLISHED`
- local compare loopback channels `9001` and `9005`: `ESTABLISHED`

The run eventually failed with:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

However, the direct evidence showed that the actual runtime boundary was no
longer "filter graph not built". The secondary had already entered COLO, while
the primary stayed in `finish-migrate` and `query-colo-status mode=none`.

## Problem

Runtime validation still treated primary `query-chardev frontend-open=false` as
a hard failure by itself. That made the final `last_error` point back to
`primary_filter_chardev_frontend_incomplete`, even when:

- generated/runtime XML markers existed,
- primary filter commandline markers existed,
- required TCP channels were established,
- secondary block graph was ready,
- secondary was in COLO mode.

In that state, `frontend-open=false` is useful diagnostic evidence, but it is
not the most accurate top-level failure reason. The failed transition is that
primary QEMU did not enter the COLO primary role.

## Design

Runtime validation uses a topology-ready predicate that does not require primary
chardev `frontend-open=true`:

```bash
ftctl_xcolo_runtime_primary_topology_ready
```

The predicate requires:

- primary filter commandline or QOM topology evidence,
- mirror, compare peer, compare-local, and compare-out channels established,
- secondary block graph ready or not applicable.

It intentionally does not require `xcolo_primary_filter_chardev_ready=yes`.
Chardev frontend state remains recorded in state and events as diagnostic data.

## Failure Ordering

When migration is active and secondary is in COLO, classify failures in this
order:

1. missing QGA when QGA is required,
2. missing primary filter topology,
3. missing 9000-series channel,
4. secondary block graph not ready,
5. primary stuck in `finish-migrate` while secondary is `inmigrate/colo`:
   `primary_finish_migrate_colo_role_not_entered`,
6. generic COLO role pending/convergence timeout.

This prevents a valid-but-closed listener/client frontend from hiding the
more important role-transition failure.

## Expected Evidence

The next equivalent runtime failure should be reported as:

```text
xcolo.runtime_validate fail
reason=primary_finish_migrate_colo_role_not_entered
primary_status=finish-migrate
secondary_status=inmigrate
primary_colo=none
secondary_colo=secondary
primary_migrate=active
secondary_migrate=colo
```

If primary finally reports `query-colo-status mode=primary` and secondary stays
`secondary`, the runtime success path may accept the pair even when listener
frontends still report closed, provided all topology and channel checks are
healthy.

## Relationship To Design 330

Design 330 split pre-migrate chardev validation from strict runtime diagnostics.
This document extends that principle into runtime failure classification:
chardev frontend state is retained as evidence, but the top-level runtime error
must describe the failed COLO role transition when the topology is otherwise
ready.
