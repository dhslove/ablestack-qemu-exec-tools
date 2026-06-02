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
