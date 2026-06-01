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

### Run 2026-06-01-04

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-111-VM`
- Result: failed
- Last reached stage: 11
- Evidence:
  - standby VM/volumes created
  - baseline seeding completed for root and data disks
  - primary generated runtime started and listened on COLO channels
  - secondary generated runtime started and connected
  - primary network filters were marked as QMP-attached with
    `xcolo_primary_net_filters_attach_mode=qmp-objects`
  - pre-migrate evidence was persisted before runtime recovery
  - pre-migrate migration capabilities were present:
    `x-colo=yes`, `return-path=yes`, `checkpoint_delay=yes`
  - pre-migrate channels were established:
    `mirror=yes`, `compare=yes`, `compare_local=yes`, `compare_out=yes`
  - pre-migrate primary chardev topology was accepted:
    `xcolo_premigrate_primary_filter_chardev_ready=yes`
  - secondary reached `query-migrate=colo`
- Failure signature:
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - primary `query-migrate.error-desc`:
    `Received invalid message 0x0000 length 0x0000`
  - primary QEMU log:
    `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log:
    `Can't receive COLO message: Input/output error`
  - pre-migrate QOM evidence shows the expected QMP-attached primary filter
    objects were not visible through the current `/objects/<id>` QOM checks:
    `xcolo_premigrate_primary_filter_qom_ready=unknown`
    with empty `m0`, `redire0`, `redire1`, and `comp0` properties
- Progress judgment:
  - `repetition_status=not_repeat`
  - forward progress: the new pre-migrate evidence was captured and survived
    runtime recovery
  - not a pure repeat of Run 2026-06-01-03 because the exact pre-migrate
    topology is now known
  - the current blocker is no longer missing channel evidence; it is the
    mismatch between QMP object-add success handling and QOM topology
    verification
- Next improvement:
  - after each primary QMP `object-add`, verify the created object using a
    QOM path that is valid for runtime-added netfilter objects on
    qemu-ablestack-9.2.4
  - if `/objects/<id>` is not the valid path, discover and persist the actual
    QOM object path from `qom-list /objects` or equivalent QMP inventory
  - do not set `xcolo_primary_net_filters_attached=true` until the discovered
    QOM path confirms `m0`, `redire0`, `redire1`, and `comp0`
  - if the object path is valid but properties are unavailable, classify the
    failure before issuing primary `migrate` instead of letting migration fail
    with an opaque COLO protocol error

### Change For Next Run

- Design:
  `docs/ftctl/335-ft-xcolo-qmp-filter-qom-hard-gate-design-20260601.md`
- Implementation intent:
  - discover QMP-created filter object paths through `qom-list /objects`
  - add explicit `status=on`, `insert=behind`, and `position=tail` to QMP
    netfilter `object-add` calls
  - require `xcolo_primary_filter_qom_ready=yes` before setting
    `xcolo_primary_net_filters_attached=true`
  - stop before primary `migrate` with
    `last_error=primary_filter_qom_topology_missing` if QOM validation fails
