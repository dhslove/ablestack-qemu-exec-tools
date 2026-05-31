# 330. FT X-COLO Pre-Migrate Chardev Topology-Aware Gate Design

Date: 2026-05-31

## Context

After design 329, the FT protection run passed the pre-migrate 9000-series
channel gate:

```text
primary.channel_paths result=ok mode=pre_migrate mirror_listen=yes compare_listen=yes
```

The run then rebuilt the primary QMP network filter graph successfully, but
failed before `primary.migrate`:

```text
primary.filter_chardev_binding result=fail
reason=mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed
primary.net_filters.pre_migrate_gate result=fail
reason=primary_filter_chardev_frontend_incomplete
```

This proves the previous channel split moved the boundary forward. The remaining
problem is that FTCTL still uses one strict chardev `frontend-open` rule for both
pre-migrate construction and runtime validation.

## Problem

`query-chardev` reports QEMU chardev frontend state, but not every X-COLO
chardev has the same readiness meaning before `primary.migrate`.

Before migration starts, listener/server-side or topology-backed endpoints may
legitimately report `frontend-open=false` while their TCP channel is already in
the expected pre-migrate state:

- `mirror0`: acceptable when the mirror channel is `LISTEN` or already
  `ESTABLISHED`.
- `compare0`: acceptable when the compare peer channel is `LISTEN` or already
  `ESTABLISHED`.
- `compare_out0`: acceptable when the compare-out loopback channel is already
  `ESTABLISHED`.

Treating these labels as hard failures before migration prevents FTCTL from
reaching the actual COLO migration stage even when the topology is ready.

## Design

Split chardev binding validation by phase.

### Pre-Migrate Gate

The pre-migrate gate is topology-aware:

1. All required chardev labels must exist:
   `mirror0`, `compare1`, `compare0`, `compare0-0`, `compare_out`,
   `compare_out0`.
2. Chardevs that must already be consumed by QEMU must still have
   `frontend-open=true`.
3. Listener/server-side or topology-backed closed frontends may be accepted only
   when the matching channel state proves the path is ready:
   - `mirror0` closed frontend accepted by mirror `LISTEN` or `ESTABLISHED`.
   - `compare0` closed frontend accepted by compare peer `LISTEN` or
     `ESTABLISHED`.
   - `compare_out0` closed frontend accepted by compare-out `ESTABLISHED`.
4. Missing labels or unknown frontend state remain hard failures.

Successful evidence must include the phase and topology-aware marker:

```text
primary.filter_chardev_binding ok phase=pre_migrate topology_aware=yes
```

### Runtime Gate

Runtime diagnostics keep the stricter meaning:

- all required chardev labels must exist,
- closed frontends remain diagnostic failures,
- channel readiness must become fully `ESTABLISHED`,
- primary and secondary COLO roles must be reported correctly.

This prevents a pre-migrate listener state from being mistaken for a stable
runtime COLO session.

## Code Shape

`ftctl_xcolo_collect_primary_chardev_binding_state` accepts a phase argument:

```bash
ftctl_xcolo_collect_primary_chardev_binding_state "${vm}" "pre_migrate"
ftctl_xcolo_collect_primary_chardev_binding_state "${vm}"              # strict
```

Pre-migrate callers use `pre_migrate`; runtime diagnostics and failure
refinement keep strict default behavior.

## Expected Result

The next successful pre-migrate sequence should pass the former failure point:

```text
primary.channel_paths ok mode=pre_migrate
primary.filter_chardev_binding ok phase=pre_migrate topology_aware=yes
primary.net_filters ok mode=qmp-rebuild
primary.cont_before_migrate ok
primary.migrate ok
```

If a later failure occurs, it should now be isolated to the migration/runtime
COLO role establishment phase instead of the pre-migrate graph construction
phase.

## Relationship To Earlier Designs

- Design 328 remains correct that the primary filter graph must be built before
  migration. This document refines the meaning of "ready" at that boundary.
- Design 329 remains correct that pre-migrate channel readiness is not the same
  as runtime peer establishment.
- Runtime validation documents remain valid because strict chardev/frontend
  checks are still used after migration starts.
- `331-ft-xcolo-runtime-primary-role-failure-classification-design-20260531.md`
  refines runtime behavior: chardev frontend state remains diagnostic evidence,
  but a topology-ready runtime pair that stalls with primary in
  `finish-migrate` must be classified as a primary COLO role transition failure
  rather than as a pre-migrate chardev binding failure.
