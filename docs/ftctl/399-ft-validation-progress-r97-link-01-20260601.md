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

### Run 2026-06-01-05

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-112-VM`
- Protection row: `56`
- Result: failed
- Last reached stage: runtime validation after primary `migrate`
- Evidence:
  - standby VM and standby volumes were created
  - baseline seed completed for both root and data disks
  - primary generated runtime and secondary generated runtime were created
  - secondary incoming side started and reached COLO-capable state
  - primary QMP filter objects were created dynamically
  - hard QOM gate passed:
    `primary.filter_qom_topology=ok`
  - persisted QOM paths and properties were valid:
    `m0=/objects/m0`, `redire0=/objects/redire0`,
    `redire1=/objects/redire1`, `comp0=/objects/comp0`
  - pre-migrate evidence was complete:
    `x-colo=yes`, `return-path=yes`, `checkpoint_delay=yes`,
    `filter_qom=yes`, `chardev=yes`, `mirror=yes`, `compare=yes`,
    `compare_local=yes`, `compare_out=yes`
  - primary `migrate` command returned `ok`
- Failure signature:
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - runtime validation saw:
    `primary_status=paused`, `secondary_status=running`,
    `primary_colo=none`, `secondary_colo=secondary`
  - primary `query-migrate.error-desc`:
    `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log:
    `Can't receive COLO message: Input/output error`
- Progress judgment:
  - `repetition_status=not_repeat`
  - Design 335 worked: the prior blocker, unconfirmed primary QOM filter
    topology, is gone
  - this run proves the failure is now after a valid primary filter QOM and
    complete pre-migrate channel evidence
  - the next blocker is COLO protocol negotiation after primary `migrate`, not
    QMP object creation
- Next improvement:
  - keep the late QMP attach point, but change the primary QMP object-add
    order to QEMU's documented primary COLO filter order:
    `m0 -> redire0 -> redire1 -> comp0`
  - persist `xcolo_primary_filter_qmp_attach_order=qemu-doc-primary` so the
    next run can prove the new order was active
  - keep Design 335 QOM hard gate after the reordered attach

### Change For Next Run

- Design:
  `docs/ftctl/336-ft-xcolo-primary-filter-qmp-order-design-20260601.md`
- Implementation intent:
  - update both `qmp-objects` and `qmp-rebuild` primary filter attach paths
  - attach `filter-mirror m0` before `redire0`, `redire1`, and `comp0`
  - add selftest coverage for the primary QMP object-add order
  - do not interpret a later COLO protocol failure as a repeated loop unless
    the order marker and QOM hard gate are both confirmed

### Run 2026-06-02-06

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-113-VM`
- Protection row: `57`
- Result: failed, still active in Cloud DB as an error row
- Monitoring note:
  - the user reported a new protection start, but Cloud DB did not create a
    new protection row
  - active state remained on the previous failed row `57`
  - DB still reports standby VM `i-2-113-VM` as `Running`, while the target
    host `10.10.32.1` no longer has that libvirt domain
- Last reached stage: runtime validation after primary `migrate`
- Evidence:
  - Design 336 was active:
    `xcolo_primary_filter_qmp_attach_order=qemu-doc-primary`
  - primary and secondary netdev discovery passed:
    `xcolo_primary_netdev_ready=yes`,
    `xcolo_secondary_netdev_ready=yes`
  - QOM hard gate passed:
    `xcolo_primary_filter_qom_ready=yes`
  - pre-migrate evidence was complete:
    `xcolo_premigrate_primary_filter_qom_ready=yes`,
    `xcolo_premigrate_primary_filter_chardev_ready=yes`,
    all four COLO channels established
  - primary `migrate` moved into runtime validation, not an earlier prepare
    failure
- Failure signature:
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - `xcolo_primary_status=paused`
  - `xcolo_secondary_status=running`
  - `xcolo_primary_colo_mode=none`
  - `xcolo_secondary_colo_mode=secondary`
  - `xcolo_primary_migrate_status=failed`
  - `xcolo_secondary_migrate_status=colo`
  - `xcolo_primary_migrate_error_desc=Received invalid message 0x0000 length 0x0000`
- Progress judgment:
  - `repetition_status=progressed_evidence_same_terminal_error`
  - Design 336 was applied and verified, so the failure is no longer
    attributable to primary QMP filter order
  - the remaining terminal symptom is still the primary-side COLO protocol
    message failure after migration starts
  - the stale active DB row and stale standby inventory also prove cleanup must
    be done before the next valid start
- Next improvement:
  - add an explicit FT/COLO primary runtime netdev vhost guard
  - fail before primary `migrate` if the generated primary runtime QEMU command
    still contains a vhost-enabled tap netdev for the COLO-filtered NIC
  - persist a marker such as `xcolo_primary_netdev_vhost=off` or
    `xcolo_primary_netdev_vhost=on` so future runs can distinguish a real COLO
    protocol failure from an invalid vhost-backed network path
  - cleanup row `57`, stale standby VM `113`, volumes `211` and `212`, and
    host runtime leftovers before the next test

### Change For Next Run

- Design:
  `docs/ftctl/337-ft-xcolo-primary-vhost-guard-design-20260602.md`
- Implementation intent:
  - keep virtio MAC/IP identity unchanged
  - normalize generated FT/COLO virtio interfaces to QEMU userspace driver XML
  - inspect the actual generated primary QEMU process command line through
    `/proc/*/cmdline`
  - record `xcolo_primary_netdev_vhost=off/on/unknown`
  - stop before primary `migrate` with
    `last_error=primary_netdev_vhost_enabled` if vhost is still enabled
  - treat a future protocol failure with `xcolo_primary_netdev_vhost=off` as a
    new blocker, not another vhost investigation loop

### Build And Cleanup 2026-06-02-07

- Source commit:
  `6629a414e31a683a7ea4e836ce81a2fb12421b94`
- GitHub Actions run:
  `26764986794`
- Build result: success
- RPM:
  `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
- RPM SHA256:
  `8fe5f2e26e6aab588e3af1932a0042d406701d81e6da017df618fab8b25f5fac`
- Deployment:
  - installed on `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
  - used `aspkg` through `exec -a rpm` because 32.x masks direct `rpm`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts
  - installed `xcolo.sh` contains the
    `xcolo_primary_netdev_vhost` and `primary_vhost_guard_failed` markers
- Cleanup:
  - host-side runtime for `i-2-54-VM` was removed with forced unprotect after
    the stale lock cleared
  - stale standby domain `i-2-113-VM` is not present on `10.10.32.1`
  - stale local image files for volumes `211` and `212` were removed from
    `10.10.32.1`
  - Cloud DB active FT state is clean:
    `active_protection=0`, `active_protection_volume=0`,
    `active_ftctl_details=0`, `active_standby_vm=0`,
    `active_standby_volumes=0`
  - primary VM `i-2-54-VM` remains `Running` on host `10.10.32.3`
  - primary QMP `query-block-jobs` returns an empty list
  - primary QMP `query-migrate` returns an empty object
- Next valid test expectation:
  - if vhost is still present on the generated primary runtime, the run should
    stop before primary `migrate` with `primary_netdev_vhost_enabled`
  - if `xcolo_primary_netdev_vhost=off` is recorded and the same protocol
    failure remains, the next blocker is not vhost and must move to COLO channel
    payload direction or QEMU behavior

### Run 2026-06-02-08

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-114-VM`
- Protection row: `58`
- Standby volumes:
  - root: `213`, path `8cbadebb-3480-4459-99ec-4626c20d8ece`
  - data: `214`, path `6227f4c2-4bdd-49d5-b5e9-7c86a885042f`
- Result: failed
- Last reached stage: runtime validation after primary `migrate`
- Evidence:
  - the new run was created correctly; this was not a stale row repeat
  - baseline seed completed for both disks
  - primary generated runtime started
  - secondary generated runtime `i-2-114-VM` started on `10.10.32.1`
  - primary vhost guard passed:
    `conversion_stage=primary_vhost_guard_passed`
  - actual primary runtime marker:
    `xcolo_primary_netdev_vhost=off`
  - secondary QEMU command line also had no vhost marker:
    `-netdev {"type":"tap","fd":"79","id":"hostnet0"}`
  - QOM hard gate still passed:
    `xcolo_primary_filter_qom_ready=yes`
  - primary QMP attach order marker still present:
    `xcolo_primary_filter_qmp_attach_order=qemu-doc-primary`
  - pre-migrate evidence still passed:
    `xcolo_premigrate_primary_filter_qom_ready=yes`,
    `xcolo_premigrate_primary_filter_chardev_ready=yes`,
    all COLO channels established
- Failure signature:
  - Cloud DB:
    `protection_state=error`, `transport_state=failed`,
    `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - primary status after recovery: `Running` on host `10.10.32.3`
  - standby DB row remains `Running` on host `10.10.32.1`, but the runtime
    domain was destroyed during failure recovery
  - primary QEMU log:
    `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log:
    `Can't receive COLO message: Input/output error`
  - primary runtime validation:
    `xcolo_primary_migrate_status=failed`,
    `xcolo_secondary_migrate_status=colo`,
    `xcolo_primary_colo_mode=none`,
    `xcolo_secondary_colo_mode=secondary`
- Progress judgment:
  - `repetition_status=progressed_evidence_same_terminal_error`
  - Design 337 worked: vhost is now explicitly off at the generated primary
    runtime before the failed migrate
  - the vhost-backed netdev hypothesis is closed for this failure signature
  - repeated terminal error after `xcolo_primary_netdev_vhost=off` means the
    next investigation must move to COLO channel payload direction, chardev
    endpoint role, or QEMU COLO protocol behavior
- Next improvement:
  - stop changing netdev/vhost handling unless new evidence contradicts this
    run
  - record the exact primary and secondary chardev endpoint map immediately
    before `migrate`, including which side is server/client for:
    `mirror0`, `compare1`, `compare0`, `compare0-0`, `compare_out`,
    `compare_out0`
  - validate the COLO compare/redirector data path direction against the QEMU
    documented primary/secondary command topology before issuing `migrate`
  - add a repeat guard so another `Received invalid message 0x0000 length
    0x0000` with `xcolo_primary_netdev_vhost=off` is classified as
    `colo_channel_payload_direction_failed`, not as another generic primary
    migrate failure

### Change For Next Run 2026-06-02-08

- Design:
  `docs/ftctl/338-ft-xcolo-primary-startup-filter-topology-design-20260602.md`
- Implementation intent:
  - generate the primary COLO network filter topology in QEMU startup
    `qemu:commandline`, matching the secondary startup model
  - keep primary filter object order as:
    `m0 -> redire0 -> redire1 -> comp0`
  - use QMP object attach/rebuild only as a fallback/diagnostic path when
    startup markers are absent
  - mark the normal path as:
    `xcolo_primary_net_filters_attach_mode=cmdline`
  - require `xcolo_primary_filter_cmdline_ready=yes` before primary `migrate`
  - fail before `migrate` with
    `last_error=primary_filter_cmdline_topology_missing` if the actual QEMU
    process commandline does not contain the expected primary filter topology
- Repetition control:
  - if the next run records `xcolo_primary_netdev_vhost=off`,
    `xcolo_primary_net_filters_attach_mode=cmdline`,
    `xcolo_primary_filter_cmdline_ready=yes`,
    `xcolo_primary_filter_qom_ready=yes`, and all pre-migrate channels ready,
    but still fails with the same `Received invalid message 0x0000 length
    0x0000` signature, the blocker must be treated as lower-level COLO
    protocol/runtime behavior instead of another filter attachment iteration
