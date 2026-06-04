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

### Build, Deploy, Cleanup 2026-06-02-09

- Source commit for deployed artifact:
  `4ffbbc1a43e90e8cd932479d02531a9402980783`
- GitHub Actions run:
  `26795058139`
- Build result: success
- RPM:
  `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
- RPM SHA256:
  `708049f6c52ad251df06b4afa199b290b9153dfb0e38d0f82a51d93967a7b2d9`
- Deployment:
  - installed on `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
  - used `aspkg` through `exec -a rpm` because 32.x masks direct `rpm`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts
  - installed `xcolo.sh` contains `xcolo_primary_filter_cmdline_ready`,
    `primary_filter_cmdline_topology_missing`, and startup
    `filter-mirror,id=m0` markers
- Cleanup:
  - forced unprotect on `10.10.32.3` removed primary runtime state for
    `i-2-54-VM`
  - standby runtime/image leftovers for `i-2-114-VM` and volumes `213`/`214`
    were removed from `10.10.32.1`
  - Cloud DB active FT state is clean:
    `active_protection=0`, `active_protection_volume=0`,
    `active_ftctl_details=0`, `active_standby_vm=0`,
    `active_standby_volumes=0`
  - primary VM `i-2-54-VM` is `Running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returns an empty list
  - primary QMP `query-migrate` returns an empty object
- Next valid test expectation:
  - generated primary runtime should report
    `xcolo_primary_net_filters_attach_mode=cmdline`
  - pre-migrate evidence should include
    `xcolo_primary_filter_cmdline_ready=yes`
  - a repeated `Received invalid message 0x0000 length 0x0000` after those
    markers must be treated as a lower-level COLO protocol/runtime blocker

### Run 2026-06-02-09

- Target: `r97-link-01`
- Primary VM: `i-2-54-VM`
- Standby VM: `i-2-115-VM`
- Protection row: `59`
- Standby volumes:
  - root: `215`, path `9a5ae55d-1e5b-4a24-9b07-5999e64f8bc5`
  - data: `216`, path `074908e5-8319-4fd6-95b4-ca9b4f3b3852`
- Result: failed
- Last reached stage: runtime validation after primary `migrate`
- Evidence:
  - baseline seed completed for both disks:
    `xcolo_disk_sda_baseline_seeded=true`,
    `xcolo_disk_sdb_baseline_seeded=true`
  - generated primary and secondary runtimes started
  - primary vhost guard passed:
    `xcolo_primary_netdev_vhost=off`
  - primary startup commandline topology gate passed:
    `primary.filter_cmdline_topology result=ok`,
    `phase=pre_migrate_xml_runtime`, `expected_netdev=hostnet0`
  - primary QOM topology gate passed:
    `primary.filter_qom_topology result=ok`
  - normal network filter attach marker is now:
    `xcolo_primary_net_filters_attach_mode=cmdline`
  - pre-migrate evidence passed:
    `filter_qom=yes`, `filter_cmdline=yes`, `chardev=yes`,
    `mirror=yes`, `compare=yes`, `compare_local=yes`, `compare_out=yes`
  - primary `migrate` command returned ok and block handshake completed:
    `primary.migrate result=ok`, `block_conversion.handshake result=ok`
- Failure signature:
  - Cloud/ftctl state:
    `protection_state=error`, `transport_state=failed`,
    `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
  - runtime validation:
    `xcolo_primary_migrate_status=failed`,
    `xcolo_secondary_migrate_status=colo`,
    `xcolo_primary_colo_mode=none`,
    `xcolo_secondary_colo_mode=secondary`
  - primary QEMU log:
    `filter mirror send failed(Operation not permitted)`,
    then `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log:
    `Can't receive COLO message: Input/output error`
  - after recovery, primary `i-2-54-VM` is Running on `10.10.32.3`
  - standby domain `i-2-115-VM` was destroyed during recovery, but Cloud DB
    still has standby VM row `115` and volumes `215`/`216` as active
- Progress judgment:
  - `repetition_status=repeated_terminal_error_after_startup_topology_passed`
  - this is no longer a vhost or primary filter attachment problem
  - Design 338 worked: startup commandline topology, QOM topology, and
    pre-migrate channel evidence all passed before the same protocol failure
  - the next improvement must focus on lower-level COLO protocol/runtime
    behavior, especially why primary emits
    `filter mirror send failed(Operation not permitted)` before the invalid
    COLO message
- Next improvement:
  - stop iterating on startup filter attachment unless new evidence contradicts
    Run 59
  - classify this failure as a COLO runtime/protocol blocker
  - inspect primary filter-mirror failure conditions and the primary/secondary
    socket endpoint roles at QEMU runtime, not just through ftctl state
  - add explicit capture of filter object runtime status and socket errno/log
    context immediately after `migrate` starts
  - cleanup is required before the next valid retest because row `59`, standby
    VM `115`, and standby volumes `215`/`216` remain active in Cloud DB

### Change For Next Run 2026-06-02-09

- Design:
  `docs/ftctl/339-ft-xcolo-delayed-primary-filter-activation-design-20260602.md`
- Implementation intent:
  - keep primary COLO filter objects in generated startup commandline
  - change primary startup filter status from `on` to `off`
  - verify startup QOM status is `off` before activation
  - after channel validation, block graph attachment, and startup QOM topology
    validation, enable filters with QMP `qom-set`
  - activate in order: `redire0 -> redire1 -> m0`
  - verify post-activation QOM status is `on`
  - run the strict chardev binding gate after activation, because `status=off`
    may leave filter chardev frontends closed before activation
  - record:
    `xcolo_primary_filter_startup_status=off`,
    `xcolo_primary_net_filters_activation_mode=qom-set-status`,
    `xcolo_primary_net_filters_activated=true`,
    `xcolo_primary_filter_runtime_status=on`
  - if QEMU logs still show `filter mirror send failed(Operation not
    permitted)`, classify as
    `xcolo_runtime_validation_failed:primary_filter_mirror_send_failed`
- Repetition control:
  - this run tests delayed activation, not topology placement
  - if startup status is `off`, activation is `true`, runtime status is `on`,
    and the same mirror-send failure remains, the next blocker is QEMU COLO
    runtime/protocol behavior rather than ftctl filter activation ordering

### Build, Deploy, Cleanup 2026-06-02-10

- Source commit for deployed artifact:
  `cad8d0594b97d534bb54d24dee21515f76896501`
- GitHub Actions run:
  `26796801104`
- Build result: success
- RPM:
  `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
- RPM SHA256:
  `c4ebe2509d5f2a7f1ed0e733671a4e9d1e1e12ff76ef9b0f2c5cee5458382424`
- Deployment:
  - installed on `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
  - used `aspkg` through `exec -a rpm` because 32.x masks direct `rpm`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts
  - installed `xcolo.sh` contains `status=off`,
    `qom-set-status`, `primary_filter_activation_failed`, and
    `primary_filter_mirror_send_failed` markers
- Cleanup:
  - forced unprotect on `10.10.32.3` removed primary runtime state for
    `i-2-54-VM`
  - standby runtime/image leftovers for `i-2-115-VM` and volumes `215`/`216`
    were removed from `10.10.32.1`
  - Cloud DB active FT state is clean:
    `active_protection=0`, `active_protection_volume=0`,
    `active_ftctl_details=0`, `active_standby_vm=0`,
    `active_standby_volumes=0`
  - primary VM `i-2-54-VM` is `Running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returns an empty list
  - primary QMP `query-migrate` returns an empty object
- Next valid test expectation:
  - generated primary runtime should start filter objects with `status=off`
  - activation should record
    `xcolo_primary_net_filters_activation_mode=qom-set-status` and
    `xcolo_primary_net_filters_activated=true`
  - if `filter mirror send failed(Operation not permitted)` still appears,
    the failure should be classified as
    `xcolo_runtime_validation_failed:primary_filter_mirror_send_failed`

### Run 60 Result 2026-06-02-11

- User action:
  - started FT protection for `r97-link-01`
- Cloud state:
  - protection row `60`
  - primary VM `54` / `i-2-54-VM`
  - standby VM `116` / `i-2-116-VM`
  - final protection state: `error`
  - final transport state: `failed`
  - final active side: `primary`
  - final error:
    `xcolo_runtime_validation_failed:primary_filter_mirror_send_failed`
- Progress evidence:
  - baseline seed completed for both disks:
    `xcolo_disk_sda_baseline_seeded=true`,
    `xcolo_disk_sdb_baseline_seeded=true`
  - primary generated runtime VM was created successfully
  - secondary generated runtime VM was created successfully
  - secondary COLO block graph was built successfully for both `sda` and `sdb`
  - primary generated commandline contained filter objects with `status=off`
  - pre-activation QOM topology check passed with expected status `off`
  - delayed activation passed:
    `primary.filter_status_on.redire0`,
    `primary.filter_status_on.redire1`,
    `primary.filter_status_on.m0`
  - post-activation QOM topology check passed with expected status `on`
  - pre-migrate evidence passed:
    `x_colo=yes`, `return_path=yes`, `checkpoint_delay=yes`,
    `filter_qom=yes`, `filter_cmdline=yes`, `chardev=yes`,
    all four channels established
  - primary `migrate` command returned ok
  - handshake stage returned ok
- Failure evidence:
  - primary runtime validation failed after handshake
  - primary QEMU log:
    `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log at the same timestamp:
    `Can't receive COLO message: Input/output error`
  - validation state after failure:
    - primary status: `paused`
    - secondary status: `running`
    - primary migrate status: `failed`
    - secondary migrate status: `colo`
    - primary COLO mode: `none`
    - secondary COLO mode: `secondary`
    - strict chardev state after failure:
      `mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed`
  - recovery returned the primary VM to normal running state on
    `10.10.32.3`
- Repetition control:
  - not a blind repeat of the previous startup/filter activation failures
  - the delayed activation design worked as intended through QMP status
    transition, post-activation topology, pre-migrate evidence, and migrate
    start
  - the remaining blocker is now the COLO protocol/socket message path after
    migrate handshake
- Next improvement direction:
  - stop changing startup filter timing unless new evidence contradicts Run 60
  - inspect the COLO message path between:
    - primary `filter-mirror m0 -> mirror0 -> secondary red0`
    - secondary `red1 -> primary compare1`
    - primary local compare loop `compare0/compare0-0` and
      `compare_out/compare_out0`
  - validate whether the mirror and compare channel roles match the QEMU COLO
    reference for the installed QEMU 9.2.4 build
  - add runtime capture immediately after successful migrate:
    QOM filter status, chardev frontend state, socket peer/listen state, and
    QEMU log tail before the validation timeout destroys the secondary
  - the desired state for the next run is not just `primary.migrate ok`, but:
    primary migrate status enters COLO, secondary remains COLO secondary, both
    VMs are not exposed to guest boot independently, and no invalid COLO
    message is logged

### Change For Next Run 2026-06-02-12

- Design:
  `docs/ftctl/340-ft-xcolo-virtio-vnet-hdr-support-design-20260602.md`
- Implementation intent:
  - detect whether the primary or secondary XCOLO netdev model is virtio based
  - record:
    `xcolo_net_vnet_hdr_support=on|off`,
    `xcolo_net_vnet_hdr_support_reason`,
    `xcolo_net_vnet_hdr_primary_model`,
    `xcolo_net_vnet_hdr_secondary_model`
  - for virtio models, add `vnet_hdr_support` to:
    - primary `filter-mirror m0`
    - primary `filter-redirector redire0/redire1`
    - primary `colo-compare comp0`
    - secondary `filter-redirector f1/f2`
    - secondary `filter-rewriter rew0`
  - apply the same contract to generated XML commandline and QMP object-add
    fallback/rebuild paths
  - treat missing primary commandline `vnet_hdr_support` as a pre-migrate
    blocker with `last_error=xcolo_vnet_hdr_support_missing`
  - record vnet header state in pre-migrate evidence
- Validation:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - `git diff --check`: pass
  - full selftest still stops at pre-existing shellcheck warnings; no new
    syntax failure
  - added and manually ran a focused mini-check that confirms virtio models
    produce primary/secondary COLO args containing `vnet_hdr_support`
- Repetition control:
  - the next run is not another filter activation timing test
  - if `xcolo_net_vnet_hdr_support=on` and generated commandline contains
    `vnet_hdr_support`, but the same invalid COLO message remains, the next
    blocker is deeper QEMU COLO protocol/device-model behavior

### Build, Deploy, Cleanup 2026-06-02-13

- Source commit for deployed artifact:
  `d2739cffb82d8a45c05a19589a06f065b0451a0c`
- GitHub Actions run:
  `26798436784`
- Build result: success
- RPM:
  `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
- RPM SHA256:
  `ae35c79d777c32566c9f7a9c6934c68bf18d9ff64b8e782bbcd3ef60c6528265`
- Deployment:
  - installed on `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
  - used `aspkg` through `exec -a rpm`
  - installed `xcolo.sh` contains:
    `vnet_hdr_support`,
    `xcolo_net_vnet_hdr_support`,
    `xcolo_vnet_hdr_support_missing`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts
- Cleanup:
  - forced unprotect on `10.10.32.3` returned ok for `i-2-54-VM`
  - removed Run 60 standby image files from `10.10.32.1`:
    - `/var/lib/libvirt/images/44c1e6f2-ddc2-4707-b0b0-c56b90fb0861`
    - `/var/lib/libvirt/images/346e4dca-6811-401b-996a-cc322db8c2f3`
  - Cloud DB cleanup marked protection row `60` disabled/removed, standby VM
    `116` expunging, and standby volumes `217`/`218` expunged
  - active cleanup counters are all zero:
    active protection, active protection volume, active ftctl details, active
    standby VM, active standby volumes
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returns an empty list
  - primary QMP `query-migrate` returns an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`,
    which is the expected clean pre-registration state
- Next valid test expectation:
  - new generated primary and secondary commandlines must contain
    `vnet_hdr_support` because both netdev models are `virtio`
  - pre-migrate evidence must report `vnet_hdr=on`
  - if the invalid COLO message repeats with those markers, report it as a
    deeper QEMU COLO protocol/device-model blocker, not a repeated ftctl
    topology/timing failure

### Run 61 Monitoring 2026-06-02-13

- User action:
  - started FT protection for `r97-link-01`
- Cloud DB final state:
  - protection row `61`
  - primary VM `54`
  - standby VM `117`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_baseline_seed_failed:sdb`
- Host status:
  - primary domain `i-2-54-VM` is running on `10.10.32.3`
  - standby VM `i-2-117-VM` remains stopped on the peer side
  - QMP `query-block-jobs` is empty
  - QMP `query-migrate` is empty
- New marker validation:
  - `xcolo_primary_netdev_model=virtio`
  - `xcolo_secondary_netdev_model=virtio`
  - `xcolo_net_vnet_hdr_support=on`
  - `xcolo_net_vnet_hdr_support_reason=virtio_net_model`
  - event log contains:
    `xcolo.net_vnet_hdr ok required=on reason=virtio_net_model`
- Disk seed progression:
  - `sda` baseline seed succeeded
  - `sdb` baseline seed started, NBD export started, then copy failed with
    `rc=255`
  - `sdb` target image remained a small qcow2 seed target, while `sda` target
    image had a populated qcow2 result
- Failure evidence:
  - target host `10.10.32.1` entered `MaxStartups throttling` during the
    failure window
  - source host `10.10.32.3` also logged `MaxStartups throttling` in the same
    window
  - several SSH preauth sessions were dropped or closed around the seed-copy
    window
  - `block_conversion.baseline_seed.copy` recorded `error=""`, which means
    the remote execution layer did not preserve useful SSH failure detail for
    this rc=255 case
- Repetition control:
  - this is not a repeat of the previous COLO invalid-message failure
  - the vnet header detection change produced the expected state marker
  - the run failed before generated runtime filter activation, migration, or
    pre-migrate evidence could validate the previous COLO protocol hypothesis
- Next improvement target:
  - make baseline seed remote copy resilient and diagnosable:
    capture rc=255 SSH failure detail, add bounded retries for SSH transport
    failures, and avoid treating an empty remote error as sufficient evidence

### Change For Next Run 2026-06-02-14

- Design:
  `docs/ftctl/341-ft-xcolo-baseline-seed-ssh-retry-design-20260602.md`
- Implementation intent:
  - keep the change local to baseline seed remote copy and shared remote-exec
    diagnostics
  - add synthetic diagnostics when SSH returns `rc=255` with empty stdout/stderr
  - retry FT XCOLO baseline seed copy only for SSH transport failures
  - remove file-backed `<dest>.ftctl-seed.*` temporaries before retries
  - emit explicit retry/final-failure events so the next test can distinguish
    real progress from repeated transport failure
- Repetition control:
  - if `sdb` seed passes, the next run should reach the COLO runtime/migration
    validation that Run 61 could not reach
  - if `sdb` seed fails again, it must include retry events or non-empty
    transport diagnostics; otherwise it is a repeated diagnostic gap

### Build, Deploy, Cleanup 2026-06-02-14

- Source commit for deployed artifact:
  `a527be1c935c017b2dab10e822541ec6d2e522ab`
- GitHub Actions run:
  `26800381008`
- Build result: success
- RPM:
  `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
- RPM SHA256:
  `f278253e4937dd88294456e1b2c295fa1043a90940d8955981866360ca42d502`
- Deployment:
  - installed on `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
  - used `aspkg` through `exec -a rpm`
  - installed scripts contain:
    `ssh_transport_failed_without_stderr`,
    `block_conversion.baseline_seed.copy.retry`,
    `xcolo_baseline_seed_ssh_failed`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts
- Cleanup:
  - forced unprotect on `10.10.32.3` returned `status not_found` afterward for
    `i-2-54-VM`
  - Cloud DB cleanup marked protection row `61` disabled/removed, standby VM
    `117` expunging, and standby volumes `219`/`220` expunged
  - removed Run 61 standby image files from `10.10.32.1`:
    - `/var/lib/libvirt/images/eb48d5d1-60e3-402f-9db7-877de96511eb`
    - `/var/lib/libvirt/images/f950ff81-4ce4-4dd5-9f60-7ea280da92fe`
  - active cleanup counters are all zero:
    active protection, active ftctl details, active standby VM, active standby
    volumes
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returns an empty list
  - primary QMP `query-migrate` returns an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`
- Next valid test expectation:
  - if transient SSH failure occurs during `sdb` baseline seed, retry events
    and non-empty transport diagnostics must be recorded
  - if baseline seed passes, the run should proceed to generated runtime
    filter activation and COLO migration validation

### Run 62 Monitoring 2026-06-02-15

- User action:
  - started FT protection for `r97-link-01`
- Cloud DB final state:
  - protection row `62`
  - primary VM `54`
  - standby VM `118`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
- Host status:
  - primary domain `i-2-54-VM` is running again on `10.10.32.3` after rollback
  - standby domain `i-2-118-VM` was started during the run and then destroyed
    by rollback; standby VM row remains stopped
  - QMP `query-block-jobs` is empty after rollback
  - QMP `query-migrate` is empty after rollback
- Progress compared to Run 61:
  - Run 61 failed during `sdb` baseline seed copy
  - Run 62 passed both baseline seed targets:
    - `xcolo_disk_sda_baseline_seeded=true`
    - `xcolo_disk_sdb_baseline_seeded=true`
  - the run reached generated runtime, filter activation, pre-migrate evidence,
    and migration validation
- Validated markers:
  - `xcolo_net_vnet_hdr_support=on`
  - `xcolo_primary_filter_cmdline_vnet_hdr_required=on`
  - `xcolo_primary_filter_qom_vnet_hdr_ready=yes`
  - `xcolo_primary_filter_qom_m0_vnet_hdr_support=on`
  - `xcolo_primary_filter_qom_redire0_vnet_hdr_support=on`
  - `xcolo_primary_filter_qom_redire1_vnet_hdr_support=on`
  - `xcolo_primary_filter_qom_comp0_vnet_hdr_support=on`
  - `xcolo_premigrate_vnet_hdr_support=on`
  - `xcolo_premigrate_primary_filter_chardev_ready=yes`
  - `xcolo_premigrate_channel_mirror_established=yes`
  - `xcolo_premigrate_channel_compare_established=yes`
  - `xcolo_premigrate_channel_compare_local_established=yes`
  - `xcolo_premigrate_channel_compare_out_established=yes`
  - `xcolo_secondary_block_graph_ready=yes`
- Failure evidence:
  - primary migration failed:
    `xcolo_primary_migrate_status=failed`
  - primary QEMU log:
    `Received invalid message 0x0000 length 0x0000`
  - secondary migration remained in COLO state:
    `xcolo_secondary_migrate_status=colo`
  - secondary QEMU log:
    `Can't receive COLO message: Input/output error`
  - QEMU command line included `vnet_hdr_support` on primary and secondary
    filters, but QEMU warned that the short-form boolean is deprecated and
    recommends `vnet_hdr_support=on`
- Repetition control:
  - this is progress compared to Run 61 because the baseline seed transport
    blocker was cleared
  - this is now a repeated COLO invalid-message blocker with stronger evidence:
    vnet header support, QOM filter readiness, chardev readiness, channels, and
    secondary block graph were all recorded as ready before migrate
  - the next change must not keep cycling through generic filter-order guesses;
    it must target the validated remaining mismatch in the COLO runtime
    protocol path

### Change For Run 63 2026-06-02-16

- Design document:
  - `342-ft-xcolo-network-firewall-storage-preflight-design-20260602.md`
- Purpose:
  - make the network path, firewall contract, and storage backend symmetry
    explicit before another COLO invalid-message test
  - prevent another generic "primary_migrate_failed" report when all previous
    readiness markers have already passed
- Code expectations for the next run:
  - generated filter command lines must use `vnet_hdr_support=on`
  - pre-migrate must record `xcolo_firewall_*` state and stop before migrate if
    externally required FT ports are missing
  - pre-migrate/runtime/failure phases must record compact `xcolo_socket_*`
    summaries for 9003, 9004, loopback compare ports, and the NBD endpoint
  - disk plan creation must record `xcolo_storage_symmetry` so RBD/raw to
    filesystem/qcow2 conversion is visible as a warning, not an implicit
    assumption
  - if the same invalid COLO message appears with filters, chardevs, channels,
    and secondary block graph ready, the failure must be classified as
    `repeated_protocol_invalid_message`
- Repetition control:
  - if Run 63 still fails with the same primary/secondary QEMU messages but the
    new socket and firewall markers are healthy, the next step must be an A/B
    test around storage/backend symmetry or QEMU COLO protocol behavior, not
    another filter/chardev readiness patch

### Run 63 Preparation 2026-06-02-16

- Source commit built and deployed:
  - `89f21d1` (`fix: add xcolo network preflight diagnostics`)
- GitHub Actions:
  - workflow: `FTCTL Branch Development Release`
  - run: `26804550257`
  - result: success
- RPM:
  - `/home/ablecloud/work/ftctl-artifacts-run-26804550257/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `3ac9ab1220e05accddf5f87889af327b4fd30908e9e13d270d059d7a0bbc86d7`
- Deployment:
  - installed on `10.10.32.1`, `10.10.32.2`, `10.10.32.3`
  - verified installed script markers:
    - `vnet_hdr_support=on`
    - `xcolo_firewall_ready`
    - `xcolo_socket_${phase}_primary_9998`
    - `xcolo_repeated_protocol_invalid_message`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts
- Cleanup:
  - active protection rows for primary VM `54`: `0`
  - active FTCTL VM details for `r97-link-01` and standby VMs: `0`
  - active standby VM rows for `r97-link-01-standby`: `0`
  - active standby volumes for `r97-link-01-standby`: `0`
  - removed Run 62 standby image files:
    - `/var/lib/libvirt/images/311d6375-1f14-4e02-b79f-59a9b58cf746`
    - `/var/lib/libvirt/images/e552ff63-ec12-481e-b0f7-96fde13249bd`
  - removed stale target profile/state/debug files for `i-2-54-VM`
  - primary VM `i-2-54-VM` remains running on `10.10.32.3`
  - primary QMP `query-block-jobs` returns an empty list
  - primary QMP `query-migrate` returns an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`
- Next Run 63 expected decision point:
  - if firewall preflight fails, fix the explicit port contract first
  - if firewall and socket markers are healthy but invalid COLO message repeats,
    stop treating this as a generic filter ordering issue and proceed to
    storage/QEMU protocol A/B validation

### Run 63 Monitoring 2026-06-02-17

- User action:
  - started FT protection for `r97-link-01`
- Evidence directory:
  - `/home/ablecloud/work/ft-run63-monitor-20260602-172225.log`
  - `/home/ablecloud/work/ft-run63-final-20260602-172508`
- Cloud DB final state:
  - protection row `63`
  - primary VM `54`
  - standby VM `119`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_runtime_validation_failed:primary_migrate_failed`
- Progress confirmed compared to Run 62:
  - baseline seed passed both disks again:
    - `xcolo_disk_sda_baseline_seeded=true`
    - `xcolo_disk_sdb_baseline_seeded=true`
  - storage layout evidence is now explicit:
    - `xcolo_storage_symmetry=warning`
    - `xcolo_storage_symmetry_reason=sda:primary_block/raw_secondary_file/qcow2,sdb:primary_block/raw_secondary_file/qcow2`
  - firewall contract is explicitly healthy:
    - `xcolo_firewall_primary_state=active`
    - `xcolo_firewall_primary_service=present`
    - `xcolo_firewall_primary_missing_ports=`
    - `xcolo_firewall_primary_ready=yes`
    - `xcolo_firewall_secondary_state=active`
    - `xcolo_firewall_secondary_service=present`
    - `xcolo_firewall_secondary_missing_ports=`
    - `xcolo_firewall_secondary_ready=yes`
    - `xcolo_firewall_ready=yes`
  - socket evidence is now explicit:
    - pre-migrate and runtime primary 9003/9004/9001/9005 are listening
    - pre-migrate and runtime secondary 9003/9004 are established
    - NBD endpoint is established/listening as expected
    - secondary 9998 migrate endpoint is listening
- Failure evidence:
  - primary QEMU:
    - `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU:
    - `Can't receive COLO message: Input/output error`
  - QMP:
    - primary migrate status reached `failed`
    - secondary migrate status reached `colo`
- Repetition control:
  - this is not a repeat of the previous evidence quality; the run added
    firewall, socket, and storage layout proof
  - it is a repeat of the same protocol failure after network/firewall readiness
    was proven healthy
  - the next change should not be another generic network/firewall or filter
    ordering patch
- Follow-up defect found in the latest classifier:
  - code did not classify this run as `xcolo_repeated_protocol_invalid_message`
    because the runtime failure classifier checked current strict chardev state,
    which becomes `no` after the failed migrate
  - pre-migrate chardev readiness was `yes`, so repeated-message classification
    should use pre-migrate readiness plus socket/firewall evidence instead of
    post-failure strict chardev state
- Next expected direction:
  - fix the classifier to mark this exact signature as
    `xcolo_repeated_protocol_invalid_message`
  - then run an A/B path focused on storage symmetry or QEMU COLO protocol
    behavior, because firewall and socket transport are no longer likely root
    causes for this failure

### Change For Run 64 2026-06-02-17

- Design documents:
  - `342-ft-xcolo-network-firewall-storage-preflight-design-20260602.md`
  - `343-ft-xcolo-storage-compatibility-gate-design-20260602.md`
- Purpose:
  - promote FT XCOLO storage symmetry from diagnostic warning to default
    compatibility gate
  - stop `block/raw -> file/qcow2` FT protection before primary shutdown
  - classify repeated invalid-message failures using pre-migrate evidence
    instead of failure-time strict chardev state
- Code expectations for the next run:
  - with the current local filesystem/qcow2 target storage, protection should
    fail early with `last_error=xcolo_storage_backend_mismatch`
  - primary VM `i-2-54-VM` should not be shut down for the mismatch case
  - if an explicit experimental override is used, state must record
    `xcolo_storage_compatibility=experimental`
  - if the same invalid QEMU message occurs after pre-migrate evidence is
    healthy, the classifier must set
    `last_error=xcolo_repeated_protocol_invalid_message`
- Repetition control:
  - a Run 64 early storage mismatch block is progress, not failure repetition
  - if Run 64 again reaches migrate with the same mismatched storage and no
    override, the gate did not fire and must be fixed before further COLO
    protocol testing

### Run 64 Preparation Result 2026-06-02-18

- Source commit:
  - `976e088d79c9c087ed26be0a747b44fb48e512c9`
  - `fix: block xcolo storage backend mismatch`
- GitHub Actions build:
  - workflow: `FTCTL Branch Development Release`
  - run: `26809595332`
  - artifact: `ftctl-branch-rpm-26809595332`
  - RPM SHA256:
    `075b955e09e2e296a404389b1bf07c54fafd2c7c9ef301d46bb45c38d4dce80e`
- Deployed hosts:
  - `10.10.32.1`
  - `10.10.32.2`
  - `10.10.32.3`
- Installed verification:
  - package: `ablestack_vm_ftctl-0.8.0-1.noarch`
  - installed `xcolo.sh` contains:
    - `ftctl_xcolo_require_storage_symmetry`
    - `xcolo_storage_compatibility=blocked`
    - `xcolo_storage_compatibility=experimental`
    - `last_error=xcolo_storage_backend_mismatch`
    - `xcolo_repeated_protocol_invalid_message_evidence=premigrate_ready`
- Cleanup verification after Run 63:
  - active protection rows for primary VM `54`: `0`
  - active FTCTL VM details for primary/standby scope: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `Running` on host `3`
  - `query-block-jobs` returns an empty list
  - `query-migrate` returns an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active
    on all three 32.x hosts
- Retest readiness:
  - the next UI protection attempt is expected to stop before primary shutdown
    with `xcolo_storage_backend_mismatch` while the current target storage
    remains local filesystem/qcow2
  - this is the desired guard behavior for the repeated
    `Received invalid message 0x0000 length 0x0000` / `Can't receive COLO
    message: Input/output error` path under mismatched storage layout

### Run 64 Result 2026-06-03-12

- User action:
  - FT protection was started for `r97-link-01` / `i-2-54-VM`
  - target storage was selected so the standby disks were also `block/raw`
- Final state:
  - protection row: `64`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `120` / `i-2-120-VM`
  - `protection_state=error`
  - `transport_state=planned`
  - `active_side=primary`
  - `last_error=xcolo_block_generated_xml_prepare_failed`
- Progress confirmed:
  - the previous storage mismatch gate did not block this run
  - the actual storage layouts were compatible:
    - `xcolo_storage_symmetry=ok`
    - `xcolo_storage_primary_layouts=sda:block/raw,sdb:block/raw`
    - `xcolo_storage_secondary_layouts=sda:block/raw,sdb:block/raw`
  - primary VM remained `Running`
  - no block jobs or QEMU migration were started
- Root cause evidence:
  - profile disk map pointed to secondary RBD paths:
    - `sda=/dev/rbd/rbd/440e02f0-c616-4837-973c-c3ab2488ba52`
    - `sdb=/dev/rbd/rbd/32e4619f-a047-470e-9d4f-ae29e808646c`
  - on the secondary host `10.10.32.1`, those `/dev/rbd/...` KRBD paths did
    not exist while the cloud-managed standby VM was still stopped
  - `qemu-img info --force-share` against those paths failed with
    `No such file or directory`
  - generated standby XML was left before disk rewrite completion and still
    referenced the primary RBD paths
- Interpretation:
  - this is not a repeat of the invalid COLO message failure
  - same-format storage selection worked
  - the new failure is a cloud-managed RBD metadata probe bug: XML preparation
    assumes the secondary block path is already mapped on the secondary host
    before the transient standby runtime exists
- Required next change:
  - for cloud-managed `block/raw` disk maps, do not require `qemu-img info` on
    an unmapped secondary `/dev/rbd/...` path during generated XML preparation
  - derive metadata from the already known storage symmetry result or the
    disk-map target itself:
    - `disk_type=block`
    - `source_attr=dev`
    - `format=raw`
  - add sub-step logging for `xcolo_block_generated_xml_prepare_failed` so the
    exact failed helper is recorded in `last_error` and events
  - keep preserving primary VM state before retry; this failure is still before
    primary shutdown and before migration

### Run 65 Preparation Result 2026-06-03-13

- Source commit:
  - `6736bf830bdd9feae36ff3fbdc95f3a9f631cb2c`
  - `fix: infer cloud-managed rbd xcolo metadata`
- Design document:
  - `343-ft-xcolo-storage-compatibility-gate-design-20260602.md`
- Code changes:
  - cloud-managed `/dev/rbd/...` disk maps now infer metadata as
    `raw|dev|block` when the recorded storage symmetry is compatible
  - generated standby XML source validation now confirms every mapped disk
    target points at the intended secondary destination
  - generated XML preparation records sub-step failure reasons such as:
    - `xcolo_standby_disk_metadata_failed`
    - `xcolo_standby_disk_rewrite_failed`
    - `xcolo_standby_disk_source_mismatch`
- Validation:
  - `bash -n` passed for `xcolo.sh`, `standby.sh`, and selftest
  - `git diff --check` passed
  - targeted selftest passed:
    - `selftest_case_xcolo_cloud_managed_rbd_metadata_inference`
  - full selftest still stops at the pre-existing backend validation baseline
    after shellcheck is no-op'd; this is not a new failure from this change
- GitHub Actions build:
  - workflow: `FTCTL Branch Development Release`
  - run: `26862256891`
  - result: success
  - RPM SHA256:
    `0bb05d570ae051f65c422f7c7290ab56a62cb4fbea834d07b8a05b9a13834025`
- Deployed hosts:
  - `10.10.32.1`
  - `10.10.32.2`
  - `10.10.32.3`
- Installed verification:
  - package: `ablestack_vm_ftctl-0.8.0-1.noarch`
  - deployed marker checks passed for:
    - `ftctl_xcolo_disk_map_infer_cloud_managed_rbd_metadata`
    - `xcolo_standby_disk_metadata_failed`
    - `ftctl_xml_validate_disk_map_sources`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active
    on all three 32.x hosts
- Cleanup verification after Run 64:
  - active protection rows for primary VM `54`: `0`
  - active FTCTL VM details for primary/standby scope: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - removed standby RBD images:
    - `440e02f0-c616-4837-973c-c3ab2488ba52`
    - `32e4619f-a047-470e-9d4f-ae29e808646c`
  - primary VM `i-2-54-VM` is `Running` on host `3`
  - `query-block-jobs` returns an empty list
  - `query-migrate` returns an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`
- Retest expectation:
  - compatible `block/raw -> block/raw` cloud-managed RBD should now pass
    generated XML preparation even when the secondary KRBD paths are not
    mapped before standby runtime creation
  - if XML preparation still fails, the next run should include a specific
    sub-step `last_error` rather than the broad
    `xcolo_block_generated_xml_prepare_failed`

### Run 65 Result 2026-06-03-12

- User action:
  - FT protection was started for `r97-link-01` / `i-2-54-VM`
  - compatible `block/raw -> block/raw` storage was selected
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run65-monitor-20260603-125151.log`
  - final evidence:
    `/home/ablecloud/work/ft-run65-final-20260603-125841`
- Final state:
  - protection row: `65`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `121` / `i-2-121-VM`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_baseline_seed_failed:sda`
- Progress confirmed:
  - generated XML preparation now passes
  - state includes:
    - `primary_xml_generated=/var/lib/ablestack-vm-ftctl/xml/i-2-54-VM/primary.generated.xml`
    - `standby_xml_generated=/var/lib/ablestack-vm-ftctl/xml/i-2-54-VM/standby.generated.xml`
  - standby generated XML now points `sda` at the secondary RBD image:
    - `/dev/rbd/rbd/0f9bac5b-a44d-4427-a3f7-a5da21348ba4`
  - storage compatibility remained valid:
    - `xcolo_storage_symmetry=ok`
    - `xcolo_storage_primary_layouts=sda:block/raw,sdb:block/raw`
    - `xcolo_storage_secondary_layouts=sda:block/raw,sdb:block/raw`
- Failure stage:
  - `block_conversion.baseline_seed.start` succeeded for `sda`
  - primary source readiness succeeded:
    - `block_conversion.baseline_seed.source_ready`
  - source NBD export started:
    - `block_conversion.baseline_seed.nbd_start`
    - `nbd://10.10.32.3:10916/ftctl-xcolo-seed-i-2-54-VM-sda`
  - copy failed after three attempts:
    - `block_conversion.baseline_seed.copy.final_fail`
    - `rc=95`
    - `failure_class=copy`
- Current root cause hypothesis:
  - the previous XML metadata assumption is fixed
  - baseline seeding still attempts to copy to secondary KRBD path
    `/dev/rbd/rbd/0f9bac5b-a44d-4427-a3f7-a5da21348ba4`
  - that path is not mapped on `10.10.32.1`, although the RBD image exists in
    the pool
  - cloud-managed RBD handling therefore needs the same lifecycle correction in
    baseline seed copy: the code must either map/unmap the secondary RBD path
    for the copy operation or copy using an RBD URI/path that does not require
    a pre-existing `/dev/rbd/...` mapping
- Repetition control:
  - this is not a repeat of Run 64
  - Run 64 stopped at generated XML preparation
  - Run 65 reached baseline seed copy and rolled back primary cleanly

### Run 66 Preparation 2026-06-03-13

- Design update:
  - cloud-managed RBD baseline seed must not assume that the secondary
    `/dev/rbd/<pool>/<image>` path is already mapped before libvirt starts the
    transient standby runtime
  - qemu FTCTL should temporarily map the secondary RBD image only for the
    seed-copy operation, copy into the resolved block device, then unmap it
    again
  - generated XML and runtime state must still preserve the Cloud-owned
    `/dev/rbd/<pool>/<image>` target path
- Code update:
  - `ftctl_xcolo_seed_secondary_baseline_disk` now detects cloud-managed
    `/dev/rbd/...` seed targets
  - the secondary host command now runs `rbd map <pool>/<image>` when the
    expected block device is absent
  - the mapped device is resolved from the expected path, map output, or
    `rbd device list --format json`
  - failure states are now specific:
    - `xcolo_baseline_seed_rbd_map_failed:<target>`
    - `xcolo_baseline_seed_rbd_device_missing:<target>`
    - `xcolo_baseline_seed_rbd_unmap_failed:<target>`
- Validation:
  - `bash -n` passed for `lib/ftctl/xcolo.sh`,
    `lib/ftctl/standby.sh`, and `bin/ablestack_vm_ftctl_selftest.sh`
  - `git diff --check` passed
  - targeted selftests passed:
    - `selftest_case_xcolo_baseline_seed_maps_cloud_managed_rbd`
    - `selftest_case_xcolo_cloud_managed_rbd_metadata_inference`
- Repetition control:
  - this is not a repeat of Run 65 yet because the code now addresses the
    exact unmapped secondary RBD condition observed in Run 65
  - next repeated evidence threshold:
    - if Run 66 still fails at baseline seed with unmapped or copy-level RBD
      evidence, stop and reassess whether `qemu-img convert` should target an
      `rbd:` URI instead of a host KRBD device

### Run 66 Retest Readiness 2026-06-03-13

- Source commit:
  - `441a3be` (`fix: map cloud-managed rbd baseline seed targets`)
- Build:
  - GitHub Actions run:
    `https://github.com/dhslove/ablestack-qemu-exec-tools/actions/runs/26864098471`
  - result: success
  - RPM:
    `/home/ablecloud/work/ftctl-artifacts-run-26864098471/ftctl-branch-rpm-26864098471/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `82f8d03a994ec55254b16435c26824c33a01288b0fe1af58d83fb81e2ae27be5`
- Deployment:
  - installed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - package check:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
  - installed marker checks passed:
    - `baseline_rbd_map_failed`
    - `baseline_rbd_device_missing`
    - `baseline_rbd_unmap_failed`
    - `rbd map`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active
    on all three 32.x hosts
- Cleanup:
  - removed Run 65 protection row from active scope
  - removed FTCTL VM details for `r97-link-01` / `r97-link-01-standby`
  - expunged standby VM `i-2-121-VM`
  - expunged standby volumes `227` and `228`
  - removed standby RBD images:
    - `0f9bac5b-a44d-4427-a3f7-a5da21348ba4`
    - `f34b6cdb-d357-4af7-b993-ebcc5b3d8281`
  - removed FTCTL runtime files for `i-2-54-VM`
- Final readiness verification:
  - primary VM DB state:
    - `i-2-54-VM`, `Running`, host `3`, power state `PowerOn`
  - active protection rows for primary VM `54`: `0`
  - active FTCTL details for primary/standby scope: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - host runtime:
    - `i-2-54-VM` is running on `10.10.32.3`
    - `query-block-jobs` is empty
    - `query-migrate` is empty
    - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`
- Note:
  - during cleanup, Cloud DB reported the primary as `Stopped` while libvirt
    still had `i-2-54-VM` running on host `3`
  - because QMP block jobs and migrate state were clean, the DB row was restored
    to match actual Cloud-managed runtime state:
    - `state=Running`
    - `host_id=3`
    - `power_state=PowerOn`

### Run 66 Result 2026-06-03-22

- User action:
  - FT protection was started again for `r97-link-01` / `i-2-54-VM`
  - compatible `block/raw -> block/raw` storage was selected
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run66-monitor-20260603-225707.log`
  - final evidence:
    `/home/ablecloud/work/ft-run66-final-20260603-225828`
  - extra evidence:
    `/home/ablecloud/work/ft-run66-extra-20260603-230009`
- Final state:
  - protection row: `66`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `122` / `i-2-122-VM`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - Cloud DB `last_error`:
    - `xcolo_block_secondary_create_failed`
  - UI/API visible error:
    - `Unable to register FTCTL protection for VM d08503ff-ea56-4e35-bdf8-2f0ebf81382c: timeout`
- Progress confirmed:
  - the Run 65 baseline seed failure was fixed
  - status now includes:
    - `xcolo_disk_sda_baseline_seeded=true`
    - `xcolo_disk_sdb_baseline_seeded=true`
  - storage compatibility remained valid:
    - `xcolo_storage_symmetry=ok`
    - `xcolo_storage_primary_layouts=sda:block/raw,sdb:block/raw`
    - `xcolo_storage_secondary_layouts=sda:block/raw,sdb:block/raw`
- New failure stage:
  - baseline seed completed for both disks
  - generated standby XML pointed secondary disks at:
    - `/dev/rbd/rbd/cb3f6f83-fb74-46f4-9055-6cdc200a07fa`
    - `/dev/rbd/rbd/5b727ed2-b320-487d-ae1d-d4ce9fbd8544`
  - secondary libvirt/QEMU start failed
  - secondary host libvirt log reported:
    - `Cannot access storage file '/dev/rbd/rbd/5b727ed2-b320-487d-ae1d-d4ce9fbd8544': No such file or directory`
- Current root cause:
  - baseline seed now maps cloud-managed secondary RBD temporarily and unmaps
    it after copy
  - however, the subsequent transient secondary runtime still needs the same
    RBD devices mapped while libvirt starts and while the standby domain runs
  - preserving `/dev/rbd/rbd/<image>` in XML is not sufficient unless the
    expected host-side KRBD path exists at create time
- Required next design:
  - add a cloud-managed secondary runtime RBD map lifecycle
  - before `virsh create` on the secondary host, map every secondary RBD target
    in the generated XML
  - resolve the real block device from the expected symlink, `rbd map` output,
    or `rbd device list`
  - either ensure the generated XML points to an existing mapped block device
    or rewrite the runtime XML source to the resolved `/dev/rbdN` device for
    the transient domain
  - keep the mappings until protection cleanup/error rollback destroys the
    transient secondary runtime, then unmap only those devices mapped by FTCTL
- Repetition control:
  - this is not a repeat of Run 65
  - Run 65 stopped at baseline seed copy
  - Run 66 passed baseline seed for both disks and moved to secondary runtime
    creation

### Run 67 Fix Plan 2026-06-03-23

- Trigger:
  - Run 66 failed after both baseline seed copies completed
  - secondary libvirt could not open a generated XML disk source under
    `/dev/rbd/rbd/<secondary-image>`
- Confirmed progress from prior run:
  - Run 65 failure stage: baseline seed copy
  - Run 66 failure stage: secondary transient runtime create
  - therefore this is progress, not the same failure loop
- Root cause addressed:
  - cloud-managed RBD images can be mapped as `/dev/rbdN` even when the
    generated Cloud path `/dev/rbd/<pool>/<image>` is not a block device
  - the transient standby XML must point at the actual runtime block device
    that exists on the secondary host
- Design implemented in source:
  - before `ftctl_standby_activate`, qemu FTCTL maps each cloud-managed
    secondary RBD target on the secondary host
  - generated standby XML disk sources are rewritten to the resolved runtime
    device, such as `/dev/rbd14`
  - per-disk runtime mapping state is recorded:
    - `xcolo_secondary_runtime_rbd_<target>=<cloud-path>|<runtime-device>|<mapped-by-ftctl>`
  - follow-up secondary disk binding lookup uses the runtime device path rather
    than the original Cloud path
  - rollback and standby deactivate unmap only devices mapped by FTCTL
- Repetition guard for next run:
  - if secondary create still fails, compare generated XML source paths with
    the secondary host `rbd device list` output
  - if QMP binding fails after secondary create, verify binding lookup used the
    runtime `/dev/rbdN` path stored in state
  - do not treat this as a storage type mismatch unless layouts diverge from
    `block/raw -> block/raw`

### Run 67 Retest Readiness 2026-06-03-23

- Source commit:
  - `dfa1bdc` (`fix: map cloud managed xcolo runtime rbd`)
- Local verification before build:
  - `bash -n lib/ftctl/xcolo.sh`
  - `bash -n lib/ftctl/standby.sh`
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`
  - targeted selftest:
    - `selftest_case_xcolo_secondary_runtime_maps_cloud_managed_rbd`
  - `git diff --check`
- Build:
  - GitHub Actions run:
    `https://github.com/dhslove/ablestack-qemu-exec-tools/actions/runs/26891699872`
  - RPM build and artifact upload completed
  - final workflow conclusion was failed only at the GitHub Release publish
    step because GitHub returned a secondary rate-limit error
  - downloaded RPM artifact:
    `/home/ablecloud/work/ftctl-artifacts-run-26891699872/ftctl-branch-rpm-26891699872/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `487c7ae6ab1d2d3b5d05e2cf8500193d4def679c9cfdc45891561c898d586219`
- Deployment:
  - installed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - package check:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
  - installed marker checks passed:
    - `xcolo_secondary_runtime_rbd_prepare`
    - `xcolo_secondary_runtime_xml_rewrite_failed`
    - `rbd unmap`
    - `standby.deactivate.runtime_rbd_unmap`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active
    on all three 32.x hosts
- Cleanup:
  - removed Run 66 protection row from active scope:
    - row `66` now `disabled/stopped`, `removed=2026-06-03 23:40:37`
  - removed FTCTL VM details for `r97-link-01` / `r97-link-01-standby`
  - expunged standby VM `i-2-122-VM`
  - expunged standby volumes `229` and `230`
  - removed standby RBD images:
    - `cb3f6f83-fb74-46f4-9055-6cdc200a07fa`
    - `5b727ed2-b320-487d-ae1d-d4ce9fbd8544`
  - removed FTCTL runtime files for `i-2-54-VM`
- Final readiness verification:
  - primary VM DB state:
    - `i-2-54-VM`, `Running`, host `3`, power state `PowerOn`
  - active protection rows for primary VM `54`: `0`
  - active FTCTL details for primary/standby scope: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - host runtime:
    - `i-2-54-VM` is running on `10.10.32.3`
    - `query-block-jobs` is empty
    - `query-migrate` is empty
    - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returns `not_found`
- Cleanup note:
  - the first cleanup pass removed RBD images successfully but stopped on a
    runtime path that was a directory rather than a file
  - retry used `rm -rf` for the target-specific runtime path and completed DB
    cleanup plus timer restart

### Run 67 Result 2026-06-03-23

- User action:
  - FT protection was started again for `r97-link-01` / `i-2-54-VM`
  - compatible `block/raw -> block/raw` storage was selected
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run67-monitor-20260603-234708.log`
  - final evidence:
    `/home/ablecloud/work/ft-run67-final-20260603-235329`
- Final state:
  - protection row: `67`
  - standby VM: `123` / `i-2-123-VM`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_repeated_protocol_invalid_message`
- Progress confirmed:
  - Run 66 `xcolo_block_secondary_create_failed` was fixed
  - both baseline seeds completed:
    - `xcolo_disk_sda_baseline_seeded=true`
    - `xcolo_disk_sdb_baseline_seeded=true`
  - secondary runtime RBD mapping completed:
    - `xcolo_secondary_runtime_rbd_prepared=true`
    - `xcolo_secondary_runtime_rbd_sda=/dev/rbd/rbd/b96309d5-b10d-4ddd-aa9a-2c54a533768c|/dev/rbd/rbd/b96309d5-b10d-4ddd-aa9a-2c54a533768c|1`
    - `xcolo_secondary_runtime_rbd_sdb=/dev/rbd/rbd/3d72840a-7a2f-41c7-8cbb-5e53374e4316|/dev/rbd/rbd/3d72840a-7a2f-41c7-8cbb-5e53374e4316|1`
  - secondary domain reached `standby_state=running`
  - primary migration and block conversion handshake reached:
    - `primary.migrate=ok`
    - `block_conversion.handshake=ok`
  - secondary block graph was present for both disks:
    - `xcolo_secondary_block_graph_ready=yes`
  - socket and firewall checks were not the immediate cause:
    - `xcolo_firewall_ready=yes`
    - runtime/failure snapshots showed primary 9003/9004 listening and
      secondary 9003/9004 established
- Failure evidence:
  - `conversion_stage=runtime_validation_failed`
  - `xcolo_repeated_protocol_invalid_message=yes`
  - primary QEMU/libvirt log:
    - `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU/libvirt log:
    - `Can't receive COLO message: Input/output error`
  - runtime validation state:
    - `xcolo_primary_status=paused`
    - `xcolo_secondary_status=running`
    - `xcolo_primary_migrate_status=failed`
    - `xcolo_secondary_migrate_status=colo`
    - `xcolo_primary_colo_mode=none`
    - `xcolo_secondary_colo_mode=secondary`
- Repetition control:
  - this is a repeat of the known COLO protocol invalid-message class, not a
    repeat of Run 66 storage/runtime RBD failure
  - the latest code change did improve the run because it advanced from
    secondary create failure to runtime validation failure after handshake
  - the next design must focus on COLO protocol channel sequencing and filter
    activation timing, not storage type selection or firewall openness

### Run 68 Fix Plan 2026-06-04

- Trigger:
  - Run 67 reached `primary.migrate=ok` and `block_conversion.handshake=ok`
    but failed in post-migrate runtime validation
  - the repeated terminal signature was:
    - primary QEMU: `Received invalid message 0x0000 length 0x0000`
    - secondary QEMU: `Can't receive COLO message: Input/output error`
- Confirmed non-causes from Run 67:
  - compatible `block/raw -> block/raw` storage was selected
  - baseline seed completed for both disks
  - cloud-managed secondary runtime RBD mapping completed
  - secondary runtime domain started
  - secondary block graph was ready
  - firewall and socket evidence were ready
  - pre-migrate filter, chardev, and 9000-series channel evidence were ready
- Design recorded:
  - [344. FT XCOLO Steady-State Gate And Protocol Subreason Design](344-ft-xcolo-steady-state-gate-and-protocol-subreason-design-20260604.md)
- Code direction:
  - treat `block_conversion.handshake=ok` as QMP command acceptance only
  - add an explicit `block_conversion.steady_state_gate` event/state after
    handshake
  - keep stable top-level error:
    `last_error=xcolo_repeated_protocol_invalid_message`
  - add protocol subreason state for repeated invalid-message failures:
    `xcolo_protocol_invalid_message_reason`
  - for the Run 67 shape, expected subreason is:
    `primary_role_not_entered_after_migrate`
- Repetition control:
  - every next FT test must compare the latest failure against this Run 67
    protocol-role blocker
  - if the same top-level error and same subreason repeat with the same ready
    preconditions, report it immediately as the same repeated blocker before
    another iteration

### Run 68 Retest Readiness 2026-06-04

- Source commit:
  - `e833a9c` (`fix: classify xcolo steady-state protocol failures`)
- Local verification:
  - `bash -n lib/ftctl/xcolo.sh`
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`
  - `git diff --check`
  - targeted selftest:
    - `selftest_case_xcolo_runtime_validation_classifies_repeated_invalid_message`
  - full selftest note:
    - full selftest did not complete because existing shellcheck/backend
      validation warnings/errors stop the current runner before the XCOLO
      runtime cases; the new targeted case passed in isolation
- Build:
  - GitHub Actions run:
    `https://github.com/dhslove/ablestack-qemu-exec-tools/actions/runs/26895838488`
  - result: success
  - downloaded RPM artifact:
    `/home/ablecloud/work/ftctl-artifacts-run-26895838488/ftctl-branch-rpm-26895838488/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `6659a2f910c41b513ffb6f07261253df8f86b63f3956e57e81d8d839023e6137`
  - RPM marker verification passed:
    - `block_conversion.steady_state_gate`
    - `xcolo_protocol_invalid_message_reason`
    - `xcolo_handshake_command_state`
- Deployment:
  - installed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installed package:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
  - installed marker verification passed on all three hosts:
    - `xcolo_steady_state_gate`
    - `xcolo_protocol_invalid_message_reason`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active
    on all three hosts
- Cleanup:
  - removed Run 67 from active protection scope:
    - row `67` now `disabled/stopped`, `removed=2026-06-04 00:48:38`
  - removed FTCTL VM details for `r97-link-01` / `r97-link-01-standby`
  - expunged standby VM:
    - `123` / `i-2-123-VM`
  - expunged standby volumes:
    - `231` / `b96309d5-b10d-4ddd-aa9a-2c54a533768c`
    - `232` / `3d72840a-7a2f-41c7-8cbb-5e53374e4316`
  - removed standby RBD images:
    - `b96309d5-b10d-4ddd-aa9a-2c54a533768c`
    - `3d72840a-7a2f-41c7-8cbb-5e53374e4316`
  - removed stale FTCTL runtime files for `i-2-54-VM` and `i-2-123-VM`
- Final readiness verification:
  - primary VM DB state:
    - `i-2-54-VM`, `Running`, host `3`, power state `PowerOn`
  - active protection rows for primary VM `54`: `0`
  - active FTCTL details for primary/standby scope: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - host runtime:
    - `i-2-54-VM` is running on `10.10.32.3`
    - no Run 67 standby RBD images remain
    - no target FTCTL runtime files remain under the checked state/profile/xml
      paths
    - `query-block-jobs` is empty
    - `query-migrate` is empty
    - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`

### Run 68 Result 2026-06-04-01

- User action:
  - FT protection was started again for `r97-link-01` / `i-2-54-VM`
  - compatible shared block/raw storage was selected
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run68-monitor-20260604-005907.log`
  - final evidence:
    `/home/ablecloud/work/ft-run68-final-20260604-010332`
- Final state:
  - protection row: `68`
  - standby VM: `124` / `i-2-124-VM`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_repeated_protocol_invalid_message`
- Code improvement confirmed:
  - the new post-handshake gate was recorded:
    - `xcolo_handshake_command_state=accepted`
    - `xcolo_steady_state_gate=failed`
  - the repeated invalid-message subreason was recorded:
    - `xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate`
  - therefore Run 68 confirmed the new classifier and did not regress the
    recovery path
- Runtime evidence:
  - primary migration state before recovery:
    - `xcolo_primary_migrate_status=failed`
    - `xcolo_primary_colo_mode=none`
  - secondary migration state:
    - `xcolo_secondary_migrate_status=colo`
    - `xcolo_secondary_colo_mode=secondary`
  - primary QEMU log:
    - `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log:
    - `Can't receive COLO message: Input/output error`
  - qemu FTCTL recovery restored the primary domain:
    - primary VM DB state: `Running`, host `3`, power state `PowerOn`
    - primary libvirt domain `i-2-54-VM` running on `10.10.32.3`
- Repetition control:
  - this is the same protocol-role blocker predicted by design 344
  - no new evidence was produced that reopens storage selection, firewall,
    socket, baseline seed, secondary RBD mapping, or generic filter attachment
    as the active hypothesis
  - next improvement must target QEMU COLO role transition after primary
    migrate, not another generic pre-migrate readiness iteration
- Cleanup note:
  - Run 68 garbage remains at this point:
    - active protection row `68`
    - standby VM `i-2-124-VM`
    - standby volumes `233`, `234`
    - standby RBD images
  - cleanup is required before the next retest

### Run 69 Fix Plan 2026-06-04

- Trigger:
  - Run 68 repeated the Run 67 protocol-role blocker, but now with explicit
    state:
    - `xcolo_handshake_command_state=accepted`
    - `xcolo_steady_state_gate=failed`
    - `xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate`
- Design recorded:
  - [345. FT XCOLO Pre-Migrate Checkpoint Hard Gate Design](345-ft-xcolo-premigrate-checkpoint-hard-gate-design-20260604.md)
  - checkpoint defer guidance in design 320 is marked superseded
- Code direction:
  - move `migrate-set-parameters x-checkpoint-delay` before primary
    `migrate`
  - verify `query-migrate-parameters` returns the expected delay before
    allowing primary `migrate`
  - record:
    - `xcolo_primary_checkpoint_delay_expected`
    - `xcolo_primary_checkpoint_delay_actual`
    - `xcolo_primary_checkpoint_delay_ready`
    - `xcolo_premigrate_primary_checkpoint_delay_ready`
  - stop before primary migrate with
    `last_error=primary_checkpoint_parameter_set_failed` if the setting cannot
    be verified
- Repetition control:
  - if the next run still reaches
    `xcolo_repeated_protocol_invalid_message` with
    `xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate`
    and `xcolo_primary_checkpoint_delay_ready=yes`, then checkpoint setup is
    eliminated as the active cause
  - at that point the next target must be QEMU COLO role-transition timing,
    not storage/firewall/baseline/filter-readiness repetition

### Run 69 Retest Readiness 2026-06-04

- Source commit:
  - `f8be76c` (`fix: gate xcolo migrate on checkpoint delay`)
- Local verification:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - targeted XCOLO selftests: pass
    - checkpoint-before-migrate handshake ordering
    - multi-disk export-before-migrate ordering
    - primary filter binding runtime validation
    - repeated invalid COLO protocol classifier
- GitHub Actions build:
  - run: `26898235513`
  - result: success
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `070ca9f884d2482a0f59399f21477bdc61c99f94bb60f98b511ec3285a18c773`
- RPM marker verification:
  - extracted RPM includes:
    - `primary.migrate_set_parameters.pre_migrate`
    - `xcolo_primary_checkpoint_delay_ready`
    - `query-migrate-parameters`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - installed package on each host:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
  - installed host script markers verified on all three hosts:
    - `primary.migrate_set_parameters.pre_migrate`
    - `xcolo_primary_checkpoint_delay_ready`
    - `query-migrate-parameters`
  - host timers verified active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Run 68 cleanup:
  - active protection row `68`: removed
  - standby VM `i-2-124-VM`: destroyed/undefined on hosts and marked
    `Expunging`
  - standby volumes `233`, `234`: marked `Expunged`
  - standby RBD images removed:
    - `157cd09b-c0ee-4cf5-9fd2-d7344fb6e6c2`
    - `be68efc6-be51-4309-8de4-84b3dffe3539`
  - FTCTL runtime/profile leftovers for `i-2-54-VM` and `i-2-124-VM`:
    removed
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`:
    `not_found`
- Next retest expectation:
  - the next run must show either:
    - pre-migrate checkpoint gate failure before primary migrate, or
    - `xcolo_primary_checkpoint_delay_ready=yes` before any repeated
      `xcolo_repeated_protocol_invalid_message`
  - if the same protocol invalid-message failure repeats with checkpoint ready,
    checkpoint setup is eliminated and the next design target becomes QEMU COLO
    role-transition timing/filter activation around migration.

### Run 69 Result 2026-06-04

- Trigger:
  - user started FT protection registration after Run 69 readiness cleanup
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run69-monitor-20260604-013518.log`
  - final evidence:
    `/home/ablecloud/work/ft-run69-final-20260604-013822`
- Final state:
  - protection row: `69`
  - standby VM: `125` / `i-2-125-VM`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_repeated_protocol_invalid_message`
  - standby VM DB state: `Running`, host `1`, power state `PowerOn`
- Progress confirmed:
  - the pre-migrate checkpoint hard gate worked:
    - `xcolo_primary_checkpoint_delay_expected=2000`
    - `xcolo_primary_checkpoint_delay_actual=2000`
    - `xcolo_primary_checkpoint_delay_ready=yes`
    - `xcolo_primary_checkpoint_delay_pre_migrate=2000`
    - `xcolo_premigrate_primary_checkpoint_delay_ready=yes`
  - pre-migrate readiness was also recorded as ready:
    - `xcolo_premigrate_primary_capability_x_colo=yes`
    - `xcolo_premigrate_primary_capability_return_path=yes`
    - `xcolo_premigrate_primary_filter_qom_ready=yes`
    - `xcolo_premigrate_primary_filter_cmdline_ready=yes`
    - `xcolo_premigrate_primary_filter_chardev_ready=yes`
    - `xcolo_premigrate_channel_mirror_established=yes`
    - `xcolo_premigrate_channel_compare_established=yes`
    - `xcolo_premigrate_channel_compare_local_established=yes`
    - `xcolo_premigrate_channel_compare_out_established=yes`
    - `xcolo_firewall_ready=yes`
- Repeated failure evidence:
  - `xcolo_handshake_command_state=accepted`
  - `xcolo_steady_state_gate=failed`
  - `xcolo_repeated_protocol_invalid_message=yes`
  - `xcolo_repeated_protocol_invalid_message_evidence=premigrate_ready`
  - `xcolo_repeated_protocol_invalid_message_storage_symmetry=ok`
  - `xcolo_protocol_invalid_message_reason=primary_role_not_entered_after_migrate`
  - `xcolo_primary_migrate_status=failed`
  - `xcolo_primary_colo_mode=none`
  - `xcolo_secondary_migrate_status=colo`
  - `xcolo_secondary_colo_mode=secondary`
  - primary QEMU log:
    - `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU log:
    - `Can't receive COLO message: Input/output error`
- Repetition control:
  - this is the same protocol-role blocker as Run 68
  - the checkpoint-delay hypothesis is now eliminated because the gate is
    verified before primary migrate
  - storage symmetry, firewall, socket establishment, baseline seed, secondary
    RBD mapping, and generic pre-migrate readiness are not the next active
    hypothesis
- Next improvement direction:
  - target QEMU COLO role-transition timing/filter activation around
    `primary.migrate`
  - the next code change must explicitly make the migration role transition
    observable and gate on it, instead of cycling through already-verified
    storage/firewall/checkpoint preconditions

### Run 70 Fix Plan 2026-06-04

- Trigger:
  - Run 69 repeated `xcolo_repeated_protocol_invalid_message`, but also proved
    the pre-migrate checkpoint hard gate is working
- Design recorded:
  - [346. FT XCOLO Post-Migrate Filter Activation Gate Design](346-ft-xcolo-post-migrate-filter-activation-gate-design-20260604.md)
- Code direction:
  - keep primary filter objects/topology present before migrate
  - keep primary filter object `status=off` until after `primary.migrate`
  - insert a post-migrate pre-activation gate that captures:
    - primary/secondary migrate status
    - primary/secondary COLO mode
    - invalid-message evidence before filter activation
    - socket snapshot
  - activate primary filters only after that pre-activation gate
  - insert a post-activation gate that captures whether the invalid message
    appears after filter activation
- Required new state split:
  - `xcolo_protocol_failure_phase=pre_filter_activation`
  - or `xcolo_protocol_failure_phase=post_filter_activation`
  - or `xcolo_protocol_failure_phase=role_transition_stalled`
- Repetition control:
  - if the same invalid-message failure occurs without a phase split, the
    implementation is incomplete
  - no further checkpoint/firewall/storage/baseline precondition cycling is
    allowed unless the new phase split shows one of those assumptions regressed

### Run 70 Retest Readiness 2026-06-04

- Source commit:
  - `c0a054f` (`fix: defer xcolo filter activation after migrate`)
- Local verification:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - `git diff --check`: pass
  - targeted XCOLO selftests: pass
    - checkpoint-before-migrate ordering
    - multi-disk export-before-migrate ordering
    - primary filter binding deferred to runtime validation
    - repeated invalid COLO protocol classifier
- GitHub Actions build:
  - run: `26900041917`
  - result: success
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `c4f4c99161237d11f0fb94347363f389dce15bc8ba45e498f7d8a5ea27815ecd`
- RPM marker verification:
  - extracted RPM includes:
    - `xcolo.post_migrate_pre_activation_gate`
    - `xcolo_filter_activation_broke_colo_stream`
    - `xcolo_protocol_failure_phase`
    - `xcolo_primary_filter_status_pre_migrate=off`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - installed host script markers verified on all three hosts:
    - `xcolo.post_migrate_pre_activation_gate`
    - `xcolo_filter_activation_broke_colo_stream`
    - `xcolo_protocol_failure_phase`
  - host timers verified active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Run 69 cleanup:
  - active protection row `69`: removed
  - standby VM `i-2-125-VM`: destroyed/undefined on hosts and marked
    `Expunging`
  - standby volumes `235`, `236`: marked `Expunged`
  - standby RBD images removed:
    - `f225a7ce-8975-44d2-9c73-fefc9fc30701`
    - `45ed56b2-aaa0-4f17-9cf3-d7ac62ccb5b4`
  - FTCTL runtime/profile leftovers for `i-2-54-VM` and `i-2-125-VM`:
    removed
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`:
    `not_found`
- Next retest expectation:
  - if invalid COLO protocol repeats, the result must include
    `xcolo_protocol_failure_phase`
  - acceptable phase values for the next diagnosis:
    - `pre_filter_activation`
    - `post_filter_activation`
    - `role_transition_pre_activation_timeout`
    - `filter_activation_command`

### Run 70 Result 2026-06-04

- Trigger:
  - user started FT protection registration after Run 70 readiness cleanup
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run70-monitor-20260604-125517.log`
  - final evidence:
    `/home/ablecloud/work/ft-run70-final-20260604-125757`
- Final state:
  - protection row: `70`
  - standby VM: `126` / `i-2-126-VM`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_filter_activation_broke_colo_stream`
- Progress confirmed:
  - the new phase split worked
  - pre-activation state:
    - `xcolo_primary_filter_status_pre_activation=off`
    - `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_secondary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_primary_colo_mode=none`
    - `xcolo_post_migrate_pre_activation_secondary_colo_mode=none`
    - `xcolo_post_migrate_pre_activation_invalid_message=no`
    - `xcolo_socket_post_migrate_pre_activation_primary_9998=established`
  - post-activation state:
    - `xcolo_primary_filter_status_post_activation=on`
    - `xcolo_post_migrate_post_activation_primary_migrate_status=failed`
    - `xcolo_post_migrate_post_activation_secondary_migrate_status=colo`
    - `xcolo_post_migrate_post_activation_primary_colo_mode=none`
    - `xcolo_post_migrate_post_activation_secondary_colo_mode=secondary`
    - `xcolo_post_migrate_post_activation_invalid_message=yes`
    - `xcolo_protocol_failure_phase=post_filter_activation`
- QEMU log evidence:
  - primary:
    - `Received invalid message 0x0000 length 0x0000`
  - secondary:
    - `Can't receive COLO message: Input/output error`
- Repetition control:
  - this is not an unclassified repetition
  - the failure moved from generic repeated invalid message to a classified
    post-filter-activation failure
  - checkpoint, storage symmetry, firewall, socket preflight, and migration
    pre-activation stream establishment are not the next active hypothesis
- Next improvement direction:
  - focus on primary filter activation semantics after migration
  - specifically inspect whether `redire0`, `redire1`, and `m0` are being
    activated in the wrong order for this qemu-ablestack COLO path, or whether
    activation must be staged around a primary COLO role transition signal
  - the next code change must not return to storage/firewall/checkpoint
    precondition loops unless this post-activation diagnosis regresses
- Cleanup note:
  - Run 70 garbage remains at this point:
    - active protection row `70`
    - standby VM `i-2-126-VM`
    - standby volumes and RBD images created for Run 70
  - cleanup is required before the next retest

### Run 71 Fix Plan 2026-06-04

- Design document:
  - `347-ft-xcolo-staged-filter-activation-order-design-20260604.md`
- Reason:
  - Run 70 proved that the COLO stream is valid before primary filter
    activation and breaks only after filters are switched on
  - the previous order `redire0 -> redire1 -> m0` enables the compare-output
    return path before the compare input and mirror paths are both stable
- Code direction:
  - activate filters in staged order:
    - `redire1`
    - `m0`
    - `redire0`
  - after each step, capture:
    - primary/secondary migrate status
    - primary/secondary COLO mode
    - primary migrate error description
    - invalid-message presence
    - socket snapshot
  - if the repeated invalid-message error appears again, record:
    - `xcolo_filter_activation_failed_step=<step>`
    - `xcolo_protocol_failure_phase=filter_activation_<step>`
    - `last_error=xcolo_filter_activation_<step>_broke_colo_stream`
- Repetition control:
  - if the same QEMU error repeats without a failed activation step, the fix is
    incomplete
  - do not return to checkpoint/firewall/storage/socket precondition changes
    unless the new per-step evidence shows one of those assumptions regressed

### Run 71 Retest Readiness 2026-06-04

- Source commit built:
  - `bed56bb` (`fix: stage xcolo filter activation diagnostics`)
- Local verification:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - `git diff --check`: pass
  - targeted XCOLO selftests: pass
    - checkpoint-before-migrate ordering
    - multi-disk export-before-migrate ordering
    - staged filter activation failed-step classifier
    - primary filter binding deferred to runtime validation
    - repeated invalid COLO protocol classifier
- GitHub Actions build:
  - run: `26930959064`
  - result: success
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `38771298103b4663f28823dcf9bb3df6f96b94b35e4ae752f64f97c924c35793`
- RPM marker verification:
  - extracted RPM includes:
    - `xcolo.filter_activation_step`
    - `xcolo_filter_activation_failed_step`
    - `redire1,m0,redire0`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - installed host script markers verified on all three hosts:
    - `redire1,m0,redire0`
    - `xcolo_filter_activation_failed_step`
  - host timers verified active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Run 70 cleanup:
  - active protection row `70`: removed
  - standby VM `126` / `i-2-126-VM`: destroyed/undefined on hosts and marked
    `Expunging`
  - standby volumes `237`, `238`: marked `Expunged`
  - standby RBD images removed:
    - `7a900119-c499-4ecb-ac64-1d0fb1a56679`
    - `66e83b2d-3a20-4759-b8fa-ac3bc5aa26b6`
  - FTCTL runtime/profile leftovers for `i-2-54-VM` and `i-2-126-VM`:
    removed
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`:
    `not_found`
- Next retest expectation:
  - if `Received invalid message 0x0000 length 0x0000` repeats, the result must
    include:
    - `xcolo_filter_activation_failed_step`
    - `xcolo_protocol_failure_phase=filter_activation_<step>`
  - this run must distinguish whether `redire1`, `m0`, or `redire0` breaks the
    COLO stream

### Run 71 Result 2026-06-04

- Trigger:
  - user started FT protection registration after Run 71 readiness cleanup
- Evidence:
  - initial monitor log:
    `/home/ablecloud/work/ft-run71-monitor-20260604-134649.log`
  - final monitor log:
    `/home/ablecloud/work/ft-run71-monitor2-20260604-134739.log`
  - final evidence directory:
    `/home/ablecloud/work/ft-run71-final2-20260604-134739`
- Final state:
  - protection row: `71`
  - standby VM: `127` / `i-2-127-VM`
  - standby volumes:
    - `239` / `5d3bfa1e-b782-4c98-9033-304d954f73c1`
    - `240` / `237e3dcb-151b-425b-8ca4-89fc58915b2e`
  - `protection_state=error`
  - `transport_state=failed`
  - Cloud-side last error:
    `Unable to register FTCTL protection for VM d08503ff-ea56-4e35-bdf8-2f0ebf81382c: timeout`
  - FTCTL host-side last error:
    `xcolo_filter_activation_redire1_broke_colo_stream`
- Progress confirmed:
  - the staged activation classifier worked
  - pre-activation stream was still valid:
    - `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_secondary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_invalid_message=no`
    - `xcolo_socket_post_migrate_pre_activation_primary_9998=established`
  - first activation step:
    - `xcolo_primary_net_filters_activation_order=redire1,m0,redire0`
    - `xcolo_filter_activation_step=redire1`
    - `xcolo_filter_activation_failed_step=redire1`
    - `xcolo_protocol_failure_phase=filter_activation_redire1`
    - `xcolo_filter_activation_redire1_primary_migrate_status=failed`
    - `xcolo_filter_activation_redire1_secondary_migrate_status=colo`
    - `xcolo_filter_activation_redire1_primary_migrate_error_desc=Received invalid message 0x0000 length 0x0000`
    - `xcolo_filter_activation_redire1_invalid_message=yes`
- QEMU log evidence:
  - secondary:
    - `Can't receive COLO message: Input/output error`
  - primary migrate error:
    - `Received invalid message 0x0000 length 0x0000`
- Repetition control:
  - this is not a blind repeat of Run 70
  - Run 70 classified the failure as post-filter-activation
  - Run 71 narrowed that to the first filter activation step, `redire1`
  - the next active hypothesis is not checkpoint, storage, firewall, baseline
    seeding, or generic socket reachability
- Next improvement direction:
  - focus on `redire1` RX redirect activation semantics
  - validate whether `redire1` can be enabled only after a stronger secondary
    COLO readiness signal than `query-migrate status=active`
  - inspect whether primary `redire1 outdev=compare0` is wired to a chardev
    endpoint that is still in listener/not-yet-bound state at activation time
  - if QEMU requires compare input to be active only after secondary has entered
    `colo` mode, add a gate before `redire1`
  - if `redire1` activation itself always breaks the stream in this topology,
    the next design must test reversing the RX activation model rather than
    cycling through storage/firewall/checkpoint fixes
- Cleanup note:
  - Run 71 garbage remains at this point:
    - active protection row `71`
    - standby VM `i-2-127-VM`
    - standby volumes `239`, `240`
    - standby RBD images listed above
  - cleanup is required before the next retest

### Run 72 Fix Plan 2026-06-04

- Design document:
  - `348-ft-xcolo-pre-redire1-activation-gate-design-20260604.md`
- Reason:
  - Run 71 narrowed the repeated invalid-message failure to the first filter
    activation step, `redire1`
  - pre-activation migration/socket state was valid before `redire1`
  - therefore the next fix must protect the `redire1` readiness boundary
- Code direction:
  - add a strict pre-redire1 gate before
    `qom-set /objects/redire1 status=on`
  - require:
    - primary migrate status `active`
    - secondary migrate status `colo`
    - secondary COLO mode `secondary`
    - no invalid-message before redire1
    - strict primary chardev binding ready, not `accepted_closed`
    - primary compare channels established
  - if the gate does not pass, do not activate `redire1`
  - classify the failure as:
    - `xcolo_protocol_failure_phase=pre_redire1_gate`
    - `xcolo_filter_activation_failed_step=redire1`
    - `last_error=xcolo_redire1_activation_prerequisite_timeout`
- Repetition control:
  - the next run must either pass the pre-redire1 gate or report the exact
    missing prerequisite
  - if the gate passes and `redire1` still breaks the stream, the next target is
    the `redire1 outdev=compare0` topology itself

### Run 72 Retest Readiness 2026-06-04

- Source commit built:
  - `56fcc40` (`fix: gate redire1 xcolo activation readiness`)
- Local verification:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - `git diff --check`: pass
  - targeted XCOLO selftests: pass
    - checkpoint-before-migrate ordering
    - multi-disk export-before-migrate ordering
    - staged filter activation failed-step classifier
    - pre-redire1 gate blocks early activation
    - primary filter binding deferred to runtime validation
    - repeated invalid COLO protocol classifier
- GitHub Actions build:
  - run: `26932125476`
  - result: success
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `dd0ae0b85598bc88ea8e1f51bafa907e8f141af46d22d53bc094d50c0c89a693`
- RPM marker verification:
  - extracted RPM includes:
    - `xcolo.pre_redire1_gate`
    - `xcolo_redire1_activation_prerequisite_timeout`
    - `ftctl_xcolo_gate_before_redire1_activation`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - installed host script markers verified on all three hosts:
    - `xcolo.pre_redire1_gate`
    - `xcolo_redire1_activation_prerequisite_timeout`
  - host timers verified active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Run 71 cleanup:
  - active protection row `71`: removed
  - standby VM `127` / `i-2-127-VM`: destroyed/undefined on hosts and marked
    `Expunging`
  - standby volumes `239`, `240`: marked `Expunged`
  - standby RBD images removed:
    - `5d3bfa1e-b782-4c98-9033-304d954f73c1`
    - `237e3dcb-151b-425b-8ca4-89fc58915b2e`
  - FTCTL runtime/profile leftovers for `i-2-54-VM` and `i-2-127-VM`:
    removed
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`:
    `not_found`
- Next retest expectation:
  - if secondary/compare readiness is not sufficient, the next failure should
    be classified as `xcolo_protocol_failure_phase=pre_redire1_gate`
  - expected diagnostic keys include:
    - `xcolo_pre_redire1_gate_reason`
    - `xcolo_pre_redire1_secondary_migrate_status`
    - `xcolo_pre_redire1_secondary_colo_mode`
    - `xcolo_pre_redire1_chardev_ready`
  - if the gate passes and `redire1` still breaks the stream, the next target is
    `redire1 outdev=compare0` topology rather than timing

### Run 72 Result 2026-06-04

- Trigger:
  - user started FT protection registration after Run 72 readiness cleanup
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run72-monitor-20260604-142437.log`
  - final evidence directory:
    `/home/ablecloud/work/ft-run72-final-20260604-142437`
  - extra evidence:
    `/home/ablecloud/work/ft-run72-final-extra-20260604-142616/extra-evidence.log`
- Final state:
  - protection row: `72`
  - standby VM: `128` / `i-2-128-VM`
  - standby volumes:
    - `241` / `fabdab34-d577-41a7-985f-7e8a7f3c3af1`
    - `242` / `7b54484b-3c45-461c-92cd-17c2799e5584`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_redire1_activation_prerequisite_failed`
- Progress confirmed:
  - pre-redire1 gate was executed
  - no Run 72 event shows `primary.filter_status_on.redire1`
  - therefore `redire1` was not activated in this run
  - post-migrate pre-activation was still valid:
    - `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_secondary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_invalid_message=no`
    - `xcolo_socket_post_migrate_pre_activation_primary_9998=established`
  - pre-redire1 gate saw the stream already broken:
    - `xcolo_pre_redire1_gate=failed`
    - `xcolo_protocol_failure_phase=pre_redire1_gate`
    - `xcolo_pre_redire1_gate_reason=invalid_message_before_redire1`
    - `xcolo_pre_redire1_primary_migrate_status=failed`
    - `xcolo_pre_redire1_secondary_migrate_status=colo`
    - `xcolo_pre_redire1_secondary_colo_mode=secondary`
    - `xcolo_pre_redire1_primary_migrate_error_desc=Received invalid message 0x0000 length 0x0000`
    - `xcolo_pre_redire1_invalid_message=yes`
  - strict chardev check also failed at pre-redire1:
    - `xcolo_pre_redire1_chardev_ready=no`
    - `xcolo_pre_redire1_chardev_reason=mirror0:frontend_closed,compare0:frontend_closed,compare_out0:frontend_closed`
- QEMU log evidence:
  - primary:
    - QEMU waited for `compare1` listener connection
    - then reported `Received invalid message 0x0000 length 0x0000`
  - secondary:
    - `Can't receive COLO message: Input/output error`
- Repetition control:
  - this is not the same result as Run 71
  - Run 71 failed after `redire1` activation
  - Run 72 failed before `redire1` activation
  - the gate prevented qom-set, so the remaining failure is in the interval
    between post-migrate pre-activation and pre-redire1 readiness
- Next improvement direction:
  - superseded by the Run 73 fix plan below after code review
  - do not keep delaying `redire1` until secondary reaches `colo`; that lets
    the stream fail before any filter activation
  - replace the permissive post-migrate pre-activation gate
    `secondary_migrate=active|colo` with a tighter role-transition sequence
    that does not leave QEMU in an unsupported no-filter/no-role window
  - likely candidate:
    - prepare strict chardev readiness immediately after `primary.migrate`
    - activate `redire1` during the narrow window while primary migrate is
      still `active` and before primary reports invalid-message
    - then verify secondary reaches `colo`
  - if strict chardevs stay closed before activation, investigate whether
    `status=off` filter objects intentionally keep those frontend chardevs
    closed; in that case strict chardev readiness cannot be a precondition for
    `redire1`
- Cleanup note:
  - Run 72 garbage remains at this point:
    - active protection row `72`
    - standby VM `i-2-128-VM`
    - standby volumes `241`, `242`
    - standby RBD images listed above
  - cleanup is required before the next retest

### Run 73 Fix Plan 2026-06-04

- Design document:
  - `349-ft-xcolo-fast-redire1-activation-gate-design-20260604.md`
- Repetition control:
  - this is not a blind repeat of Run 71 or Run 72
  - Run 71 failed after `redire1` activation
  - Run 72 failed before `redire1` activation because the strict wait allowed
    the stream to break before `redire1`
  - the next run must prove whether fast cached activation reaches
    `primary.filter_status_on.redire1`
- Code direction:
  - replace the strict polling pre-redire1 gate with
    `fast_cached_post_migrate`
  - use cached `xcolo_post_migrate_pre_activation_*` values from the previous
    post-migrate gate
  - allow secondary migrate status `active` or `colo`
  - do not wait for secondary COLO mode `secondary` before `redire1`
  - do not require strict chardev frontend readiness before `redire1`; record
    it as deferred evidence because `status=off` filters can keep frontends
    closed
  - keep activation order `redire1 -> m0 -> redire0`
- Expected diagnostic distinction:
  - if no `primary.filter_status_on.redire1` event appears, inspect
    `xcolo_pre_redire1_gate_reason` and cached prerequisite keys
  - if `primary.filter_status_on.redire1` appears and the same QEMU protocol
    error returns, the next target is `redire1` topology or compare channel
    direction, not another wait loop

### Run 73 Retest Readiness 2026-06-04

- Source commit built:
  - `9d27797` (`fix: fast gate xcolo redire1 activation`)
- Local verification:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - `git diff --check`: pass
  - targeted XCOLO selftests: pass
    - checkpoint-before-migrate ordering
    - multi-disk export-before-migrate ordering
    - staged filter activation failed-step classifier
    - fast pre-redire1 gate allows secondary `active`
    - primary filter binding deferred to runtime validation
    - repeated invalid COLO protocol classifier
- GitHub Actions build:
  - run: `26933405464`
  - head SHA: `9d27797242674107a8148fd4569c12524b41b28b`
  - RPM build and artifact upload: pass
  - workflow conclusion: failure at release-publish step after artifact upload
  - deployment RPM source: Actions artifact from the same run
  - RPM SHA256:
    `ad0b98e5c8e0a916c0168ad2d13efcb7104d2fd2b3d0a1122d07054983a91ad9`
- RPM marker verification:
  - extracted RPM includes:
    - `fast_cached_post_migrate`
    - `xcolo_redire1_fast_activation_prerequisite_failed`
    - `xcolo_pre_redire1_strict_chardev_deferred=yes`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - installed host script markers verified on all three hosts:
    - `fast_cached_post_migrate`
    - `xcolo_redire1_fast_activation_prerequisite_failed`
    - `xcolo_pre_redire1_strict_chardev_deferred=yes`
  - host timers verified active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Run 72 cleanup:
  - active protection row `72`: removed and marked `disabled/stopped`
  - standby VM `128` / `i-2-128-VM`: destroyed/undefined and marked
    `Expunging`
  - standby volumes `241`, `242`: marked `Expunged`
  - standby RBD images removed:
    - `fabdab34-d577-41a7-985f-7e8a7f3c3af1`
    - `7b54484b-3c45-461c-92cd-17c2799e5584`
  - FTCTL runtime/profile leftovers for `i-2-54-VM`, `i-2-128-VM`, and
    `r97-link-01`: removed
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - active `ftctl.*` details for VM `54` or `128`: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`:
    `not_found`
  - target Run72 standby RBD images: absent
- Next retest expectation:
  - Run 73 must show whether `primary.filter_status_on.redire1` is reached
    with the fast cached gate
  - if the same QEMU invalid-message signature returns after `redire1`, the
    next design must target filter topology or compare channel direction, not
    another wait loop

### Run 73 Result 2026-06-04

- Trigger:
  - user started FT protection registration after Run 73 readiness cleanup
- Evidence:
  - monitor log:
    `/home/ablecloud/work/ft-run73-monitor-20260604-150015.log`
  - final evidence directory:
    `/home/ablecloud/work/ft-run73-final-20260604-150405`
- Final state:
  - protection row: `73`
  - standby VM: `129` / `i-2-129-VM`
  - standby volumes:
    - `243` / `ef6a84ce-4095-4f9b-871a-7007eb906129`
    - `244` / `90400d87-7f34-43fb-bb5f-1fb6cb4fbab8`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_filter_activation_redire1_broke_colo_stream`
- Progress confirmed:
  - this is not a repeat of Run 72
  - Run 72 failed before `redire1`
  - Run 73 fast gate reached and passed:
    - `xcolo_pre_redire1_gate=ready`
    - `xcolo_pre_redire1_gate_mode=fast_cached_post_migrate`
    - `xcolo_pre_redire1_primary_migrate_status=active`
    - `xcolo_pre_redire1_secondary_migrate_status=active`
    - `xcolo_pre_redire1_invalid_message=no`
    - `xcolo_pre_redire1_strict_chardev_deferred=yes`
  - post-migrate pre-activation evidence was valid:
    - `xcolo_post_migrate_pre_activation_primary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_secondary_migrate_status=active`
    - `xcolo_post_migrate_pre_activation_invalid_message=no`
    - `xcolo_socket_post_migrate_pre_activation_primary_9998=established`
  - after `redire1` activation, the stream failed:
    - `xcolo_filter_activation_step=redire1`
    - `xcolo_filter_activation_failed_step=redire1`
    - `xcolo_protocol_failure_phase=filter_activation_redire1`
    - `xcolo_filter_activation_redire1_primary_migrate_status=failed`
    - `xcolo_filter_activation_redire1_secondary_migrate_status=colo`
    - `xcolo_filter_activation_redire1_primary_migrate_error_desc=Received invalid message 0x0000 length 0x0000`
    - `xcolo_filter_activation_redire1_invalid_message=yes`
- QEMU log evidence:
  - primary:
    - `Received invalid message 0x0000 length 0x0000`
  - secondary:
    - `Can't receive COLO message: Input/output error`
- Repetition control:
  - this is the repeated QEMU protocol signature, but it is a new reached
    stage versus Run 72
  - waiting/gating is no longer the active hypothesis
  - the next improvement must target the primary/secondary network filter
    topology, especially the `redire1` RX path and compare channel direction
- Cleanup note:
  - Run 73 garbage remains at this point:
    - active protection row `73`
    - standby VM `i-2-129-VM`
    - standby volumes `243`, `244`
    - standby RBD images listed above
  - cleanup is required before the next retest

### Run 74 Fix Plan 2026-06-04

- Design document:
  - `350-ft-xcolo-premigrate-active-filter-topology-design-20260604.md`
- Reason:
  - Run 73 proved that waiting/gating was no longer the active hypothesis
  - the QEMU protocol stream failed exactly when dormant `redire1` was enabled
    after `primary.migrate`
  - QEMU COLO documentation describes the primary/secondary network filter
    topology as present before `migrate`
- Change direction:
  - remove `status=off` from generated primary COLO filters
  - create QMP fallback filter objects active by default
  - require primary filter QOM status `on` before `primary.migrate`
  - keep post-migrate filter handling as validation only
  - do not emit `primary.filter_status_on.redire1`, `primary.filter_status_on.m0`,
    or `primary.filter_status_on.redire0` in the normal enable path
- Repetition gate:
  - if the same QEMU `Received invalid message 0x0000 length 0x0000` signature
    returns without any post-migrate `primary.filter_status_on.*` event, the
    next issue is topology/wiring, not activation timing
  - if `primary.filter_status_on.*` still appears, this fix was not actually
    installed or the dormant-filter path was incorrectly used

### Run 74 Build Deploy Cleanup Readiness 2026-06-04

- Source commit:
  - `b9b66dc` (`fix: start xcolo filters before migrate`)
- Local validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed
  - `git diff --check`: passed
  - targeted XCOLO selftests passed:
    - `selftest_case_xcolo_and_xml`
    - `selftest_case_xcolo_block_handshake_sets_checkpoint_before_migrate`
    - `selftest_case_xcolo_multi_disk_handshake_exports_all_disks`
    - `selftest_case_xcolo_virtio_vnet_hdr_support`
  - full selftest still stops at pre-existing shellcheck warnings before the
    functional cases run
- GitHub Actions:
  - run: `26935917118`
  - workflow: `FTCTL Branch Development Release`
  - result: success
  - head SHA: `b9b66dcafc5c700ae21a6d23270494bd4791d288`
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `d7cd0d4aef2ff543418a5708dfa2800e0827044a46fa6e952e1bc8326fe143d8`
- RPM marker verification:
  - installed/extracted script contains:
    - `xcolo_primary_net_filters_activation_mode=startup-active`
    - `xcolo_primary_filter_activation_stage=premigrate_active`
    - `post_migrate_startup_active`
  - `status=off` remains only in:
    - generated command-line guard that rejects dormant startup filters
    - dormant staged activation helper retained for historical repair testing
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - all hosts report `ablestack_vm_ftctl-0.8.0-1.noarch`
  - all hosts have `ablestack-vm-ftctl.timer=active`
  - all hosts have `ablestack-vm-hangctl.timer=active`
- Cleanup:
  - active protection row `73` removed/disabled:
    - `protection_state=disabled`
    - `transport_state=stopped`
    - `last_error=test_cleanup_after_premigrate_active_filter_fix`
  - standby VM `129` / `i-2-129-VM` marked `Expunging`, removed timestamp set
  - standby volumes `243`, `244` marked `Expunged`, removed timestamp set
  - standby RBD images removed:
    - `ef6a84ce-4095-4f9b-871a-7007eb906129`
    - `90400d87-7f34-43fb-bb5f-1fb6cb4fbab8`
  - FTCTL runtime/profile files for `i-2-54-VM`, `i-2-129-VM`, and
    `r97-link-01` removed
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - active `ftctl.*` details for VM `54` or `129`: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`: `not_found`
- Next retest expectation:
  - normal path must not emit `primary.filter_status_on.redire1`,
    `primary.filter_status_on.m0`, or `primary.filter_status_on.redire0`
  - if the QEMU invalid-message signature repeats without those events, report
    it as a topology/wiring issue, not another activation timing issue

### Run 75 Fix Plan 2026-06-04

- Design document:
  - `351-ft-xcolo-return-path-topology-audit-design-20260604.md`
- Reason:
  - Run 74 proved the premigrate-active topology was installed
  - no normal-path `primary.filter_status_on.*` event was emitted
  - the same QEMU protocol signature still occurred after sockets had been
    established
  - therefore the next active hypothesis is return-path/topology wiring, not
    filter activation timing
- Change direction:
  - keep the premigrate-active startup topology from design 350
  - add a combined topology audit before `primary.migrate`
  - validate secondary commandline topology in addition to the existing primary
    checks
  - capture primary and secondary QEMU command lines in the XCOLO debug
    directory
  - capture primary and secondary libvirt/QEMU log tails in the XCOLO debug
    directory
  - classify repeated invalid-message failures with narrower subreasons:
    - `topology_audit_failed`
    - `return_path_protocol_closed_after_startup_active`
    - `qemu_return_path_invalid_zero_header`
- Repetition gate:
  - if the next run blocks before `primary.migrate` with
    `xcolo_topology_audit_failed`, this is progress because a concrete topology
    mismatch was found
  - if the next run repeats the invalid-message signature with
    `xcolo_topology_audit=ok`, the next target must be QEMU return-path
    protocol semantics or QEMU runtime parity
  - do not return to wait-loop, checkpoint-delay, or post-migrate filter
    activation timing changes unless new evidence contradicts Run 74

### Run 75 Build Deploy Cleanup Readiness 2026-06-04

- Source commit built and deployed:
  - `4d5dbb6` (`fix: audit xcolo return path topology`)
- Local validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed
  - `git diff --check`: passed
  - direct PowerShell `shellcheck`: not available in the local shell
  - full selftest remains blocked by pre-existing shellcheck warnings before
    functional cases run
- GitHub Actions:
  - run: `26939390717`
  - workflow: `FTCTL Branch Development Release`
  - source commit: `4d5dbb664a71f842525206388cc4afdc369f5996`
  - RPM build and artifact upload: passed
  - release publish step: failed with GitHub secondary rate limit after artifact
    upload
  - deployed artifact source: run artifact from `26939390717`
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `b90f1eab3c2115b92c9ca5baab1e29aa6c7bef52edcda19fe3c3b4e66162bbb9`
- Deployment:
  - deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - all hosts report:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
  - installed script markers verified on all three hosts:
    - `ftctl_xcolo_require_topology_audit_ready`
    - `return_path_protocol_closed_after_startup_active`
    - `secondary-qemu-process-cmdline.txt`
  - all hosts have:
    - `ablestack-vm-ftctl.timer=active`
    - `ablestack-vm-hangctl.timer=active`
- Run 74 cleanup:
  - protection row `74` removed/disabled:
    - `admin_state=inactive`
    - `protection_state=disabled`
    - `transport_state=stopped`
    - `removed=2026-06-04 17:18:17`
    - `last_error=test_cleanup_after_return_path_topology_audit_fix`
  - standby VM `130` / `i-2-130-VM`:
    - `state=Expunging`
    - `removed=2026-06-04 17:18:17`
    - `power_state=PowerOff`
  - standby volumes `245`, `246`:
    - `state=Expunged`
    - `removed=2026-06-04 17:18:17`
  - active `ftctl.*` details for VM `54` or `130`: `0`
  - stale runtime/profile/debug files for `i-2-54-VM`, `i-2-130-VM`, and
    `r97-link-01`: removed from the three hosts
  - target Run74 standby RBD images removed:
    - `fdc548bc-4a7b-4ad4-848f-66af4f3ee247`
    - `846ed980-465b-46ca-9fe8-85bb28d765d8`
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`: `not_found`
- Next retest expectation:
  - if protection blocks before `primary.migrate`, inspect
    `xcolo_topology_audit` and `xcolo_topology_audit_reason`
  - if the invalid-message signature repeats, inspect
    `xcolo_protocol_invalid_message_reason`
  - expected new debug artifacts on failure:
    - `primary-qemu-process-cmdline.txt`
    - `secondary-qemu-process-cmdline.txt`
    - `primary-qemu-log-tail.txt`
    - `secondary-qemu-log-tail.txt`

### Run 75 Result 2026-06-04

- Result:
  - failed
- Protection row:
  - `75`
  - UUID: `af83d73b-2ef4-4014-940f-940db0ba86c4`
  - primary VM: `54` / `i-2-54-VM`
  - secondary VM: `131` / `i-2-131-VM`
- Cloud DB state:
  - `admin_state=active`
  - `protection_state=error`
  - `transport_state=failed`
  - `active_side=primary`
  - `last_error=xcolo_startup_active_filter_stream_failed`
- Progress versus Run 74:
  - topology audit executed and returned `xcolo_topology_audit=ok`
  - secondary QEMU command line was captured
  - primary and secondary QEMU log tails were captured
  - 9003/9004/9998 paths were observable
- Repeated QEMU signature:
  - primary:
    - `filter mirror send failed(Operation not permitted)`
    - `Received invalid message 0x0000 length 0x0000`
  - secondary:
    - `Can't receive COLO message: Input/output error`
- SELinux/firewall observation:
  - SELinux was `Permissive` on both involved hosts
  - no matching AVC denial was found for the failure window
  - firewalld/nftables were active, but FT port allow rules and packet counters
    existed for the relevant ports
- Repetition control:
  - this is the same protocol failure family as the previous invalid-message
    runs, but the earliest high-signal log is now
    `filter mirror send failed(Operation not permitted)`
  - do not treat the next failure as a new generic timing issue if this exact
    signature repeats
  - the next improvement must classify and persist the primary filter-mirror
    write-path failure before returning from post-migrate startup-active
    validation
- Cleanup note:
  - Run 75 garbage remains before the next fix deployment:
    - active protection row `75`
    - standby VM `i-2-131-VM`
    - standby RBD images observed in secondary command line:
      - `0ad767dc-e5f2-4cca-bee3-517d7c14a2ec`
      - `f6aced3f-ae77-4df1-9ca3-c1fc93c2fe04`
  - cleanup is required before the next retest

### Run 76 Fix Plan 2026-06-04

- Design document:
  - `352-ft-xcolo-filter-mirror-eperm-diagnostics-design-20260604.md`
- Reason:
  - Run 75 proved topology audit can pass while QEMU still fails on the
    primary mirror write path
  - the `filter mirror send failed(Operation not permitted)` log is earlier and
    more specific than the later invalid zero-message header
- Change direction:
  - keep the premigrate-active topology and topology audit from designs 350 and
    351
  - classify `filter mirror send failed(Operation not permitted)` as
    `xcolo_filter_mirror_send_eperm`
  - persist the failing path as `primary:m0->mirror0->secondary:red0`
  - collect chardev, socket, policy, and QEMU log evidence before returning
    failure from `ftctl_xcolo_activate_primary_filters_after_migrate`
- Repetition gate:
  - if the next run repeats the same signature and reports
    `xcolo_filter_mirror_send_eperm`, this is diagnostic progress
  - if the next run still reports only
    `xcolo_startup_active_filter_stream_failed`, the fix did not cover the
    actual early return path

### Run 76 Build Deploy Cleanup Readiness 2026-06-04

- Source commit built and deployed:
  - `bc677d9` (`fix: classify xcolo mirror eperm failures`)
- Local validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed
  - `git diff --check`: passed
  - full selftest still stops at pre-existing shellcheck warnings before the
    functional cases run
  - a focused selftest case was added for startup-active
    `filter_mirror_send_eperm` classification
- GitHub Actions:
  - run: `26955017185`
  - workflow: `FTCTL Branch Development Release`
  - result: success
  - source commit: `bc677d9e`
  - RPM: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `77b0db802c797ad063e7d6b5dd01dd1c76e08b92589e9020e5073af663e6bb03`
- RPM marker verification:
  - extracted RPM script contains:
    - `ftctl_xcolo_classify_startup_active_stream_failure`
    - `xcolo_filter_mirror_send_eperm`
    - `primary-query-chardev`
    - `secondary-query-chardev`
    - `primary-policy`
    - `secondary-policy`
- Deployment:
  - deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - all hosts report:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
  - all hosts have:
    - `ablestack-vm-ftctl.timer=active`
    - `ablestack-vm-hangctl.timer=active`
  - installed host scripts contain the new EPERM/chardev/policy markers
- Run 75 cleanup:
  - protection row `75` removed/disabled:
    - `admin_state=inactive`
    - `protection_state=disabled`
    - `transport_state=stopped`
    - `removed=2026-06-04 22:39:50`
    - `last_error=test_cleanup_after_filter_mirror_eperm_fix`
  - standby VM `131` / `i-2-131-VM`:
    - `state=Expunging`
    - `removed=2026-06-04 22:39:50`
    - `power_state=PowerOff`
  - standby volumes `247`, `248`:
    - `state=Expunged`
    - `removed=2026-06-04 22:39:50`
  - active `ftctl.*` details for VM `54` or `131`: `0`
  - stale runtime/profile/debug files for `i-2-54-VM`, `i-2-131-VM`, and
    `r97-link-01`: removed from the three hosts
  - target Run75 standby RBD images removed:
    - `0ad767dc-e5f2-4cca-bee3-517d7c14a2ec`
    - `f6aced3f-ae77-4df1-9ca3-c1fc93c2fe04`
- Final readiness:
  - primary VM `54` / `i-2-54-VM`:
    - DB state: `Running`
    - host id: `3`
    - power state: `PowerOn`
    - libvirt state on `10.10.32.3`: `running`
  - active protection rows for primary VM `54`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`: `not_found`
- Next retest expectation:
  - if the same QEMU signature repeats, `last_error` should now be
    `xcolo_filter_mirror_send_eperm`
  - debug evidence should include chardev query files and policy snapshots for
    the post-migrate failure phase

### Run 76 Monitor Result And Chardev Contract Direction 2026-06-04

- Run 76 repeated the same QEMU symptom but with better classification:
  - `last_error=xcolo_filter_mirror_send_eperm`
  - primary QEMU:
    - `filter mirror send failed(Operation not permitted)`
    - `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU:
    - `Can't receive COLO message: Input/output error`
- This is diagnostic progress compared with the older generic
  `xcolo_startup_active_filter_stream_failed` result.
- The new evidence moved the boundary from TCP reachability to QEMU chardev
  frontend state:
  - `xcolo_socket_post_migrate_startup_active_validation_primary_9003=listen`
  - `xcolo_socket_post_migrate_startup_active_validation_secondary_9003=established`
  - `xcolo_socket_post_migrate_startup_active_validation_primary_9004=listen`
  - `xcolo_socket_post_migrate_startup_active_validation_secondary_9004=established`
  - but failure-time QMP showed:
    - `xcolo_failure_primary_chardev_mirror0=present_closed`
    - `xcolo_failure_primary_chardev_compare1=present_open`
    - `xcolo_failure_secondary_chardev_red0=present_open`
    - `xcolo_failure_secondary_chardev_red1=present_closed`
- Repetition control:
  - do not return to storage symmetry, checkpoint delay, or generic firewall
    theories unless new evidence contradicts the Run 76 record
  - the next implementation must verify the COLO chardev contract directly:
    - `primary m0 -> mirror0 -> secondary red0 -> f1`
    - `secondary f2 -> red1 -> primary compare1 -> comp0`
  - if the same QEMU signature appears again, the test report must explicitly
    include:
    - `xcolo_chardev_contract_ready`
    - `xcolo_chardev_contract_reason`
    - `xcolo_chardev_contract_mirror_path`
    - `xcolo_chardev_contract_compare_path`
- Design recorded:
  - `docs/ftctl/353-ft-xcolo-chardev-contract-gate-design-20260604.md`
- Expected next useful result:
  - FT reaches steady state, or
  - the attempt fails earlier as `xcolo_colo_chardev_contract_not_ready`, or
  - EPERM repeats but the report identifies the exact closed chardev edge.
