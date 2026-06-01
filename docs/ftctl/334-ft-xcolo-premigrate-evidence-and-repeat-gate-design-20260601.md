# 334. FT X-COLO Pre-Migrate Evidence And Repeat Gate Design

## Background

The latest `r97-link-01` FT run on the 32.x cluster removed the previous
early packet filter activation symptom:

- generated primary QEMU command line contained COLO chardevs only;
- primary packet filters were attached later by QMP;
- the earlier `filter mirror send failed(Operation not permitted)` message did
  not recur;
- the secondary still entered `query-migrate=colo` and
  `query-colo-status=secondary`;
- the primary finally failed migration with
  `Received invalid message 0x0000 length 0x0000`.

This is progress, but the high-level Cloud state still reports
`primary_migrate_failed`. Without a durable lower-level signature, later tests
can accidentally circle around the same failure.

## Design Principles

- FT validation must preserve the exact last progressed stage for every run.
- qemu FTCTL must record evidence before recovery destroys generated runtime
  domains.
- A run is considered repeated only when the terminal error, last reached
  stage, QEMU error signature, and expected improvement marker are all
  unchanged from the previous run.
- If a run repeats the same failure signature without a new evidence marker,
  testing stops and the repeated loop must be reported before more code is
  written.

## Runtime Evidence Contract

Immediately before sending primary QMP `migrate`, qemu FTCTL records stable
`xcolo_premigrate_*` state keys:

- evidence timestamp;
- primary `x-colo` and `return-path` migration capability state;
- primary checkpoint delay parameter presence;
- primary QOM packet filter readiness and selected object properties;
- primary chardev frontend readiness;
- 9000-series channel establishment state.

These keys are intentionally separate from live `xcolo_primary_*` keys because
live keys can be overwritten after runtime recovery restores the original
primary domain.

When runtime validation observes a terminal migration failure, qemu FTCTL also
records:

- `xcolo_primary_migrate_error_desc`;
- `xcolo_secondary_migrate_error_desc`;
- the same fields in the `xcolo.runtime_validate` failure event.

## Repeat Gate

For every FT test run, update the progress document before proposing the next
change. Compare the current run with the immediately previous run using:

- last reached stage;
- `last_error`;
- primary `query-migrate.error-desc`;
- secondary QEMU log signature;
- whether the expected improvement marker changed;
- pre-migrate QOM/chardev/channel evidence.

If the same signature repeats and there is no new evidence marker, mark the run
as:

```text
repetition_status=repeat
```

Then report that the loop is repeating and stop speculative patching. If a
signature has the same high-level error but a different low-level cause or a
new progressed stage, mark it as:

```text
repetition_status=not_repeat
```

and document why.

## Expected Result

The next failed run, if any, must say whether the failure is:

- missing QMP-attached primary filter topology before `migrate`;
- invalid/closed chardev or 9000-series channel state before `migrate`;
- a COLO migration protocol failure after a valid pre-migrate topology;
- a repeated failure loop requiring a different strategy.
