# FT Validation Progress - r97-link-01 - 2026-06-01

This document records per-run progress so FT validation does not repeat the
same failure loop without noticing. Each run must identify the last reached
stage, the new evidence, and the next change.

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

