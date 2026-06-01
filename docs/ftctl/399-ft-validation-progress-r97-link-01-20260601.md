# FT Validation Progress - r97-link-01 - 2026-06-01

This document records per-run progress so FT validation does not repeat the
same failure loop without noticing. Each run must identify the last reached
stage, the new evidence, and the next change.

## Repeat Gate

Each run must be compared with the immediately previous run before more code is
written. The comparison key is:

- last reached stage;
- `last_error`;
- primary `query-migrate.error-desc`;
- secondary QEMU log signature;
- expected improvement marker from the previous change;
- pre-migrate QOM/chardev/channel evidence, if present.

If all of these are unchanged, set `repetition_status=repeat`, report the loop
immediately, and stop speculative patching. If the high-level error is the same
but a lower-level signature or reached stage changed, set
`repetition_status=not_repeat` and document the exact improvement.

## Progress Scale

1. Cloud registration accepted.
2. Standby VM and volumes created.
3. Baseline disk seed completed.
4. Primary generated XML accepted and primary paused runtime started.
5. Secondary generated XML accepted and incoming runtime started.
6. COLO peer channels connected.
7. Secondary block graph/NBD export ready.
8. Primary NBD client/block graph ready.
9. Primary network filters attached.
10. Primary migrate issued.
11. Secondary enters COLO mode.
12. Primary enters COLO mode.
13. Stable FT mirroring observed.

## Runs

### Run 2026-06-01-01

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-108-VM`
- Result: failed
- Last reached stage: 11
- Evidence:
  - primary reached `query-status=finish-migrate`
  - primary `query-migrate=active`
  - secondary reached `query-status=inmigrate`
  - secondary `query-migrate=colo`
  - secondary `query-colo-status=secondary`
- Failure signature:
  - primary COLO role did not enter
  - `xcolo_runtime_validation_failed:primary_finish_migrate_colo_role_not_entered`
- Progress judgment:
  - forward progress from earlier block graph/channel failures
  - not a repeated identical failure after the parent-node export change
- Next improvement:
  - export secondary base/parent node through NBD
  - keep primary paused before initial COLO migrate
  - preserve activation-stalled evidence instead of immediate hard cleanup

### Run 2026-06-01-02

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-109-VM`
- Result: failed
- Last reached stage: 11
- Evidence:
  - standby VM/volumes created
  - baseline seeding completed
  - secondary block graph ready
  - primary and secondary 9000-series channels connected
  - secondary reached `query-migrate=colo`
  - secondary reached `query-colo-status=secondary`
- Failure signature:
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - primary QEMU log: `filter mirror send failed(Operation not permitted)`
  - secondary QEMU log: `Can't receive COLO message: Input/output error`
- Progress judgment:
  - forward progress on disk/NBD path was retained
  - not circling on parent-node export or block graph setup
  - current repeated risk is premature primary packet filter activation
- Next improvement:
  - remove primary packet filter objects from generated XML
  - keep primary chardev endpoints in XML for listener/connect sequencing
  - attach primary packet filter objects with QMP only after block graph and
    channel readiness

### Run 2026-06-01-03

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-110-VM`
- Result: failed
- Last reached stage: 11
- Evidence:
  - standby VM/volumes created
  - baseline seeding completed for root and data disks
  - primary generated runtime started with COLO chardevs only
  - primary generated command line did not contain `filter-mirror`,
    `filter-redirector`, or `colo-compare`
  - qemu FTCTL recorded `xcolo_primary_net_filters_attach_mode=qmp-objects`
  - secondary reached `query-migrate=colo`
  - secondary reached `query-colo-status=secondary`
- Failure signature:
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - primary QEMU log: `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log: `Can't receive COLO message: Input/output error`
  - previous `filter mirror send failed(Operation not permitted)` did not
    appear in the current run's generated-primary log segment
- Progress judgment:
  - `repetition_status=not_repeat`
  - forward progress: XML early packet filter activation was removed
  - not a pure repeat of Run 2026-06-01-02 because the filter-mirror send
    failure disappeared and generated primary command line is now clean
  - remaining repeated symptom is still terminal `primary_migrate_failed`
- Next improvement:
  - treat `primary_migrate_failed` after QMP filter attach as a COLO migration
    protocol/ordering failure, not as XML early-filter activation
  - capture `query-migrate.error-desc` into state before recovery
  - verify whether QMP-attached filter objects remain visible in QOM at the
    exact pre-migrate point, before recovery removes the generated runtime
  - review the primary `migrate` command ordering and QEMU COLO capability
    setup against the documented COLO sequence
