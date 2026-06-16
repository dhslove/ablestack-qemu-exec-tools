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

### Chardev Contract Gate Build Deploy Cleanup Readiness 2026-06-04

- Source commit built and deployed:
  - `1b0a581` (`fix: gate xcolo chardev contract readiness`)
- Design and implementation:
  - added `docs/ftctl/353-ft-xcolo-chardev-contract-gate-design-20260604.md`
  - added QMP contract capture for:
    - `primary m0 -> mirror0 -> secondary red0 -> f1`
    - `secondary f2 -> red1 -> primary compare1 -> comp0`
  - persisted report fields:
    - `xcolo_chardev_contract_ready`
    - `xcolo_chardev_contract_reason`
    - `xcolo_chardev_contract_mirror_path`
    - `xcolo_chardev_contract_compare_path`
  - startup-active validation now briefly waits for the contract and either:
    - reports `xcolo_colo_chardev_contract_not_ready`, or
    - preserves `xcolo_filter_mirror_send_eperm` with contract details if QEMU
      already reached the EPERM/invalid-message failure.
- Local validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed
  - `git diff --check`: passed
  - full selftest still stops at pre-existing shellcheck warnings
  - focused harness for the Run76 chardev pattern passed:
    - `ready=no`
    - `mirror_path_primary_mirror0=present_closed`
    - `compare_path_secondary_red1=present_closed`
- GitHub Actions:
  - run: `26958027782`
  - workflow: `FTCTL Branch Development Release`
  - result: success
  - source commit: `1b0a581c9ead6593b77dea71120ced691d6871fd`
  - RPM SHA256:
    `72b044de2c2b7a0e50d00b0bafab159757267d5300caba0c223f1303d1c09604`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - all hosts report:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
    - `ablestack-vm-ftctl.timer=active`
    - `ablestack-vm-hangctl.timer=active`
  - installed scripts contain:
    - `ftctl_xcolo_capture_colo_chardev_contract`
    - `xcolo_chardev_contract_ready`
    - `xcolo_colo_chardev_contract_not_ready`
- Run76 cleanup:
  - protection row `76`: removed/disabled
  - active protection rows for VM `54`: `0`
  - active `ftctl.*` details for VM `54` or `132`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - standby VM `132` set to `Expunging`
  - standby volumes `249`, `250` set to `Expunged`
  - standby RBD images removed:
    - `0214d02b-56c0-436d-9190-de9cef942696`
    - `9b0ca780-1ee8-4856-b673-45fa7d6467b3`
  - stale FTCTL runtime/profile/debug files for `i-2-54-VM`, `i-2-132-VM`,
    and `r97-link-01` removed from the three hosts.
- Final readiness:
  - primary VM `54` / `i-2-54-VM` is `Running` on host `10.10.32.3`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`: `not_found`
- Next test report must explicitly include:
  - chardev contract gate result
  - mirror path state
  - compare path state
  - whether a repeated EPERM signature is now narrowed by contract evidence.

### Run77 Pre-Guest Contract Follow-up 2026-06-04

- Retest evidence directory:
  - `/home/ablecloud/work/ft-run-monitor-20260604-234241`
- Protection row:
  - `77`
- Primary:
  - `i-2-54-VM` on `10.10.32.3`
- Secondary:
  - `i-2-133-VM` on `10.10.32.1`
- Result:
  - final DB state: `protection_state=error`, `transport_state=failed`
  - `last_error=xcolo_filter_mirror_send_eperm`
  - primary QEMU logged `filter mirror send failed(Operation not permitted)`
  - primary later logged `Received invalid message 0x0000 length 0x0000`
  - secondary logged `Can't receive COLO message: Input/output error`
- New evidence captured by the chardev contract diagnostics:
  - `xcolo_chardev_contract_ready=no`
  - `xcolo_chardev_contract_reason=mirror_path_primary_mirror0=present_closed,compare_path_secondary_red1=present_closed`
  - mirror path:
    `primary:m0->mirror0(present_closed)->secondary:red0(present_open)->f1`
  - compare path:
    `secondary:f2->red1(present_closed)->primary:compare1(present_open)->comp0`
- Interpretation:
  - this is progress over generic invalid-message diagnosis
  - TCP reachability and topology audit are not sufficient
  - the failure boundary is now the QEMU chardev frontend lifecycle
  - the existing post-migrate contract check is too late because primary
    startup-active filters can already send before that check runs
- Design recorded:
  - `docs/ftctl/354-ft-xcolo-pre-guest-chardev-contract-gate-design-20260604.md`
- Implementation direction:
  - add a `pre_guest_traffic_contract` gate before primary `migrate`
  - capture primary/secondary `query-status`, socket state, and
    primary/secondary `query-chardev`
  - require primary `mirror0`, primary `compare1`, secondary `red0`, and
    secondary `red1` to be `present_open`
  - fail with
    `xcolo_colo_chardev_contract_not_ready_before_guest_traffic` if the
    contract is not ready
  - keep the post-migrate contract check as a secondary validation point
- Repetition guard:
  - if the next run again reaches `xcolo_filter_mirror_send_eperm` before the
    pre-guest gate result, the new gate is still too late
  - if the next run fails at the pre-guest gate with closed chardev edges and
    no QEMU EPERM, the implementation improved failure containment and the next
    question is why QEMU keeps `mirror0` or `red1` closed before migrate

### Pre-Guest Contract Gate Build Deploy Cleanup Readiness 2026-06-05

- Source commit built and deployed:
  - `8702f81` (`fix: gate xcolo before guest traffic`)
- GitHub Actions:
  - run: `26960622235`
  - workflow: `FTCTL Branch Development Release`
  - result: success
  - source commit: `8702f81c3f1314217d2911e000b724c9c5389c98`
  - RPM SHA256:
    `51797527417397a6f160bfadce8297b3e923d9b5f591d9b7b93497f2277b763d`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - all hosts report:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
    - `ablestack-vm-ftctl.timer=active`
    - `ablestack-vm-hangctl.timer=active`
  - installed scripts contain:
    - `ftctl_xcolo_gate_before_guest_traffic`
    - `xcolo_colo_chardev_contract_not_ready_before_guest_traffic`
- Run77 cleanup:
  - protection row `77`: removed/disabled
  - active protection rows for VM `54`: `0`
  - active `ftctl.*` details for VM `54` or `r97-link-01-standby%`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - standby VM `133` set to `Expunging`
  - standby volumes `251`, `252` set to `Expunged`
  - standby RBD images removed or confirmed absent:
    - `2471d059-e967-48c6-82a8-f52157be4d7d`
    - `3e8d93fb-2060-45f7-b4e9-796731bf8af2`
  - stale FTCTL runtime/profile/debug files for `i-2-54-VM`, `i-2-133-VM`,
    and `r97-link-01` removed from the three hosts.
- Final readiness:
  - primary VM `54` / `i-2-54-VM` is `Running` on host `10.10.32.3`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`: `not_found`
- Next test report must explicitly include:
  - `xcolo_pre_guest_traffic_gate`
  - `xcolo_pre_guest_traffic_gate_reason`
  - `xcolo_pre_guest_traffic_contract_chardev_contract_ready`
  - whether QEMU EPERM appears before or after the pre-guest gate

### Run78 QEMU Doc Topology Audit Follow-up 2026-06-05

- Retest evidence directory:
  - `/home/ablecloud/work/ft-run-monitor-20260605-003019`
- Protection row:
  - `78`
- Primary:
  - `i-2-54-VM` on `10.10.32.3`
- Secondary:
  - `i-2-134-VM` on `10.10.32.1`
- Result:
  - final DB state: `protection_state=error`, `transport_state=failed`
  - `last_error=xcolo_colo_chardev_contract_not_ready_before_guest_traffic`
  - `xcolo_protocol_failure_phase=pre_guest_traffic_contract`
  - primary remained `paused`
  - secondary remained `inmigrate`
- Captured contract:
  - `xcolo_chardev_contract_ready=no`
  - `xcolo_chardev_contract_reason=mirror_path_primary_mirror0=present_closed,compare_path_secondary_red1=present_closed`
  - mirror path:
    `primary:m0->mirror0(present_closed)->secondary:red0(present_open)->f1`
  - compare path:
    `secondary:f2->red1(present_closed)->primary:compare1(present_open)->comp0`
- Log interpretation:
  - the pre-guest gate contained the failure before a new current-run
    `Received invalid message 0x0000 length 0x0000` was observed
  - the remaining ambiguity is whether the generated command line differs from
    the QEMU COLO sample or whether QEMU keeps a documented chardev frontend
    closed at runtime
- Design recorded:
  - `docs/ftctl/355-ft-xcolo-qemu-doc-hard-topology-audit-design-20260605.md`
- Implementation direction:
  - keep startup-active filter topology
  - do not reintroduce staged `status=off` / `qom-set status=on` activation
  - hard-check primary QEMU command line against documented `mirror0`,
    `compare1`, `compare0`, `compare0-0`, `compare_out`, and `compare_out0`
    socket semantics
  - hard-check secondary command line against documented `red0`, `red1`,
    `f1`, `f2`, `rew0`, and `-incoming`
  - classify document-topology failures as
    `xcolo_qemu_doc_topology_mismatch`
  - classify document-topology-ok but closed runtime frontend failures as
    `xcolo_qemu_doc_runtime_frontend_closed`
- Repetition guard:
  - if the next run again reports closed `mirror0` or `red1`, the report must
    explicitly say whether `xcolo_qemu_doc_topology` was `ok` or `failed`
  - if it was `ok`, the next change must target QEMU runtime frontend binding
    and not command-line topology or staged activation timing

### QEMU Doc Topology Audit Build Deploy Cleanup Readiness 2026-06-05

- Source commit built and deployed:
  - `4aa8241` (`fix: harden xcolo qemu doc topology audit`)
- GitHub Actions:
  - run: `26963481673`
  - workflow: `FTCTL Branch Development Release`
  - result: success
  - source commit: `4aa824135647bca5ec80b9eab4de2f3d00e05af7`
  - RPM SHA256:
    `ad830fb62f5c827eff5a4cce5d88cc2f819ae8124c73df0422336a150c66fd74`
- Deployment:
  - RPM deployed to:
    - `10.10.32.1`
    - `10.10.32.2`
    - `10.10.32.3`
  - all hosts report:
    - `ablestack_vm_ftctl-0.8.0-1.noarch`
    - `ablestack-vm-ftctl.timer=active`
    - `ablestack-vm-hangctl.timer=active`
  - installed scripts contain:
    - `xcolo_qemu_doc_runtime_frontend_closed`
    - `xcolo_qemu_doc_topology_mismatch`
    - `doc_compare1_listener`
- Run78 cleanup:
  - protection row `78`: removed/disabled
  - active protection rows for VM `54`: `0`
  - active `ftctl.*` details for VM `54` or `r97-link-01-standby%`: `0`
  - active `r97-link-01-standby%` VM rows: `0`
  - active `r97-link-01-standby%` volume rows: `0`
  - standby VM `134` set to `Expunging`
  - standby volumes `253`, `254` set to `Expunged`
  - standby RBD images removed:
    - `d909daa8-7505-4753-8d25-a33f30af6064`
    - `c392d7e7-8096-4e5c-8a14-69158f86d98d`
  - stale FTCTL runtime/profile/debug files for `i-2-54-VM`, `i-2-134-VM`,
    and `r97-link-01` removed from the three hosts.
- Final readiness:
  - primary VM `54` / `i-2-54-VM` is `Running` on host `10.10.32.3`
  - primary QMP `query-block-jobs`: empty
  - primary QMP `query-migrate`: empty
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json`: `not_found`
- Next test report must explicitly include:
  - `xcolo_qemu_doc_topology`
  - `xcolo_qemu_doc_topology_reason`
  - `xcolo_qemu_doc_runtime_frontend`
  - `xcolo_qemu_doc_runtime_frontend_reason`
  - whether the closed frontend issue is still `mirror0`, `red1`, or a new edge

### Run79 QEMU Doc Runtime Frontend Monitor 2026-06-05

- Retest evidence directory:
  - `/home/ablecloud/work/ft-run-monitor-20260605-103340`
- Protection row:
  - `79`
- Primary:
  - `i-2-54-VM` on `10.10.32.3`
- Secondary:
  - `i-2-135-VM` on `10.10.32.1`
- Result:
  - final DB state: `protection_state=error`, `transport_state=failed`
  - `last_error=xcolo_qemu_doc_runtime_frontend_closed`
  - `xcolo_protocol_failure_phase=pre_guest_traffic_doc_frontend_contract`
- Progress:
  - both baseline seed copies completed:
    - `sda -> fa01b0d2-e6fd-4c22-84e3-e4d023d2285b`
    - `sdb -> 55fee667-7648-4b91-8bfc-e8890da9d4fd`
  - storage symmetry stayed `ok`:
    - `sda:block/raw,sdb:block/raw`
  - QEMU document topology audit passed:
    - `xcolo_qemu_doc_topology=ok`
    - `xcolo_qemu_doc_primary_qom_ready=yes`
    - `xcolo_qemu_doc_primary_cmdline_ready=yes`
    - `xcolo_qemu_doc_secondary_cmdline_ready=yes`
  - TCP/socket layer was established:
    - primary `9003` and `9004`: `listen`
    - secondary `9003` and `9004`: `established`
- Failure evidence:
  - chardev contract failed:
    - `xcolo_chardev_contract_ready=no`
    - `xcolo_chardev_contract_reason=mirror_path_primary_mirror0=present_closed,compare_path_secondary_red1=present_closed`
    - mirror path:
      `primary:m0->mirror0(present_closed)->secondary:red0(present_open)->f1`
    - compare path:
      `secondary:f2->red1(present_closed)->primary:compare1(present_open)->comp0`
  - primary QEMU command line contained the expected QEMU COLO document shape:
    - `mirror0 wait=off`
    - `compare1 wait=on`
    - `compare0/compare0-0`
    - `compare_out/compare_out0`
    - active `m0`, `redire0`, `redire1`, `comp0`
  - secondary QEMU command line contained:
    - `red0 reconnect-ms=1000`
    - `red1 reconnect-ms=1000`
    - active `f1`, `f2`
    - `-incoming tcp:10.10.32.1:9998`
  - primary QEMU still logged:
    - `filter mirror send failed(Operation not permitted)`
  - no new current-run repeated `Received invalid message 0x0000 length 0x0000`
    was captured before the runtime recovery.
- Repetition assessment:
  - this is not the previous generic invalid-message loop
  - this is a narrowed repeat of the same lower-level chardev frontend closure:
    QEMU document command-line topology is correct, but runtime frontend state
    is not ready
  - the pre-guest gate classified the failure correctly, but it did not prevent
    the earlier `filter mirror send failed(Operation not permitted)` log
- Next improvement direction:
  - keep the QEMU document command-line topology unchanged
  - do not return to staged `status=off` filter activation
  - move the runtime frontend readiness control earlier than the current
    pre-guest gate, or make the primary startup path prevent guest TX from
    entering `m0 -> mirror0` until both `mirror0` and `red1` are open
  - the next design must explain exactly how QEMU can start with the documented
    topology while keeping `mirror0`/`red1` frontends closed, and how ftctl will
    block guest/filter traffic before that first send attempt

### Premigrate Frontend Open Design 2026-06-05

- Design recorded:
  - `docs/ftctl/356-ft-xcolo-premigrate-frontend-open-before-migrate-design-20260605.md`
- Corrected interpretation:
  - primary `migrate` starts the COLO runtime and is not the right place to
    begin waiting for `mirror0`/`red1`
  - frontend readiness must be proven before primary `migrate`
- Code direction:
  - generated primary `mirror0` default changes from `wait=off` to `wait=on`
    for FTCTL's libvirt-orchestrated cloud-managed path
  - this intentionally differs from the QEMU sample's `mirror0 wait=off`
  - the reason is Run 79: with startup-active `m0`, `mirror0 wait=off` allowed
    primary QEMU to pass the mirror listener before secondary `red0` was a
    usable frontend peer
  - async primary create avoids the old deadlock risk because FTCTL can observe
    the mirror listener, start secondary, wait for peer connections, and only
    then finish primary create
  - add baseline-based pre-migrate QEMU log guard:
    - `last_error=xcolo_filter_mirror_send_before_migrate`
    - `xcolo_protocol_failure_phase=premigrate_filter_mirror_send`

### Premigrate Frontend Open Build And Retest Readiness 2026-06-05

- Source commit:
  - `bb92082667d1948df5380778f676c5aeed6c033a`
  - `fix: require xcolo mirror peer before migrate`
- Build:
  - GitHub Actions run: `26994945999`
  - the workflow conclusion was `failure` because the branch development
    release publish step failed
  - the FTCTL RPM build, repository creation, and artifact upload steps
    completed successfully
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `99a75df48f17d1d17aac06ae8cf78d76e4ff2b4ae7d7c8892d8b79dcaeb2d40c`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - 32.x package installation must use the administrator wrapper directly:
    `aspkg -Uvh --replacepkgs`
  - using `exec -a rpm aspkg ...` returned success but left the previous
    installed script unchanged, so this method is not valid for 32.x
  - verified installed script markers on all three hosts:
    - `FTCTL_XCOLO_MIRROR_WAIT:-on`
    - `xcolo_filter_mirror_send_before_migrate`
    - `xcolo_primary_qemu_log_baseline_lines`
    - `premigrate_filter_mirror_send`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 79:
  - removed active protection row `79` by marking it disabled/stopped/removed
    with `last_error=test_cleanup_after_premigrate_frontend_open_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `135`
  - marked standby VM `135` (`i-2-135-VM`) as `Expunging`
  - marked standby volumes `255` and `256` as `Expunged`
  - removed standby RBD images:
    - `rbd/fa01b0d2-e6fd-4c22-84e3-e4d023d2285b`
    - `rbd/55fee667-7648-4b91-8bfc-e8890da9d4fd`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-135-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returned an empty list
  - primary QMP `query-migrate` returned an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`
  - the removed standby RBD images now return `No such file or directory`

### Run 88 Monitoring Result 2026-06-05

- Test start:
  - protection row: `88`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `144` / `i-2-144-VM`
  - standby volumes:
    - root: `273`, RBD image `fbd6948e-9c74-4644-bce3-0c2ae0df46b9`
    - data: `274`, RBD image `890f209a-5215-4796-a410-15fe886a362d`
- Final observed state:
  - host state file: `protection_state=error`, `transport_state=failed`
  - host `last_error=xcolo_block_primary_listener_wait_failed`
  - Cloud DB row still showed `protection_state=pairing`, `transport_state=planned`,
    with `last_error=xcolo_block_primary_listener_wait_failed`
  - primary VM was rollback-restored and running again on `10.10.32.3`
  - standby VM stayed `Stopped`
- Confirmed improvement from previous runs:
  - the native RBD backend correction was active:
    `file=rbd:rbd/<image-id>`
  - the BlockBackend/node-name split correction was active:
    `id=...-bb,node-name=...`
  - guest disk devices referenced the BlockBackend ids:
    `drive=ftctl-colo-...-bb,id=ftctl-colo-...-dev`
  - the previous failures `xcolo_startup_krbd_path_leaked` and
    `Device name ... conflicts with an existing node name` did not recur
- New failure boundary:
  - primary QEMU failed while starting generated XML:
    `Bus 'scsi0.0' not found`
  - secondary QEMU failed with the same `scsi0.0` bus error
  - generated XML retained the libvirt SCSI controller alias `scsi0`, but the
    FT-controlled guest-visible disks were appended through qemu:commandline as
    `-device scsi-hd,bus=scsi0.0,...`
- Repetition analysis:
  - this is not the same repeated COLO protocol `invalid message 0x0000` loop
  - this is a new startup graph/device topology boundary after the RBD backend
    and BlockBackend/node-name fixes
- Next design direction:
  - stop mixing libvirt-owned SCSI controller topology with qemu:commandline
    guest disk devices
  - for FT-controlled disks, create the disk controller and guest-visible disk
    devices from the same qemu:commandline graph, or otherwise keep both under
    libvirt XML control if libvirt can express the full COLO backend graph
  - add a generated-startup validation that rejects a qemu:commandline disk
    device referencing a controller bus that is not owned by the same startup
    graph or proven usable by an actual QEMU startup preflight

### Startup Disk Controller Ownership Fix 2026-06-05

- Corrected design:
  - `docs/ftctl/366-ft-xcolo-startup-disk-controller-ownership-design-20260605.md`
- Code direction:
  - prepend the FT startup disk graph with an FTCTL-owned SCSI controller:
    `-device virtio-scsi-pci,id=ftctl-xcolo-scsi0`
  - attach all FT-controlled protected disks to:
    `bus=ftctl-xcolo-scsi0.0`
  - keep native RBD backend and BlockBackend/node-name split unchanged
  - reject generated args that attach protected disks to libvirt-owned
    `scsiN.0`
  - classify that validation failure as:
    `xcolo_startup_disk_controller_mismatch`
- Expected retest improvement:
  - Run 89 must not repeat `Bus 'scsi0.0' not found`
  - if it fails, it should move to a later boundary such as channel attach,
    QMP block graph operations, primary migrate, or post-migrate runtime
    validation

### Startup Disk Controller Ownership Build And Retest Readiness 2026-06-05

- Source commit for deployed code:
  - `99d905205cd5cd59129d2615e14ae6f114c5bb3f`
  - `fix: own xcolo startup disk controller`
- Build:
  - GitHub Actions run: `27019998472`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `0b345d86e540b532042cc2ece6c2d628ce94598b7003d2645f1ece0e4c2ecf07`
- Pre-deploy QEMU syntax check:
  - host: `10.10.32.3`
  - minimal QEMU startup with:
    - `-device virtio-scsi-pci,id=ftctl-xcolo-scsi0`
    - `-device scsi-hd,bus=ftctl-xcolo-scsi0.0,...`
  - result: QEMU started and was stopped by the test timeout, confirming the
    FTCTL-owned bus name is valid on QEMU 9.2.4
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used 32.x administrator wrapper:
    `aspkg --replacepkgs -U`
  - verified installed script markers on all three hosts:
    - `ftctl-xcolo-scsi0`
    - `xcolo_startup_disk_controller_mismatch`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 88:
  - removed active protection row `88` by marking it `removed/stopped` with
    `last_error=test_cleanup_after_startup_disk_controller_fix`
  - removed active `ftctl.*` VM details for primary VM `54` and standby VM
    `144`
  - marked standby VM `144` (`i-2-144-VM`) as `Expunging`
  - marked standby volumes `273` and `274` as `Expunged`
  - removed stale FTCTL runtime/profile/debug/xml/blockcopy files for
    `i-2-54-VM`, `i-2-144-VM`, and `r97-link-01` from the 32.x hosts
  - unmapped leftover standby RBD devices on `10.10.32.1`:
    - `/dev/rbd10`
    - `/dev/rbd12`
  - removed standby RBD images:
    - `rbd/fbd6948e-9c74-4644-bce3-0c2ae0df46b9`
    - `rbd/890f209a-5215-4796-a410-15fe886a362d`
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary HMP `info block-jobs` returned `No active jobs`
  - primary HMP `info migrate` returned no active migration session
  - removed standby RBD images now return absent

### Run 89 Monitoring Result 2026-06-05

- Test start:
  - protection row: `89`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `145` / `i-2-145-VM`
  - standby volumes:
    - root: `275`, RBD image `b37f3ad0-647e-4013-8f55-710a2944ed55`
    - data: `276`, RBD image `1e26c6fc-efcb-41fc-b578-e53e801d16e1`
- Final observed state:
  - Cloud DB row: `protection_state=error`, `transport_state=failed`
  - host state: `conversion_stage=rollback_after_primary_create_failed`
  - host `last_error=xcolo_block_primary_listener_wait_failed`
  - primary VM was rollback-restored and running on `10.10.32.3`
  - standby VM stayed `Stopped`
- Confirmed improvement:
  - Run 88 `Bus 'scsi0.0' not found` did not recur
  - generated primary and secondary qemu args now include:
    - `-device virtio-scsi-pci,id=ftctl-xcolo-scsi0`
    - `bus=ftctl-xcolo-scsi0.0`
  - native RBD backend and BlockBackend/node-name split remained active
- New failure boundary:
  - both primary and secondary generated QEMU startups failed with PCI slot
    collision:
    `PCI: slot 1 function 0 not available for cirrus-vga, in use by virtio-scsi-pci,id=ftctl-xcolo-scsi0`
  - root cause: the FTCTL-owned `virtio-scsi-pci` controller was added without
    explicit PCI placement, so QEMU chose the default root slot `0x1`, which is
    already occupied by the libvirt video device
- Repetition analysis:
  - this is not the previous `scsi0.0` bus-not-found loop
  - it is the next topology ownership boundary: the FTCTL-owned controller is
    valid, but it needs deterministic PCI address placement
- Next design direction:
  - when generating the FTCTL-owned disk controller, also allocate or reuse a
    deterministic free PCI attachment point
  - for this VM shape, the simplest guarded approach is to attach
    `ftctl-xcolo-scsi0` behind an existing free pcie-root-port if available,
    or create an FTCTL-owned pcie-root-port plus controller pair in the same
    qemu:commandline graph
  - add validation that rejects FTCTL-owned controller args without explicit
    `bus=` and `addr=`, or with an address already used in generated XML

### Run 86 Startup Disk Graph Monitor Result 2026-06-05

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM created by Cloud: `142` / `i-2-142-VM`
- Final state:
  - `ftctl_protection.id=86`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_block_primary_listener_wait_failed`
  - primary domain recovered and is running on `10.10.32.3`
  - standby domain is not running; Cloud DB VM `142` remains `Stopped`
- Evidence:
  - monitor evidence directory:
    `/tmp/ftctl-monitor-run-20260605-214520`
  - primary state file recorded startup disk graph activation:
    `xcolo_startup_disk_graph=enabled`
  - generated primary QEMU args used stable RBD paths:
    `/dev/rbd/rbd/64084f28-b9c7-4e46-8aeb-13a56c452790`
    and `/dev/rbd/rbd/4b86a392-aeb4-47fd-b8cc-16295f5eee82`
  - generated secondary QEMU args used stable RBD paths:
    `/dev/rbd/rbd/bcc61c91-9e63-4db3-b96e-fdd442a93eed`
    and `/dev/rbd/rbd/d34c57a6-3ea7-48fc-b8fe-58866babb20a`
  - primary libvirt/QEMU log failed while opening the generated startup graph
    root path:
    `Could not open '/dev/rbd/rbd/64084f28-b9c7-4e46-8aeb-13a56c452790': No such file or directory`
  - secondary libvirt/QEMU log failed while opening the generated startup
    graph standby path:
    `Could not open '/dev/rbd/rbd/bcc61c91-9e63-4db3-b96e-fdd442a93eed': No such file or directory`
- Repetition analysis:
  - this is not the previous COLO protocol invalid-message loop
  - this is not the secondary memory-region assertion caused by runtime
    guest disk hotplug
  - the startup disk graph code did run and advanced the failure boundary to
    the pre-QEMU-start RBD mapping contract
  - the new issue is that the generated XML no longer contains protected
    libvirt `<disk>` entries, so existing XML/hook-based RBD mapping can no
    longer be relied on to make qemu:commandline `-drive file.filename=...`
    paths exist at QEMU startup
- Next required correction:
  - make FTCTL explicitly map and verify every stable `/dev/rbd/rbd/<image-id>`
    path referenced by startup-generated qemu commandline arguments before
    each `virsh create`
  - perform this mapping independently of libvirt XML `<disk>` entries
  - keep the stable path rule; do not switch generated XML or qemu arguments
    to `/dev/rbdN`
  - add fail-fast errors for missing startup RBD paths instead of allowing the
    failure to surface later as `xcolo_block_primary_listener_wait_failed`

### Native RBD Startup Backend Correction 2026-06-05

- Corrected conclusion after Run 86:
  - Cloud and FTCTL state must keep `/dev/rbd/rbd/<image-id>` as the stable
    disk identity
  - generated transient qemu commandline must not directly open that KRBD path
    after protected `<disk>` XML entries are removed
  - generated startup disk graph must use QEMU's native RBD backend:
    `file=rbd:<pool>/<image>`
- Code direction implemented:
  - `ftctl_xcolo_build_startup_disk_args` converts `/dev/rbd/<pool>/<image>`
    to `file=rbd:<pool>/<image>` for primary and secondary startup graph base
    nodes
  - startup graph application fails fast with
    `xcolo_startup_krbd_path_leaked` if `/dev/rbd/` remains in generated qemu
    args
  - stable RBD contract validation now also checks native RBD backend
    accessibility through `qemu-img info --force-share --output=json
    rbd:<pool>/<image>`
  - call sites preserve the specific startup backend error instead of
    overwriting it with the older stable-path error
- Repetition analysis:
  - this is a direct fix for the Run 86 QEMU startup failure
  - it does not change the earlier no-hotplug decision
  - it does not reintroduce `/dev/rbdN`
  - if the next run again fails with COLO invalid-message errors, that will be
    a later protocol boundary, not the same RBD startup path issue

### Native RBD Startup Backend Build, Deploy, Cleanup 2026-06-05

- Source commit:
  - `402bed3fe8298511aad86611020ce17b2b22b183`
  - `fix: use native rbd backend for xcolo startup`
- Build:
  - GitHub Actions run: `27017056209`
  - result: `success`
  - artifact: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `5bb93a58f27a0c4b30bc53dee2575836b510b1446e04dfd486502beb97b0a360`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - 32.x installer wrapper used:
    `aspkg --replacepkgs -U /root/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
  - verified installed script markers:
    - `xcolo_startup_krbd_path_leaked`
    - `file=rbd:`
    - `xcolo_rbd_startup_backend_unavailable`
  - verified installed script no longer has a generated startup path pattern
    like `file.filename=.*dev/rbd`
- Native RBD backend host preflight:
  - primary-side `qemu-img info --force-share --output=json
    rbd:rbd/64084f28-b9c7-4e46-8aeb-13a56c452790` succeeded on
    `10.10.32.3`
  - secondary-side `qemu-img info --force-share --output=json
    rbd:rbd/bcc61c91-9e63-4db3-b96e-fdd442a93eed` succeeded on
    `10.10.32.1` before cleanup
- Cleanup for retest:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for primary VM `54`: `0`
  - active standby VM rows for `r97-link-01-standby`: `0`
  - active standby volumes for `r97-link-01-standby%`: `0`
  - standby VM `142` / `i-2-142-VM` marked `Expunging`
  - standby volumes `269` and `270` marked `Expunged`
  - removed standby RBD images:
    - `rbd/bcc61c91-9e63-4db3-b96e-fdd442a93eed`
    - `rbd/d34c57a6-3ea7-48fc-b8fe-58866babb20a`
  - primary VM `i-2-54-VM` remains `running` on `10.10.32.3`

### Run 87 Native RBD Backend Monitor Result 2026-06-05

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM created by Cloud: `143` / `i-2-143-VM`
  - standby volumes:
    - root `271` / `e72c42de-d9cd-46fc-8a31-58a8b2565102`
    - data `272` / `c82625ca-0020-4165-96d7-c3cebcca3703`
- Final state:
  - `ftctl_protection.id=87`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_block_primary_listener_wait_failed`
  - primary domain recovered and is running on `10.10.32.3`
  - standby domain is not running; Cloud DB VM `143` remains `Stopped`
- Evidence:
  - monitor evidence directory:
    `/tmp/ftctl-monitor-run87-20260605-223445`
  - RBD startup backend improvement was effective:
    - primary generated qemu args used
      `file=rbd:rbd/64084f28-b9c7-4e46-8aeb-13a56c452790`
    - secondary generated qemu args used
      `file=rbd:rbd/e72c42de-d9cd-46fc-8a31-58a8b2565102`
    - there was no repeat of the Run 86
      `Could not open '/dev/rbd/rbd/<image-id>'` startup failure
  - new QEMU startup failure:
    - primary:
      `Device name 'ftctl-primary-parent-sda' conflicts with an existing node name`
    - secondary:
      `Device name 'ftctl-parent-sda' conflicts with an existing node name`
- Minimal reproduction on `10.10.32.3`:
  - failed:
    `-drive if=none,id=ftctltest,node-name=ftctltest,...`
    with `Device name 'ftctltest' conflicts with an existing node name`
  - did not fail with that error:
    `-drive if=none,id=ftctltest-backend,node-name=ftctltest-node,...`
    and QEMU stayed up until the test timeout stopped it
- Repetition analysis:
  - this is not the Run 86 KRBD stable path failure
  - this is not the earlier COLO invalid-message loop
  - this is not a return to runtime guest disk hotplug
  - native RBD backend moved the boundary forward to QEMU block graph naming
    semantics
- Next required correction:
  - generated startup disk graph must not use the same string for `id=` and
    `node-name=`
  - keep stable node names for graph references, but give the BlockBackend id
    a distinct suffix, such as `<node>-bb`
  - update primary, secondary, replication, quorum, and overlay graph args
    consistently so every `backing=`, `children.0=`, and device `drive=`
    continues to point at the intended node/backend

### Block Node And Backend Naming Correction 2026-06-05

- Corrected design:
  - `docs/ftctl/365-ft-xcolo-block-node-backend-naming-design-20260605.md`
- Code direction implemented:
  - generated `-drive` options now use distinct BlockBackend ids, for example:
    - `id=ftctl-primary-parent-sda-bb`
    - `node-name=ftctl-primary-parent-sda`
  - guest `scsi-hd` devices now use the BlockBackend id:
    - `drive=ftctl-colo-sda-bb`
  - guest disk device ids are distinct from block node names:
    - `id=ftctl-colo-sda-dev`
  - QMP graph node references remain unchanged:
    - `backing=ftctl-primary-parent-sda`
    - `children.0=ftctl-primary-active-sda`
    - `x-blockdev-change parent=ftctl-colo-sda`
  - startup graph validation now fails fast if:
    - `id=` equals `node-name=`
    - protected guest disk `drive=` does not point to a `-bb` backend
    - `/dev/rbd/` leaks into generated qemu args
- Repetition analysis:
  - this directly addresses the Run 87 QEMU block namespace conflict
  - it keeps the native RBD backend fix from Run 86
  - it does not reintroduce runtime guest disk hotplug
  - it does not change the COLO network graph or migrate sequence

### Block Node And Backend Naming Build, Deploy, Cleanup 2026-06-05

- Source commit:
  - `179463f2e6c07eef46a64683c67094bd06849f99`
  - `fix: split xcolo block backend and node names`
- Build:
  - GitHub Actions run: `27018679778`
  - result: `success`
  - artifact: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `6e8395679deeef29f2dde5faf751aa04ada9c73c961b65626bde1ac7a23088e2`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - 32.x installer wrapper used:
    `aspkg --replacepkgs -U /root/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
  - verified installed script markers:
    - `parent_bb = f`
    - `xcolo_startup_block_backend_node_conflict`
    - `drive={colo_bb},id={colo_dev}`
- Cleanup for retest:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for primary VM `54`: `0`
  - active standby VM rows for `r97-link-01-standby`: `0`
  - active standby volumes for `r97-link-01-standby%`: `0`
  - standby VM `143` / `i-2-143-VM` marked `Expunging`
  - standby volumes `271` and `272` marked `Expunged`
  - removed standby RBD images:
    - `rbd/e72c42de-d9cd-46fc-8a31-58a8b2565102`
    - `rbd/c82625ca-0020-4165-96d7-c3cebcca3703`
  - primary VM `i-2-54-VM` remains `running` on `10.10.32.3`

### Run 84 Monitoring Result 2026-06-05

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - primary runtime host during final check: `10.10.32.3`
  - standby VM observed by the monitor: `140` / `i-2-140-VM`
- Final monitor result:
  - protection row: `84`
  - final Cloud protection state observed by the monitor:
    - `protection_state=error`
    - `transport_state=failed`
    - `protect_job_state=failed`
    - `conversion_stage=handshake_failed`
    - `last_error=xcolo_startup_active_filter_stream_failed`
  - current libvirt state after recovery check:
    - primary `i-2-54-VM` is `running` on `10.10.32.3`
    - standby `i-2-140-VM` is `paused` on `10.10.32.1`
- Confirmed improvement:
  - the QEMU 9.2 directional chardev contract passed before migrate
  - recorded states:
    - `xcolo_chardev_contract_ready=yes`
    - `xcolo_chardev_contract_directional_ready=yes`
    - `xcolo_chardev_contract_strict_frontend_ready=no`
    - strict closed reason:
      `mirror_path_primary_mirror0=present_closed,compare_path_secondary_red1=present_closed`
    - output frontend policy:
      `xcolo_chardev_contract_output_frontend_policy=backend_connected`
    - backend connectivity:
      `primary_mirror0_backend=connected`,
      `primary_compare1_backend=connected`,
      `secondary_red0_backend=connected`,
      `secondary_red1_backend=connected`
    - pre guest traffic gate:
      `xcolo_pre_guest_traffic_gate=ready`
      with policy `qemu_9_2_directional_chardev_contract`
  - this proves the previous false failure at the pre-migrate frontend-open
    gate is no longer blocking the run
- Remaining failure:
  - failure moved to the post-`primary.migrate` phase
  - primary QEMU reported:
    `Received invalid message 0x0000 length 0x0000`
  - FTCTL classified the phase as:
    `xcolo_protocol_failure_phase=post_migrate_startup_active_filter`
  - repeated symptom flag:
    `xcolo_repeated_protocol_invalid_message=yes`
- Repetition analysis:
  - the visible QEMU symptom is the recurring `invalid message 0x0000`
    family, but this run is not a loop over the same pre-migrate failure
  - the system progressed past the directional socket/chardev readiness gate
    and reached `primary.migrate`
  - the next correction must focus on the post-migrate COLO control or filter
    stream transition, not on the already-passing pre-migrate frontend-open
    gate
- Required next analysis:
  - split the broad `xcolo_startup_active_filter_stream_failed` classifier
    into more precise evidence categories
  - distinguish actual filter send failure from migration return-path invalid
    COLO control header
  - inspect Run 84 QEMU logs/debug snapshots before changing topology again

### Run 84 Source-Level Root Cause Update 2026-06-05

- QEMU 9.2.4 source analysis found the strongest current cause:
  FTCTL enabled generic migration `return-path=true` together with
  `x-colo=true`.
- QEMU source basis:
  - `migration/migration.c:source_return_path_thread()` emits
    `Received invalid message 0x0000 length 0x0000`
  - that thread parses 16-bit `MIG_RP_MSG_*` messages and rejects
    `MIG_RP_MSG_INVALID=0`
  - `migration/colo.c:colo_process_checkpoint()` separately reads 32-bit
    `COLOMessage` values such as `COLO_MESSAGE_CHECKPOINT_READY` from the
    COLO return path
  - enabling the generic migration return-path during COLO can create two
    consumers for the same return-path stream
- QEMU document basis:
  - QEMU 9.2.4 `docs/COLO-FT.txt` enables only `x-colo` in the documented COLO
    QMP sequence
  - it does not enable generic migration `return-path`
- Corrected design:
  - `docs/ftctl/362-ft-xcolo-qemu-924-return-path-capability-conflict-design-20260605.md`
- Code correction:
  - FTCTL now sends `migrate-set-capabilities` with
    `return-path=false,x-colo=true`
  - success criteria now require `x-colo=yes` and reject `return-path=yes`
  - `Received invalid message` classification is split:
    - `xcolo_migration_return_path_conflict` if `return-path=yes`
    - `xcolo_filter_mirror_send_failed` or
      `xcolo_filter_mirror_send_eperm` only when QEMU logs prove
      `filter mirror send failed(...)`
    - `xcolo_colo_control_message_invalid` otherwise
- Repetition control:
  - if the next run still fails with `Received invalid message` while
    `xcolo_primary_capability_return_path=no`, the generic migration
    return-path conflict is ruled out and the next analysis must move to the
    COLO control message exchange itself or a QEMU-log-proven filter send
    failure

### Return-Path Capability Fix Build And Retest Readiness 2026-06-05

- Source commit for deployed code:
  - `d5f7fbab0201d1e03f581d38716bbb7e5075486a`
  - `fix: disable migration return-path for xcolo`
- Build:
  - GitHub Actions run: `27010841256`
  - workflow: `FTCTL Branch Development Release`
  - conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `2fd5d739b8be1dcb2b3b88b58345abe9a51a38d6a78bbdfaae55a4167d53039a`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used the 32.x administrator wrapper:
    `aspkg --replacepkgs -U /root/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - verified installed script markers on all three hosts:
    - `return-path","state":false`
    - `xcolo_migration_return_path_conflict`
    - `xcolo_colo_control_message_invalid`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 84:
  - destroyed standby runtime domain `i-2-140-VM` on `10.10.32.1`
  - removed standby RBD images:
    - `rbd/bbb0bcd2-369d-4e57-a97a-a5047fe11275`
    - `rbd/86085290-1dd7-4d10-a441-914d9aa9d9f2`
  - marked protection row `84` removed with
    `last_error=test_cleanup_after_return_path_capability_fix`
  - deleted `ftctl.*` VM details for primary VM `54` and standby VM `140`
  - marked standby VM `140` (`i-2-140-VM`) as `Expunging`
  - marked standby volumes `265` and `266` as `Expunged`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM` from
    `10.10.32.3`
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is Cloud DB `Running` on host id `3`
  - primary VM `i-2-54-VM` is libvirt `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returned an empty list
  - primary QMP `query-migrate` returned an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`
  - removed standby RBD images now return `No such file or directory`

### Run 85 Monitoring Result 2026-06-05

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `141` / `i-2-141-VM`
- Final Cloud state:
  - protection row: `85`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_colo_chardev_contract_not_ready`
  - primary DB/runtime state stayed `Running`
  - standby DB state was `Running`, libvirt runtime on `10.10.32.1` was
    `paused`
- Confirmed improvement from the return-path fix:
  - `xcolo_primary_capability_x_colo=yes`
  - `xcolo_primary_capability_return_path=no`
  - `xcolo_premigrate_primary_capability_return_path=no`
  - the previous QEMU primary failure
    `Received invalid message 0x0000 length 0x0000` was not observed in this
    run
  - therefore the generic migration return-path conflict hypothesis is
    currently resolved for this run
- Progress through the flow:
  - pre-migrate evidence passed:
    - checkpoint delay ready: `expected=2000`, `actual=2000`
    - primary filter QOM/cmdline/chardev ready
    - mirror/compare/loopback channels established
    - topology audit reached the pre-migrate gate
  - pre-guest traffic gate passed:
    - `xcolo_pre_guest_traffic_gate=ready`
    - policy `qemu_9_2_directional_chardev_contract`
  - post-migrate startup-active validation initially passed:
    - `xcolo_post_migrate_startup_active_validation_chardev_contract_ready=yes`
    - `xcolo_post_migrate_startup_active_validation_chardev_contract_directional_ready=yes`
    - primary migrate status: `active`
    - secondary migrate status: `active`
    - invalid-message flag: `no`
- New failure:
  - post-activation contract failed because secondary chardev query failed:
    - `xcolo_post_activation_contract_chardev_contract_ready=no`
    - `xcolo_post_activation_contract_chardev_contract_reason=mirror_path_secondary_red0=query_failed,compare_path_secondary_red1=query_failed/query_failed`
    - `xcolo_protocol_failure_phase=post_migrate_chardev_contract`
  - secondary QEMU log showed a crash before the final paused runtime:
    - `qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common: Assertion '!subregion->container' failed.`
    - libvirt recorded `shutting down, reason=crashed`
  - libvirt then started a new `i-2-141-VM` runtime with `-S`; its QMP showed:
    - `red0` disconnected to primary `10.10.32.3:9003`
    - `red1` connected to primary `10.10.32.3:9004`
    - migration status `setup`
- Repetition analysis:
  - this is not the prior `invalid message 0x0000` loop
  - this is a new boundary: secondary QEMU crashes during/after the COLO
    migration activation path, then recovery leaves the standby paused and the
    secondary chardev query unavailable at the moment FTCTL validates the
    contract
- Next investigation target:
  - inspect QEMU 9.2.4 `memory_region_add_subregion_common` assertion paths
    and identify which COLO/incoming operation can add an already-parented
    memory region
  - compare primary/secondary generated XML and command line for duplicated
    memory backend, NUMA, pflash, or device objects that might be invalid under
    incoming COLO
  - avoid returning to return-path or pre-migrate chardev hypotheses unless
    their evidence changes

### Run 85 Corrective Design 2026-06-05

- Design document:
  - `docs/ftctl/363-ft-xcolo-startup-disk-graph-no-hotplug-design-20260605.md`
- Repetition control:
  - this is not the old `Received invalid message 0x0000 length 0x0000` loop
  - the return-path conflict fix held in Run 85
  - the current boundary is secondary QEMU crash during runtime protected disk
    device replacement
- Corrective principle:
  - primary and secondary protected guest-visible disks must not be changed by
    runtime `device_del` / `device_add`
  - COLO disk graph must be present in generated transient XML before the QEMU
    process starts
  - QMP after start is limited to capability, NBD export/import,
    `x-blockdev-change` of the pre-existing quorum child, migration, and COLO
    control commands
- Code change target:
  - add startup disk graph commandline generation from the generated XML disk
    address model
  - remove protected disk XML entries only from generated transient XML to avoid
    duplicate guest disks
  - preserve stable `/dev/rbd/rbd/<image-id>` paths
  - fail fast with `xcolo_runtime_guest_disk_hotplug_forbidden` if a stale
    runtime disk replacement path is invoked

### Startup Disk Graph Build And Retest Readiness 2026-06-05

- Source commit for code/design:
  - `70eb565`
  - `fix: build xcolo disk graph before startup`
- Build:
  - GitHub Actions run: `27015017987`
  - workflow: `FTCTL Branch Development Release`
  - conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `d55aaa09a4394def19b59675e46295043e6804c758d427468736ac0628fa2cd8`
- Local validation before commit:
  - `bash -n lib/ftctl/xcolo.sh`: pass
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: pass
  - `git diff --cached --check`: pass
  - full selftest was not used as a gating result because the existing
    shellcheck step reports pre-existing warnings outside this change scope
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used the 32.x administrator wrapper:
    `aspkg --replacepkgs -U /root/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - verified installed markers on all three hosts:
    - `xcolo_startup_disk_graph`
    - `xcolo_runtime_guest_disk_hotplug_forbidden`
  - verified stale runtime hot-plug event markers are absent from installed
    qemu FTCTL script:
    - `device_del_existing_root`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 85:
  - destroyed/undefined standby domain `i-2-141-VM` on `10.10.32.1`
  - marked protection row `85` removed with
    `last_error=test_cleanup_after_startup_disk_graph_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `141`
  - marked standby VM `141` as `Expunging`
  - marked standby volumes `267` and `268` as `Expunged`
  - removed standby RBD images:
    - `rbd/f977fd7f-bd95-4554-ba99-14ebf3eeb9dc`
    - `rbd/e7541672-df9d-4ad0-8cb9-19d664ae4876`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-141-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `Running` on host id `3`
  - libvirt shows `i-2-54-VM` running on `10.10.32.3`
  - removed standby RBD images report `RBD_REMOVED`

### QEMU 9.2.4 Directional Chardev Contract Design 2026-06-05

- Run 83 code-level analysis:
  - protection row: `83`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `139` / `i-2-139-VM`
  - final state before this fix:
    - `protection_state=error`
    - `transport_state=failed`
    - `last_error=xcolo_pre_migrate_frontend_not_open`
  - QEMU command-line topology and primary QOM topology were OK.
  - TCP sockets were connected:
    - primary `9003=listen`, secondary `9003=established`
    - primary `9004=listen`, secondary `9004=established`
  - `query-chardev` showed:
    - primary `mirror0=present_closed` but filename contained a TCP peer
    - primary `compare1=present_open`
    - secondary `red0=present_open`
    - secondary `red1=present_closed` but filename contained a TCP peer
- Repetition control:
  - this is not another storage/RBD path issue
  - this is not a firewall/connectivity issue because TCP peers were present
  - this is a false-positive pre-migrate hard gate caused by treating output
    chardev `frontend-open=false` as failure
- Corrected design:
  - `docs/ftctl/361-ft-xcolo-qemu-924-directional-chardev-contract-design-20260605.md`
  - updated `docs/ftctl/360-ft-xcolo-frontend-hard-gate-and-cloud-managed-runtime-reconcile-design-20260605.md`
- Code direction:
  - parse both `frontend-open` and backend filename connectivity from
    `query-chardev`
  - require backend connectivity for output chardevs:
    - primary `mirror0`
    - secondary `red1`
  - require `frontend-open=true` for input chardevs:
    - secondary `red0`
    - primary `compare1`
  - keep strict frontend status as diagnostics only
  - update the pre-guest gate policy to
    `qemu_9_2_directional_chardev_contract`
  - restore cloud-managed standby runtime from `standby.generated.xml`, not
    `standby_xml_seed`, during qemu-side failure recovery

### Directional Chardev Contract Build And Retest Readiness 2026-06-05

- Source commit for deployed code:
  - `71e0bb480a87839e3628d5fef4e3d253c9122239`
  - `fix: use directional chardev contract for xcolo`
- Validation before build:
  - `bash -n` passed for `lib/ftctl/xcolo.sh`
  - `bash -n` passed for `lib/ftctl/standby.sh`
  - `git diff --check` passed
  - local simulation of the Run 83 `query-chardev` shape returned:
    - `directional_ready=True`
    - `strict_frontend_ready=False`
- Build:
  - GitHub Actions run: `27006586717`
  - build, RPM repo creation, and artifact upload succeeded
  - final workflow conclusion was failed only because
    `Publish FTCTL branch development release` hit a GitHub secondary rate
    limit
  - deployed RPM was taken from the uploaded artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `19ba3a465a17102e79a07eadf9354a7d2ffdf2a644294fab8d6d726556ba0d15`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used 32.x administrator wrapper:
    `aspkg --replacepkgs -U /root/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - verified installed script markers on all three hosts:
    - `qemu_9_2_directional_chardev_contract`
    - `standby_xml_generated_missing`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 83:
  - removed active protection row `83` by marking it disabled/stopped/removed
    with `last_error=test_cleanup_after_directional_chardev_contract_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `139`
  - marked standby VM `139` (`i-2-139-VM`) as `Expunging`
  - marked standby volumes `263` and `264` as `Expunged`
  - destroyed/undefined any stale `i-2-139-VM` libvirt runtime on
    `10.10.32.1`
  - unmapped and removed standby RBD images:
    - `rbd/f7d3590d-05d5-4bad-b783-50914699754a`
    - `rbd/4111de0f-0ced-4b37-b8c9-f4640b329c1e`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-139-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `Running` in Cloud DB on host `3`
  - primary VM `i-2-54-VM` is `running` in libvirt on `10.10.32.3`
  - primary QMP `query-block-jobs` returned an empty list
  - primary QMP `query-migrate` returned an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`
  - removed standby RBD images now return `No such file or directory`
- Repetition control:
  - the next test must report whether the previous false-positive hard gate is
    cleared by checking `xcolo_chardev_contract_directional_ready` and
    `xcolo_chardev_contract_strict_frontend_ready`
  - if `Received invalid message 0x0000 length 0x0000` reappears after
    `primary.migrate`, it must be treated as a new post-migrate
    migration-return-path/COLO-control failure, not as the same Run 83
    pre-migrate gate failure

### Run 82 Async Protect Frontend Contract Failure 2026-06-05

- Source state before the fix:
  - qemu source commit: `f145a8f`
  - Cloud async protect had already accepted the long-running FT job.
- Observed state:
  - protection row: `82`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `138` / `i-2-138-VM`
  - final FTCTL state: `protection_state=error`, `transport_state=failed`
  - last error: `xcolo_filter_mirror_send_eperm`
- Repeated symptom family:
  - primary QEMU reported `Received invalid message 0x0000 length 0x0000`
  - secondary QEMU reported `Can't receive COLO message: Input/output error`
  - this is the same visible protocol family as earlier runs, so it must be
    treated as repeated unless the phase evidence changes.
- New decisive evidence:
  - socket reachability passed for the COLO ports
  - topology, storage symmetry, RBD contract, firewall, and QEMU document
    topology gates passed
  - the actual guest traffic frontend contract was already closed before
    migrate:
    - `primary mirror0=present_closed`
    - `secondary red1=present_closed`
  - the previous diagnostic-only rule allowed `migrate` despite that contract
    failure.
- Cloud runtime mismatch:
  - Cloud DB showed standby VM `i-2-138-VM` as `Running` on host `1`
  - host `10.10.32.1` libvirt reported `failed to get domain 'i-2-138-VM'`
  - code inspection showed qemu recovery called standby deactivate, which used
    `virsh destroy` and `virsh undefine` on the secondary side.
- Corrected design:
  - `docs/ftctl/360-ft-xcolo-frontend-hard-gate-and-cloud-managed-runtime-reconcile-design-20260605.md`
- Code direction:
  - fail before `primary.migrate` unless primary `mirror0`, primary `compare1`,
    secondary `red0`, and secondary `red1` are all `present_open`
  - classify this as `last_error=xcolo_pre_migrate_frontend_not_open`
  - keep socket/firewall checks as separate transport diagnostics
  - for cloud-managed FT standby recovery, do not run generic undefine cleanup;
    restore or start from `standby_xml_seed` and verify libvirt runtime exists
    so Cloud DB `Running` does not silently diverge from host runtime state

### Frontend Hard Gate Build And Retest Readiness 2026-06-05

- Source commit for deployed code:
  - `969331f853ed970357e0dbc74e25f603b6da1c91`
  - `fix: hard gate xcolo frontend before migrate`
- Build:
  - GitHub Actions run: `27003067980`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `46e08628bbbc9d2ee9d5402757b2bed85136892ad872c51fe849f1bb6c0a1a67`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used the 32.x administrator package wrapper:
    `aspkg --replacepkgs -U /root/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - verified installed host script markers on all three hosts:
    - `xcolo_pre_migrate_frontend_not_open`
    - `ftctl_standby_deactivate_cloud_managed`
    - `cloud_runtime_state_mismatch`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 82:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - marked protection row `82` removed with
    `last_error=test_cleanup_after_frontend_hard_gate_fix`
  - marked standby VM `138` (`i-2-138-VM`) as `Expunging`
  - marked standby volumes `261` and `262` as `Expunged`
  - removed standby RBD images:
    - `rbd/1812a96a-c5c6-4d67-ac05-87af37ba5dc9`
    - `rbd/0f803b0e-3df2-4f17-bbd8-302768db8b50`
  - removed leftover krbd mappings on `10.10.32.1`:
    - `/dev/rbd15`
    - `/dev/rbd16`
  - removed stale FTCTL runtime/profile/debug/job files for `i-2-54-VM`,
    `i-2-138-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returned an empty list
  - primary QMP `query-migrate` returned an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`
  - no `i-2-138-VM` standby domain is running on the 32.x hosts
  - the removed standby RBD images now return absent

### Run 83 Frontend Hard Gate Retest Result 2026-06-05

- Test target:
  - primary VM: `54` / `i-2-54-VM` / `r97-link-01`
  - standby VM: `139` / `i-2-139-VM` / `r97-link-01-standby`
  - protection row: `83`
- Progress:
  - async protect job started:
    `protect-i-2-54-VM-20260605172025-3a7dcba0`
  - baseline seeding completed for both disks:
    - `sda` to `rbd/f7d3590d-05d5-4bad-b783-50914699754a`
    - `sdb` to `rbd/4111de0f-0ced-4b37-b8c9-f4640b329c1e`
  - stable RBD contract passed through `before_migrate`
  - primary and secondary runtime were created
  - primary migrate capabilities and checkpoint delay were set successfully
- Expected improvement confirmed:
  - `primary.migrate` was not issued after the frontend contract failed
  - the repeated post-migrate protocol symptom was avoided in this run
  - failure stopped at the intended phase:
    - `xcolo_protocol_failure_phase=pre_guest_traffic_contract`
    - `last_error=xcolo_pre_migrate_frontend_not_open`
  - frontend contract evidence:
    - primary `mirror0=present_closed`
    - primary `compare1=present_open`
    - secondary `red0=present_open`
    - secondary `red1=present_closed`
  - socket snapshot still showed transport reachability:
    - primary `9003=listening`
    - primary `9004=listening`
    - secondary `9003=established`
    - secondary `9004=established`
- Remaining failure:
  - Cloud DB reports standby VM `i-2-139-VM` as `Running` on host `1`
  - host `10.10.32.1` libvirt reports:
    `failed to get domain 'i-2-139-VM'`
  - standby RBD images still have local watchers/mappings on `10.10.32.1`
    after failure
- Root cause of the new recovery bug:
  - the new cloud-managed restore path was invoked and did not run generic
    `undefine`
  - `standby.deactivate.cloud_restore` failed with `rc=1`
  - the helper attempted to recreate from `standby_xml_seed`
  - `standby_xml_seed` is the original Cloud XML and still contains:
    - `<name>i-2-54-VM</name>`
    - the primary UUID
    - primary disk source paths
  - the correct file for restore must be the generated standby runtime XML,
    `standby.generated.xml`, because it contains the secondary domain name,
    secondary disk paths, and FT QEMU command line
- Next code direction:
  - cloud-managed recovery must restore/start from `standby_xml_generated`
    first, not `standby_xml_seed`
  - if generated XML is missing, it must rematerialize standby XML before
    attempting restore
  - cloud restore failure logging must include the virsh stderr so the next
    failure is not reduced to `rc=1`
  - after restore failure, FTCTL must keep explicit state:
    `cloud_runtime_state_mismatch=true`

### Cloud Timeout Structural Fix 2026-06-05

- New failure symptom:
  - UI/API displayed:
    `Unable to register FTCTL protection for VM d08503ff-ea56-4e35-bdf8-2f0ebf81382c: timeout`
- Root cause classification:
  - this timeout was produced by the Cloud KVM wrapper path, not by a qemu-side
    FTCTL phase classifier
  - the wrapper used synchronous `FtctlActionCommand(PROTECT)`
  - Cloud `Script` timeout can forcibly destroy the direct
    `ablestack_vm_ftctl protect` process
- Repetition guard:
  - do not treat this as another COLO protocol failure until the qemu worker
    has actually accepted and emitted qemu-side phase evidence
  - if the same UI timeout appears again, first verify that Cloud is calling
    `PROTECT_START`, not `PROTECT`
- Corrected design:
  - `docs/ftctl/359-ft-protect-async-job-start-design-20260605.md`
- Code direction:
  - add qemu `protect-start`
  - keep existing foreground `protect` for direct debugging
  - make Cloud `registerFtctlProtection` send `PROTECT_START`
  - expose qemu job metadata through the normal state/status path

### Run 81 Pre-Migrate Frontend Diagnostic Pivot 2026-06-05

- Run 81 result:
  - protection row: `81`
  - standby VM: `137` / `i-2-137-VM`
  - final state: `protection_state=error`, `transport_state=failed`
  - final stage: `conversion_stage=handshake_failed`
  - final error: `xcolo_qemu_doc_runtime_frontend_closed`
- Confirmed improvements from the previous change:
  - stable RBD contract passed all four phase gates:
    - `after_primary_stop`
    - `before_primary_create`
    - `before_secondary_create`
    - `before_migrate`
  - generated XML kept stable `/dev/rbd/rbd/<image-id>` paths
  - listener bootstrap used `compare_bootstrap`
  - pre-migrate TCP socket snapshot reached expected connectivity:
    - primary `9003=listen`
    - primary `9004=listen`
    - secondary `9003=established`
    - secondary `9004=established`
  - pre-migrate mirror-send guard passed
  - QEMU document topology and primary filter QOM topology passed
- Repetition control:
  - this is the same visible frontend-open gate symptom as Run 80
  - RBD mapping and listener ordering are no longer the next hypothesis
  - the repeated condition is specifically that QMP `query-chardev` reports
    `frontend-open=false` even though TCP sockets are established
- Corrected design:
  - `docs/ftctl/358-ft-xcolo-qemu-doc-preguest-frontend-diagnostic-design-20260605.md`
- Code direction:
  - keep collecting `query-chardev` at the pre-guest boundary
  - record closed frontend state as `diagnostic_closed`
  - do not set `last_error=xcolo_qemu_doc_runtime_frontend_closed` before
    primary `migrate`
  - let primary `migrate` run when topology, sockets, RBD contract, and
    pre-migrate mirror-send guards pass
  - use post-migrate runtime validation to classify the real COLO result

### Pre-Migrate Frontend Diagnostic Build And Retest Readiness 2026-06-05

- Source commit for deployed code:
  - `5d5a2d9`
  - `fix: treat pre-migrate frontend-open as diagnostic`
- Build:
  - GitHub Actions run: `26997628215`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `3c3dd134ff52ebfbea7a43d687b1a9e2abd08e26dcbcd14ca16699ca96df5ecd`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used `aspkg -Uvh --replacepkgs`
  - verified installed script markers:
    - `xcolo_pre_guest_traffic_gate_policy=qemu_doc_topology_socket`
    - `diagnostic_closed`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 81:
  - removed active protection row `81` by marking it disabled/stopped/removed
    with `last_error=test_cleanup_after_preguest_frontend_diagnostic_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `137`
  - marked standby VM `137` (`i-2-137-VM`) as `Expunging`
  - marked standby volumes `259` and `260` as `Expunged`
  - removed standby RBD images:
    - `rbd/43f0a081-a078-4593-a89b-af1861d84f37`
    - `rbd/194ac44c-d3c5-4ba3-b073-7564c4ef3e72`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-137-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returned an empty list
  - primary QMP `query-migrate` returned an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`
  - the removed standby RBD images now return `No such file or directory`

### Stable RBD Contract And Listener Bootstrap Design 2026-06-05

- Run 80 failure summary:
  - protection row: `80`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `136` / `i-2-136-VM`
  - final state: `protection_state=error`, `transport_state=failed`
  - primary `compare1` was open, but primary `mirror0` stayed closed
  - secondary `red0` was open, but secondary `red1` stayed closed
  - secondary QEMU reported `red1` connection refused to primary port `9004`
  - primary and secondary QMP also showed busy block graph cleanup messages
- Repetition analysis:
  - this is the same visible COLO protocol symptom family as the previous
    `invalid message 0x0000` / `Can't receive COLO message` failures
  - it is not acceptable to keep changing adjacent startup guesses without
    recording the exact phase and contract state
  - the next run must report RBD contract phase results, listener bootstrap
    result, frontend open state, and block-graph-busy classification
- Corrected design:
  - `docs/ftctl/357-ft-xcolo-stable-rbd-contract-and-listener-bootstrap-design-20260605.md`
- Critical correction from the previous direction:
  - generated primary and secondary XML must not be rewritten to `/dev/rbdN`
  - XML must keep the stable `/dev/rbd/rbd/<image-id>` path
  - `/dev/rbdN` may be recorded only as a diagnostic resolved device
- Code direction:
  - verify stable RBD paths after primary stop, before primary create, before
    secondary create, and before migrate
  - keep secondary runtime disk binding lookup on the stable Cloud path
  - emit primary `compare1` before `mirror0`
  - when both compare and mirror listeners use `wait=on`, treat `compare1` as
    the primary generated-create bootstrap listener so secondary `red1` can
    connect before primary blocks at `mirror0`
  - classify QMP `Node ... is busy` failures as
    `last_error=xcolo_block_graph_busy` rather than folding them into protocol
    invalid-message failures

### Stable RBD Contract Build And Retest Readiness 2026-06-05

- Source commit for deployed code:
  - `d7bd2c99a74d54f8913ea5d7831c329b6f6f4904`
  - `fix: enforce stable rbd contract for xcolo`
- Build:
  - GitHub Actions run: `26996870710`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `3c252d71a7be1fe259d63a89d36e78740fd49d65248fa512e8521fe7aaeb031a`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used 32.x administrator wrapper:
    `aspkg -Uvh --replacepkgs`
  - verified installed script markers on all three hosts:
    - `xcolo_rbd_contract_ready`
    - `xcolo_primary_listener_bootstrap`
    - `xcolo_block_graph_busy`
  - verified the removed XML rewrite helper is absent:
    - `ftctl_xcolo_rewrite_disk_source_for_runtime`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 80:
  - removed active protection row `80` by marking it disabled/stopped/removed
    with `last_error=test_cleanup_after_stable_rbd_listener_bootstrap_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `136`
  - marked standby VM `136` (`i-2-136-VM`) as `Expunging`
  - marked standby volumes `257` and `258` as `Expunged`
  - removed standby RBD images:
    - `rbd/74101fa6-d0c0-4ad0-b0cc-8a7c0cd18851`
    - `rbd/444da800-5898-406e-8592-87bc64ff36fe`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-136-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP `query-block-jobs` returned an empty list
  - primary QMP `query-migrate` returned an empty object
  - `ablestack_vm_ftctl status --vm i-2-54-VM --json` returned `not_found`
  - the removed standby RBD images now return `No such file or directory`

### X-COLO Startup SCSI PCI Placement Build And Retest Readiness 2026-06-06

- Source commit for deployed code:
  - `d15f3991fa764c74839a13e79e2843399e707ade`
  - `fix: place xcolo startup scsi controller`
- Failure boundary fixed:
  - Run 89 failed after the Run 88 `Bus 'scsi0.0' not found` issue was
    corrected.
  - The new failure was a generated QEMU startup conflict:
    `PCI: slot 1 function 0 not available for cirrus-vga, in use by
    virtio-scsi-pci,id=ftctl-xcolo-scsi0`.
  - Root cause: the FTCTL-generated startup SCSI controller had an id and guest
    SCSI bus, but it did not have explicit PCI placement. QEMU auto-placed it
    at root slot `0x1`, which conflicted with the existing VGA device.
- Code correction:
  - parse generated XML PCI topology before writing startup disk arguments
  - prefer an unused existing `pcie-root-port` for
    `ftctl-xcolo-scsi0`
  - if no unused root port exists, create an FTCTL-owned root port
    `ftctl-xcolo-pci0` at a free root slot and attach the startup SCSI
    controller behind it
  - validate that the protected disk controller always has explicit `bus=` and
    `addr=` values
  - reject accidental placement on `pcie.0` slot `0x1`
  - keep existing guards for node-name/id conflicts, guest-drive `-bb` suffix,
    libvirt-owned `scsiN.0` buses, and forbidden `/dev/rbd/` QEMU arguments
- Preflight:
  - inspected current `i-2-54-VM` topology on `10.10.32.3`
  - confirmed existing unused root port `pci.7` can host
    `ftctl-xcolo-scsi0`
  - minimal QEMU startup preflight with `cirrus-vga` at root slot `0x1` and
    FTCTL SCSI attached behind `pci.7` started successfully
- Build:
  - GitHub Actions run: `27022522155`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `83270bd300d7c64c03337237a04d0b499c14e5f4319abc58e645032e5d244a2a`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used 32.x administrator wrapper:
    `aspkg --replacepkgs -U`
  - verified installed package on all three hosts:
    `ablestack_vm_ftctl-0.8.0-1.noarch`
  - verified installed script markers on all three hosts:
    - `controller_placement_missing`
    - `existing-root-port`
    - `ftctl-xcolo-pci0`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 89:
  - removed active protection row `89` by marking it disabled/stopped/removed
    with `last_error=test_cleanup_after_xcolo_controller_placement_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `145`
  - marked standby VM `145` (`i-2-145-VM`) as `Expunging`
  - marked standby volumes `275` and `276` as `Expunged`
  - unmapped stale standby RBD mappings `/dev/rbd10` and `/dev/rbd12`
  - removed standby RBD images:
    - `rbd/b37f3ad0-647e-4013-8f55-710a2944ed55`
    - `rbd/1e26c6fc-efcb-41fc-b578-e53e801d16e1`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-145-VM`, and `r97-link-01` from the 32.x hosts
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - primary QMP/HMP shows no active block jobs
  - primary QMP/HMP shows no active migration

### Run 92 Monitoring Result 2026-06-06

- Test input:
  - target VM: `r97-link-01`
  - primary VM id: `54`
  - primary instance: `i-2-54-VM`
  - generated standby VM id: `148`
  - generated standby instance: `i-2-148-VM`
  - primary host: `10.10.32.3`
  - secondary host: `10.10.32.1`
- Final Cloud DB state:
  - `ftctl_protection.id=92`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_runtime_validation_failed:primary_not_running`
  - primary VM `54` is `Running` on host id `3`
  - standby VM `148` is DB `Running` on host id `1`
- Final host runtime state:
  - primary host `10.10.32.3` has `i-2-54-VM` running again after FTCTL
    runtime recovery
  - secondary host `10.10.32.1` has `i-2-148-VM` paused with incoming
    migration listener `10.10.32.1:9998`
  - this remaining secondary runtime is failure evidence and must be cleaned
    before the next retest
- Progress confirmed:
  - generated commandline contract passed for both roles:
    - primary generated XML contained network COLO args and disk graph args
    - secondary generated XML contained redirection/filter args, incoming
      migration, and disk graph args
  - both baseline seeds completed:
    - `xcolo_disk_sda_baseline_seeded=true`
    - `xcolo_disk_sdb_baseline_seeded=true`
  - startup disk graph was enabled:
    - `xcolo_startup_disk_graph=enabled`
  - primary and secondary generated domains were created
  - before migration, channel checks passed:
    - `xcolo.socket_snapshot phase=pre_migrate` showed primary `9003/9004`
      listening and secondary `9003/9004` established
    - `xcolo.chardev_contract phase=pre_guest_traffic_contract` passed
  - migration command was accepted:
    - `primary.migrate result=ok`
    - `xcolo.post_migrate_transition phase=startup_active_validation`
      reported primary/secondary migration `active`
  - post-migrate channel checks initially still passed:
    - `xcolo.socket_snapshot phase=post_migrate_startup_active_validation`
      showed secondary `9003/9004` established
    - `xcolo.chardev_contract phase=post_migrate_startup_active_validation`
      passed
- Failure evidence:
  - secondary QEMU on `10.10.32.1` crashed after migration activation:
    - `qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
      Assertion '!subregion->container' failed.`
    - libvirt recorded shutdown reason `crashed`
  - primary QEMU then logged:
    - `Can't receive COLO message: Input/output error`
  - after the secondary crash, FTCTL post-activation validation detected the
    broken paths:
    - `xcolo.socket_snapshot phase=post_migrate_post_activation_validation`
      showed secondary `9003/9004` closed
    - `xcolo.chardev_contract` failed with
      `mirror_path_secondary_red0=query_failed,compare_path_secondary_red1=query_failed/query_failed`
  - FTCTL later failed the job as:
    - `xcolo_runtime_validation_failed:primary_not_running`
    - this is a downstream validation result, not the first cause
- Repetition analysis:
  - this is not Run 91 repeating.
  - Run 91 failed before opening primary COLO listeners because network
    commandline args were dropped.
  - Run 92 includes both network and disk startup args, reached successful
    pre-migrate channel validation, accepted migration, and entered the
    post-migrate validation boundary.
  - the repeated primary-side `Can't receive COLO message: Input/output error`
    is currently a symptom of secondary QEMU termination, not the primary root
    cause in this run.
- Corrected direction:
  - preserve the current commandline merge and startup graph corrections; they
    moved the test past the previous boundary.
  - next investigation must focus on the secondary QEMU assertion crash, using
    QEMU 9.2.4 code-level analysis and the exact secondary command line.
  - FTCTL should also fail faster when the secondary QMP/domain disappears
    during steady-state wait, instead of waiting until a later primary runtime
    validation reports `primary_not_running`.
  - the failure classifier should report the first cause as a secondary QEMU
    crash or secondary domain loss when that is observed.
  - only `i-2-54-VM` is running on the 32.x hosts for this test target
  - removed standby RBD images now return `No such file or directory`

### Run 93 Monitoring Result 2026-06-06

- Test input:
  - target VM: `r97-link-01`
  - primary VM id: `54`
  - generated standby VM id: `149`
  - generated standby instance: `i-2-149-VM`
  - primary host: `10.10.32.3`
  - secondary host: `10.10.32.1`
- Final Cloud DB state:
  - `ftctl_protection.id=93`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_guest_topology_mismatch`
  - primary VM `54` remained `Running`
  - standby VM `149` remained `Running` in Cloud DB and paused/incoming on
    the secondary host
- Progress and repetition analysis:
  - this is not a repeat of Run 92's QEMU assertion crash.
  - Run 92 reached `primary.migrate` and then secondary QEMU crashed with
    `memory_region_add_subregion_common: Assertion '!subregion->container'
    failed`.
  - Run 93 failed earlier, before the startup disk graph was applied and before
    migration.
  - the new guard prevented proceeding into migration with an incomplete
    generated commandline.
- First cause:
  - `primary.generated.xml` and `standby.generated.xml` still contained normal
    libvirt protected `<disk>` entries.
  - their `qemu:commandline` contained only network COLO arguments.
  - the COLO disk graph arguments were absent because the block-runtime XML
    rewrite had removed the original protected disk `<alias>` and
    `<address type="drive">` elements.
  - without those elements, FTCTL could not rebuild protected `scsi-hd` devices
    on the original guest-visible SCSI qdev topology.
- Corrected direction:
  - preserve protected disk `<alias>` and `<address>` during block-runtime XML
    rewrite.
  - validate generated XML topology before removing protected disks.
  - classify missing alias/address as
    `xcolo_startup_disk_topology_missing`, not as a generic topology mismatch.
  - continue to reject any generated commandline containing
    `ftctl-xcolo-pci0` or `ftctl-xcolo-scsi0`.

### Run 94 Monitoring Result 2026-06-06

- Test input:
  - target VM: `r97-link-01`
  - primary VM id: `54`
  - generated standby VM id: `150`
  - generated standby instance: `i-2-150-VM`
  - primary host: `10.10.32.3`
  - secondary host: `10.10.32.1`
- Final Cloud DB state:
  - `ftctl_protection.id=94`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_block_secondary_create_failed`
  - primary VM `54` remained `Running`
  - standby VM `150` was `Stopped`
- Progress confirmed:
  - Run 93's missing topology metadata issue did not recur.
  - generated XML removed ordinary protected libvirt `<disk>` entries.
  - generated `qemu:commandline` included COLO disk graph arguments for both
    `sda` and `sdb`.
  - generated disk devices used original qdev identities:
    - `scsi0-0-0-0`
    - `scsi0-0-0-1`
  - no `ftctl-xcolo-pci0` or `ftctl-xcolo-scsi0` was generated.
- First cause:
  - secondary QEMU failed during create:

```text
Bus 'scsi0.0' not found
```

  - the generated XML kept the libvirt SCSI controller while protected disks
    were added through raw `qemu:commandline`.
  - QEMU did not expose the libvirt-created `scsi0.0` bus to the later raw
    commandline `scsi-hd` devices in this mixed ownership model.
- Repetition analysis:
  - this is a new boundary after Run 93.
  - the test advanced from topology metadata extraction to actual secondary
    QEMU startup with the COLO disk graph present.
  - it is related to the older `Bus 'scsi0.0' not found` symptom, but the
    context is different: the old fix introduced an FTCTL-owned controller,
    while the current fix must preserve original PCI identity.
- Corrected direction:
  - do not create `ftctl-xcolo-pci0` or `ftctl-xcolo-scsi0`.
  - extract the original SCSI controller alias and PCI address.
  - remove the libvirt SCSI controller from generated XML when protected disks
    are the only users.
  - recreate the same controller through `qemu:commandline`, for example
    `virtio-scsi-pci,id=scsi0,bus=pcie.0,addr=0x9`.
  - attach protected `scsi-hd` disks to `bus=scsi0.0`.

### Run 90 Monitoring - Existing Root-Port Reference Fails At QEMU Parse Time 2026-06-06

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `146` / `i-2-146-VM`
- Final DB state:
  - `ftctl_protection.id=90`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_block_primary_listener_wait_failed`
  - primary VM `54` remained `Running` on host id `3`
  - standby VM `146` remained `Stopped`
- Evidence:
  - primary create stderr:
    - `Failed to create domain from .../primary.generated.xml`
    - `qemu-kvm: -device virtio-scsi-pci,id=ftctl-xcolo-scsi0,bus=pci.7,addr=0x0: Bus 'pci.7' not found`
  - `primary.generated.xml` still contained controller index `7`,
    model `pcie-root-port`, alias `pci.7`
  - generated QEMU args correctly avoided the previous root slot `0x1`
    collision:
    - `-device virtio-scsi-pci,id=ftctl-xcolo-scsi0,bus=pci.7,addr=0x0`
  - RBD contract and storage symmetry checks were still healthy:
    - `xcolo_storage_symmetry=ok`
    - `xcolo_rbd_contract_ready=yes`
- Repetition analysis:
  - this is not the same failure as Run 89.
  - Run 89 failed because FTCTL SCSI was auto-placed on root slot `0x1` and
    collided with `cirrus-vga`.
  - Run 90 shows that referencing a libvirt-defined existing root-port alias
    from `qemu:commandline` is not a valid startup contract for this path.
  - The generic `xcolo_block_primary_listener_wait_failed` state is misleading
    here; the primary never reached listener readiness because QEMU failed at
    command-line parse/device construction.
- Corrected direction:
  - do not attach FTCTL-generated command-line devices to libvirt-owned
    existing `pcie-root-port` aliases such as `pci.7`
  - always create the FTCTL-owned root-port inside the same
    `qemu:commandline` argument sequence before creating
    `ftctl-xcolo-scsi0`
  - choose a free root slot from the XML topology for that FTCTL-owned
    root-port
  - keep the `cirrus-vga` root slot `0x1` guard
  - classify this parse-time failure as a dedicated startup PCI topology
    failure instead of folding it into primary listener wait failure

### Owned Root-Port Build And Retest Readiness 2026-06-06

- Source commit for deployed code:
  - `2b35b1a38e5ddef0a0a3e58c2a5962c5b8f03054`
  - `fix: use owned xcolo pci root port`
- Code correction:
  - removed the existing libvirt root-port reuse path from startup SCSI
    attachment selection
  - always create `ftctl-xcolo-pci0` in `qemu:commandline`
  - attach `ftctl-xcolo-scsi0` to `bus=ftctl-xcolo-pci0,addr=0x0`
  - validate that protected disks have the FTCTL root-port before the SCSI
    controller argument
  - reject SCSI controller parents that are not FTCTL-owned
  - classify QEMU parse-time PCI failures as
    `xcolo_startup_pci_topology_failed`
  - preserve the classified startup error instead of overwriting it with the
    generic listener wait error
- Build:
  - GitHub Actions run: `27053719762`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `6a0eb52c56cae481065d6dc1c1bd1b3c413f99dc4c0550f24ca0e3f163d7b76c`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used 32.x administrator wrapper:
    `aspkg --replacepkgs -U`
  - verified installed package on all three hosts:
    `ablestack_vm_ftctl-0.8.0-1.noarch`
  - verified installed script markers on all three hosts:
    - `controller_parent_not_ftctl_owned`
    - `ftctl_root_port_missing`
    - `xcolo_startup_pci_topology_failed`
    - `ftctl-xcolo-pci0`
  - verified stale marker `existing-root-port` is absent from installed
    `xcolo.sh`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 90:
  - marked protection row `90` disabled/stopped/removed with
    `last_error=test_cleanup_after_owned_root_port_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `146`
  - marked standby VM `146` (`i-2-146-VM`) as `Expunging`
  - marked standby volumes for VM `146` as `Expunged`
  - stopped FTCTL and hangctl timers during host runtime cleanup to prevent
    state recreation
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-146-VM`, and `r97-link-01` from the 32.x hosts
  - unmapped stale standby RBD mappings:
    - `/dev/rbd10`
    - `/dev/rbd12`
  - removed standby RBD images:
    - `rbd/578747fc-624e-44e4-bd51-e3baa5b5079c`
    - `rbd/c4394ab3-1f5c-4c77-9c33-c2110f1f5b4a`
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - no stale FTCTL files for `i-2-54-VM`, `i-2-146-VM`, or `r97-link-01`
    remained under `/run/ablestack-vm-ftctl` or `/etc/ablestack/ftctl.d`
  - removed standby RBD images now return `No such file or directory`
  - primary QMP/HMP shows no active block jobs
  - primary QMP/HMP shows no active migration

### Run 91 Monitoring - Network COLO Args Dropped From Generated XML 2026-06-06

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `147` / `i-2-147-VM`
- Final DB state:
  - `ftctl_protection.id=91`
  - `protection_state=error`
  - `transport_state=failed`
  - `last_error=xcolo_block_primary_listener_wait_failed`
  - primary VM `54` remained `Running` on host id `3`
  - standby VM `147` was left DB `Running` on host id `1`
- Progress confirmed:
  - baseline seed completed for both protected disks:
    - `xcolo_disk_sda_baseline_seeded=true`
    - `xcolo_disk_sdb_baseline_seeded=true`
  - startup disk graph validation passed for both roles
  - the owned root-port correction worked:
    - `primary_qemu_args` contained
      `pcie-root-port,id=ftctl-xcolo-pci0,bus=pcie.0,addr=0x3,...`
    - `virtio-scsi-pci,id=ftctl-xcolo-scsi0,bus=ftctl-xcolo-pci0,addr=0x0`
  - primary generated domain creation succeeded:
    - `Domain 'i-2-54-VM' created from .../primary.generated.xml`
  - secondary generated domain creation also reached incoming migration setup:
    - standby QMP `query-migrate` returned `status=setup`
    - standby was listening on `10.10.32.1:9998`
- Failure evidence:
  - primary generated XML had no network COLO command-line args:
    - `compare1` count: `0`
    - `mirror0` count: `0`
    - `filter-mirror` count: `0`
  - primary generated XML contained only the FTCTL-owned PCI root-port, SCSI
    controller, and disk graph command-line args.
  - primary QEMU log for the generated domain showed no `-chardev compare1`,
    no `-chardev mirror0`, and no filter objects.
  - no primary listener was opened on ports `9003` or `9004`, so listener wait
    timed out.
- Repetition analysis:
  - this is not Run 90 repeating.
  - Run 90 failed before generated primary startup because `bus=pci.7` was not
    found.
  - Run 91 passed generated startup with the owned root-port but failed because
    the command-line XML merge path dropped the COLO network args.
- Corrected direction:
  - `ftctl_xcolo_apply_startup_disk_graphs` must append disk graph args to the
    existing network COLO args instead of replacing them.
  - generated XML must be validated for both contracts before `virsh create`:
    - network COLO contract: `compare1`, `mirror0`, `filter-mirror`,
      `filter-redirector`, and `colo-compare`
    - disk graph contract: `ftctl-xcolo-pci0`, `ftctl-xcolo-scsi0`,
      protected disk `-drive` and `scsi-hd` args
  - if either contract is missing, fail before primary shutdown/create with a
    dedicated classifier such as `xcolo_startup_network_args_missing`.

### Startup Commandline Merge Build And Retest Readiness 2026-06-06

- Source commit for deployed code:
  - `ceed822ee876438a0b4b9b6a16f0882263cbf77e`
  - `fix: preserve xcolo network startup args`
- Code correction:
  - `ftctl_xcolo_apply_startup_disk_graphs` no longer recovers network args
    from diagnostic state
  - caller-built primary and secondary network args are passed explicitly into
    disk graph application
  - final commandline is assembled as:
    - primary network args plus primary disk graph args
    - secondary network args plus secondary disk graph args plus `-incoming`
  - generated XML commandline contract validation now checks network and disk
    markers before primary create:
    - primary: `compare1`, `mirror0`, `filter-mirror`,
      `filter-redirector`, `colo-compare`, `ftctl-xcolo-pci0`,
      `ftctl-xcolo-scsi0`
    - secondary: `red0`, `red1`, `filter-redirector`, `filter-rewriter`,
      `-incoming`, `ftctl-xcolo-pci0`, `ftctl-xcolo-scsi0`
  - if network args are absent, the failure is classified as
    `xcolo_startup_network_args_missing` instead of timing out at listener wait
- Build:
  - GitHub Actions run: `27054088954`
  - workflow conclusion: `success`
  - deployed RPM artifact:
    - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
    - SHA256:
      `52dd51dc788d011cde1556472639052cafa25f624dae582096d6434a7830cfa3`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used 32.x administrator wrapper:
    `aspkg --replacepkgs -U`
  - verified installed package on all three hosts:
    `ablestack_vm_ftctl-0.8.0-1.noarch`
  - verified installed script markers on all three hosts:
    - `xcolo_startup_network_args_missing`
    - `startup_commandline_contract`
    - `network_args_not_passed`
    - `validate_generated_commandline_contract`
    - `ftctl-xcolo-pci0`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 91:
  - marked protection row `91` disabled/stopped/removed with
    `last_error=test_cleanup_after_startup_commandline_merge_fix`
  - removed `ftctl.*` VM details for primary VM `54` and standby VM `147`
  - destroyed stale standby runtime domain `i-2-147-VM` on `10.10.32.1`
  - marked standby VM `147` (`i-2-147-VM`) as `Expunging`
  - marked standby volumes for VM `147` as `Expunged`
  - stopped FTCTL and hangctl timers during host runtime cleanup to prevent
    state recreation
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-147-VM`, and `r97-link-01` from the 32.x hosts
  - unmapped stale standby RBD mappings:
    - `/dev/rbd10`
    - `/dev/rbd12`
  - removed standby RBD images:
    - `rbd/4a11f01c-0453-4b05-9d2f-af230f22f5c2`
    - `rbd/510aa330-dd8c-434f-b423-2f21626115aa`
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `i-2-54-VM` is `running` on `10.10.32.3`
  - no stale FTCTL files for `i-2-54-VM`, `i-2-147-VM`, or `r97-link-01`
    remained under `/run/ablestack-vm-ftctl` or `/etc/ablestack/ftctl.d`
  - removed standby RBD images now return `No such file or directory`
  - primary QMP/HMP shows no active block jobs
  - primary QMP/HMP shows no active migration

### Run 95 Monitoring Result 2026-06-06

- Test trigger:
  - user started FT protection for `r97-link-01`
  - primary VM: `54` / `i-2-54-VM`
  - generated standby VM: `151` / `i-2-151-VM`
  - primary host: `10.10.32.3`
  - secondary host: `10.10.32.1`
- Deployed source at test start:
  - `27ae986efbe4121e23bf763ed830e61270c8e84f`
  - `fix: reproduce xcolo scsi controller topology`
- Confirmed improvement:
  - Run 94 `Bus 'scsi0.0' not found` did not recur.
  - generated primary and secondary XML removed the protected libvirt disk
    entries and reproduced the original SCSI controller through
    `qemu:commandline`:
    - `virtio-scsi-pci,id=scsi0,bus=pcie.0,addr=0x9,num_queues=2`
    - `scsi-hd,bus=scsi0.0,...,id=scsi0-0-0-0`
    - `scsi-hd,bus=scsi0.0,...,id=scsi0-0-0-1`
  - both startup graphs reached the migration path:
    - standby state became `running`
    - pre-migrate socket contract passed
    - pre-migrate chardev contract passed
    - `query-migrate` progressed from `active` into primary `colo`
- Failure evidence:
  - secondary QEMU crashed during migration state load:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

  - primary QEMU then logged:

```text
Can't receive COLO message: Input/output error
```

  - final Cloud DB state at evidence collection:
    - `ftctl_protection.id=95`
    - `protection_state=pairing`
    - `transport_state=planned`
    - `provisioning_state=Ready`
    - primary VM `54` was DB `Running` on host id `3`
    - standby VM `151` was DB `Stopped`
  - runtime state after the crash:
    - primary `query-migrate` returned `status=colo`
    - primary `virsh domstate` returned `paused`
    - secondary domain `i-2-151-VM` no longer existed in libvirt
- Repetition analysis:
  - this is not the Run 94 `scsi0.0` bus creation failure.
  - it is a return to the migration-state assertion class seen in earlier
    immutable-topology investigations.
  - the new evidence narrows the remaining mismatch: QEMU can now create the
    same visible `scsi0/scsi0-0-0-*` names, but the device state restored by
    migration still does not match the exact libvirt-created SCSI/PCI device
    properties closely enough.
- Corrected direction:
  - compare the normal libvirt-expanded QEMU command line for the original
    Cloud VM against the FT generated command line for the SCSI controller and
    protected disks.
  - reproduce not only `id`, `bus`, `addr`, and `num_queues`, but every
    migration-visible property that libvirt normally emits for the
    `virtio-scsi-pci` controller and `scsi-hd` disks.
  - add a startup topology diff guard before migration that checks command-line
    parity for protected disk controller properties and fails fast with a
    classifier such as `xcolo_startup_scsi_property_mismatch` instead of
    reaching QEMU assertion.
  - preserve the COLO network, RBD native backend, and commandline SCSI
    controller reproduction fixes already validated by this run.

### Libvirt QEMU Log Property Parity Implementation 2026-06-06

- Source correction prepared after Run 95:
  - use `/var/log/libvirt/qemu/<domain>.log` as the normal Cloud/libvirt argv
    reference for protected guest-visible device properties.
  - parse the latest normal QEMU argv block that is not an FT generated block
    and does not contain `ftctl-colo-*`, `colo-compare`, or `filter-mirror`.
  - extract normal `virtio-scsi-pci` and `scsi-hd` JSON device properties from
    the log.
  - when generating FT startup disk devices, prefer log-derived values for:
    - `num_queues`
    - `serial`
    - `device_id`
    - `bootindex`
    - `write-cache`
    - `share-rw`
  - fall back to XML-derived values only when the log reference is unavailable.
- Validation added:
  - every protected generated `scsi-hd` must include `write-cache=on`.
  - generated primary and secondary commandline contracts now require
    `write-cache=on` before domain creation.
- Local validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed
  - `bash -n lib/ftctl/standby.sh`: passed
  - embedded Python payload compile check: passed
  - `git diff --check`: passed
- Expected retest difference:
  - generated FT argv should now match the normal Cloud/libvirt protected disk
    device properties more closely.
  - for `r97-link-01`, root disk bootindex should come from the normal log
    (`bootindex=3`) instead of the transient rewrite boot order (`9`), and both
    protected disks should carry `write-cache=on`.

### Libvirt QEMU Log Property Parity Build, Deploy, Cleanup 2026-06-06

- Source commit built and deployed:
  - `18e1bc4ed3452742d8627ce5e1bdc06aeeaf4cc8`
  - `fix: mirror libvirt scsi disk properties for xcolo`
- Build:
  - GitHub Actions workflow: `branch-ftctl-release.yml`
  - run id: `27056832259`
  - conclusion: `success`
  - artifact: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `ab18566d3eaa43dccb64598796f2c5beae473bf5e555d24300fe05764ad2ff6b`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used the 32.x administrator wrapper:
    `aspkg --replacepkgs -U`
  - verified installed script markers on all three hosts:
    - `REFERENCE_QEMU_LOG`
    - `parse_qemu_log_device_references`
    - `guest_write_cache_missing`
    - `write-cache=on`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 95:
  - primary VM `54` / `i-2-54-VM` was already restored to normal
    Cloud/libvirt `running` state on `10.10.32.3`.
  - destroyed stale secondary runtime domain `i-2-151-VM` on `10.10.32.1`.
  - removed standby RBD images:
    - `rbd/a616038e-8d49-43df-ad2d-cca03be50ab6`
    - `rbd/e333b82d-6f73-4ed1-a598-203cd086d7a0`
  - marked protection row `95` as `removed/stopped/stopped` with
    `last_error=test_cleanup_after_libvirt_qemu_log_property_fix`.
  - removed active `ftctl.*` VM details for primary VM `54` and standby VM
    `151`.
  - marked standby VM `151` as `Expunging`.
  - marked standby volumes `287` and `288` as `Expunged`.
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-151-VM`, and `r97-link-01` from the 32.x hosts.
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `54` remains DB `Running` on host id `3`
  - primary `virsh domstate i-2-54-VM`: `running`
  - primary QMP `query-migrate`: empty return
  - primary QMP `query-block-jobs`: empty list
  - no standby domain remains in libvirt

### Run 96 Monitoring Result 2026-06-06

- Test action:
  - user started FT protection for primary VM `54` / `i-2-54-VM`.
  - Cloud created standby VM `152` / `i-2-152-VM` and standby volumes:
    - root: `c7c3a5e5-d007-421b-a380-6cd18ed6e59b`
    - data: `f37cc9ca-4702-4a7d-b2aa-3c88720c4c54`
- Current Cloud DB result:
  - `ftctl_protection.id=96`
  - `protection_state=error`
  - `transport_state=failed`
  - `provisioning_state=Ready`
  - `last_error=xcolo_colo_chardev_contract_not_ready`
  - standby VM `152` is still DB `Running` on host id `1`.
- Confirmed improvement from the previous code change:
  - generated FT disk args now include the normal libvirt/QEMU log-derived
    properties.
  - root disk generated as:
    `id=scsi0-0-0-0,...,bootindex=3,write-cache=on`
  - data disk generated as:
    `id=scsi0-0-0-1,...,write-cache=on`
  - this fixes the Run 95 commandline gap where FT startup used
    `bootindex=9` and omitted `write-cache=on`.
- Failure evidence:
  - first secondary FT domain `i-2-152-VM` crashed while receiving migration:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
shutting down, reason=crashed
```

  - primary QEMU then reported the COLO channel break:

```text
Can't receive COLO message: Input/output error
```

  - the recovery/retry secondary domain was left in libvirt as `paused` /
    `inmigrate`, listening on `10.10.32.1:9998`, but its red0 frontend could
    not reconnect because the primary-side `9003` listener was already gone:

```text
Unable to connect character device red0:
Failed to connect to '10.10.32.3:9003': Connection refused
```

- Repetition guard:
  - this is the same high-level failure class as earlier
    `memory_region_add_subregion_common` failures.
  - it is not an exact repeat of the Run 95 root cause, because the previously
    missing disk properties are now present in the generated commandline.
  - the remaining issue must be treated as unresolved migration-visible guest
    topology parity, not as another `write-cache`/`bootindex` omission.
- Next required investigation direction:
  - compare the complete normal libvirt-generated QEMU argv with generated FT
    primary and secondary argv before migration.
  - verify all migration-visible guest topology, not only disks:
    - PCI controller and bus layout
    - SCSI controller properties
    - virtio-net/netdev features, especially vhost/vhostfd-derived behavior
    - iothread/object presence that can affect device realization
    - generated QEMU argument order around guest-visible devices
  - add an automatic pre-migrate topology diff artifact to FTCTL state/debug
    output so future repeated assertion failures show the exact remaining
    mismatch instead of forcing manual log inspection.

### Primary Canonical Guest ABI Implementation 2026-06-06

- Design correction:
  - treat the primary normal libvirt runtime shape as the canonical FT guest
    ABI.
  - stop using the Cloud-created standby XML as the guest-visible shape source
    for the FT transient secondary domain.
  - keep Cloud standby VM/volume lifecycle ownership unchanged; use the standby
    object for management identity and block targets only.
- Source changes prepared:
  - added `ftctl_xcolo_clone_primary_xml_for_secondary`.
  - secondary generated XML is now cloned from the primary XML backup and then
    renamed to the standby domain name.
  - the primary UUID and guest-visible device identity are intentionally kept
    in the secondary transient XML because the secondary is a migration target.
  - native `iothread id=1` is ensured on both generated primary and secondary
    XMLs.
  - added `ftctl_xcolo_verify_generated_guest_abi_pair`.
  - after the final startup disk graph is applied, FTCTL now hashes the
    generated primary and secondary guest ABI manifests and fails before
    migration if they differ.
- New failure classification:
  - `last_error=xcolo_guest_abi_manifest_mismatch`
  - `xcolo_protocol_failure_phase=guest_abi_manifest`
- Repetition guard:
  - if `memory_region_add_subregion_common` appears again after this change,
    the next report must include whether the generated guest ABI manifest gate
    passed.
  - if the manifest gate passes but QEMU still asserts, the remaining mismatch
    is in runtime argv/QMP topology that is not yet represented by the manifest,
    and the manifest must be expanded instead of changing isolated disk options.

### Primary Canonical Guest ABI Build, Deploy, Cleanup 2026-06-06

- Source commit built and deployed:
  - `da61245352ebbd553fd6916f9c0d561a22f469a8`
  - `fix: clone primary guest abi for xcolo secondary`
- Build:
  - GitHub Actions workflow: `branch-ftctl-release.yml`
  - run id: `27057571647`
  - conclusion: `success`
  - artifact: `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256:
    `64028d0ac1c2589718d1483bdd1d0e5b154c1bed1157d15bae9e34c03682be69`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`
  - installation used the 32.x administrator wrapper:
    `aspkg --replacepkgs -U`
  - verified installed script markers on all three hosts:
    - `clone_primary_xml_for_secondary`
    - `xcolo_guest_abi_manifest`
    - `verify_generated_guest_abi_pair`
  - verified timers active on all three hosts:
    - `ablestack-vm-ftctl.timer`
    - `ablestack-vm-hangctl.timer`
- Cleanup after Run 96:
  - destroyed stale secondary runtime domain `i-2-152-VM` on `10.10.32.1`.
  - stale standby RBD images initially had watchers because they remained
    mapped as `/dev/rbd10` and `/dev/rbd12` on `10.10.32.1`.
  - unmapped and removed standby RBD images:
    - `rbd/c7c3a5e5-d007-421b-a380-6cd18ed6e59b`
    - `rbd/f37cc9ca-4702-4a7d-b2aa-3c88720c4c54`
  - marked protection row `96` as `removed/stopped/stopped` with
    `last_error=test_cleanup_after_primary_canonical_guest_abi_fix`.
  - removed active `ftctl.*` VM details for primary VM `54` and standby VM
    `152`.
  - marked standby VM `152` as `Expunging`.
  - marked standby volumes `289` and `290` as `Expunged`.
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-152-VM`, and `r97-link-01` from the 32.x hosts.
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `54` remains DB `Running` on host id `3`
  - primary `virsh domstate i-2-54-VM`: `running`
  - primary QMP `query-block-jobs`: empty list
  - no `i-2-152-VM` / `r97-link-01-standby` runtime domain remains in libvirt
  - installed marker verification passed on all three hosts.

### Run 97 Monitoring Result 2026-06-06

- Test action:
  - user started FT protection for primary VM `54` / `i-2-54-VM`.
  - Cloud created standby VM `153` / `i-2-153-VM` and standby volumes:
    - root: `57388f27-8b51-451a-9d29-3d7a80f0d7ba`
    - data: `60ad27c8-e912-4419-a420-faac9ec67dab`
- Current Cloud DB result:
  - `ftctl_protection.id=97`
  - `protection_state=error`
  - `transport_state=failed`
  - `provisioning_state=Ready`
  - `last_error=xcolo_guest_abi_manifest_mismatch`
  - standby VM `153` is still DB `Running` on host id `1`.
- Confirmed improvement:
  - the new primary-canonical secondary runtime path was used.
  - secondary QEMU process `i-2-153-VM` was started with the primary guest UUID,
    MAC, CPU/memory shape, native `iothread1`, PCI topology, and disk qdev
    identity.
  - the previous QEMU migration crash did not recur in this run.
  - `memory_region_add_subregion_common` did not appear for Run 97.
  - the system failed at the explicit guest ABI manifest gate instead of
    letting QEMU reach a low-level assertion.
- Failure evidence:

```text
last_error=xcolo_guest_abi_manifest_mismatch
xcolo_protocol_failure_phase=guest_abi_manifest
xcolo_guest_abi_manifest_phase=startup_disk_graph
xcolo_guest_abi_manifest_reason=
  mismatch ... reason=/xml[3][18][3][20][3][0][1]/address:
  '10.10.32.3'!='0.0.0.0'
```

- Interpretation:
  - the first mismatch is the VNC/graphics listen address.
  - primary generated XML retained the primary host-specific graphics listen
    address `10.10.32.3`.
  - secondary generated XML was rewritten by standby host runtime handling to
    listen on `0.0.0.0`.
  - this is not guest-visible migration ABI; it is a host presentation endpoint.
  - the ABI manifest gate is therefore too broad for nested graphics/listen
    data.
- Runtime residue:
  - primary VM `i-2-54-VM` was restored to normal libvirt `running` state on
    host `10.10.32.3`.
  - secondary transient domain `i-2-153-VM` remains `paused` / `inmigrate` on
    host `10.10.32.1`.
  - secondary `query-migrate` remains in `setup` and listening on
    `10.10.32.1:9998`.
  - secondary logged red0/red1 connection refused because primary COLO listeners
    were not kept up after the manifest gate failure.
- Repetition guard:
  - this is not a repeat of the previous QEMU assertion failure.
  - the new gate changed the failure mode from QEMU crash to pre-migrate
    mismatch classification.
  - next correction must narrow the ABI manifest to exclude role-local
    presentation endpoints such as graphics/VNC/listen, while still keeping
    true guest-visible devices in the manifest.

### Run 97 Fix Plan 2026-06-06

- Confirmed cause:
  - the manifest gate incorrectly compared host-local VNC graphics listen data.
  - the primary generated XML retained the source host console bind address,
    while the standby host runtime path normalized it to `0.0.0.0`.
  - this mismatch is not a migration-visible guest ABI difference.
- Code direction:
  - normalize FT generated XML VNC listen endpoints to `0.0.0.0` on both
    primary and secondary before startup validation.
  - exclude `graphics`, nested `listen`, `console`, and `channel` subtrees from
    the guest ABI manifest.
  - keep strict comparison for CPU, memory, machine, disk, controller, PCI,
    NIC model, NIC MAC, and guest-visible qemu `-device` arguments.
  - add a startup-gate rollback path that destroys any secondary transient
    runtime and unmaps secondary runtime RBD state without recreating the
    cloud-managed standby domain before FT protection becomes stable.
- Repetition guard:
  - this fix targets the newly introduced manifest scope error.
  - if the same VNC listen mismatch appears again, it is a regression in
    normalization/manifest exclusion rather than a new COLO protocol issue.

### Run 97 Fix Deployment And Cleanup 2026-06-06

- Implemented qemu-side fix:
  - commit: `7ff7bbbd2aab749d05aaee40876dc86a215f001a`
  - normalized FT generated XML VNC listen endpoints to `0.0.0.0` for both
    primary and secondary.
  - excluded host-local presentation/management endpoint subtrees from the
    guest ABI manifest: `graphics`, nested `listen`, `console`, and `channel`.
  - added startup-gate rollback cleanup that destroys the secondary transient
    runtime and unmaps secondary runtime RBD state without recreating the
    cloud-managed standby before protection is stable.
- Build:
  - GitHub Actions run: `27058065358`
  - result: success
  - RPM:
    `/home/ablecloud/work/ftctl-artifacts/run-27058065358/ftctl-branch-rpm-27058065358/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `c3192d31948b9701dd3a56f125df797231173aed1310ed1b62ddd04d6234698d`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3` using `aspkg`.
  - verified installed script markers on all three hosts:
    - `normalize_ft_host_local_endpoints`
    - `rollback_startup_gate`
    - `xcolo_guest_abi_manifest`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts.
- Cleanup:
  - destroyed stale secondary runtime `i-2-153-VM` on `10.10.32.1`.
  - unmapped and removed stale standby RBD images:
    - `rbd/57388f27-8b51-451a-9d29-3d7a80f0d7ba`
    - `rbd/60ad27c8-e912-4419-a420-faac9ec67dab`
  - marked protection row `97` as removed/stopped/stopped with
    `last_error=test_cleanup_after_host_local_endpoint_manifest_fix`.
  - removed active `ftctl.*` VM details for primary VM `54` and standby VM
    `153`.
  - marked standby VM `153` as `Expunging`.
  - marked standby volumes for VM `153` as `Expunged`.
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-153-VM`, and `r97-link-01` from the 32.x hosts.
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `54` remains DB `Running` on host id `3`
  - primary `virsh domstate i-2-54-VM`: `running`
  - primary QMP `query-block-jobs`: empty list
  - no `i-2-153-VM` / `r97-link-01-standby` runtime domain remains in libvirt
  - installed marker verification passed on all three hosts.

### Run 98 Monitoring Result 2026-06-06

- Test action:
  - user started FT protection for primary VM `54` / `i-2-54-VM`.
  - Cloud created standby VM `154` / `i-2-154-VM` and standby volumes:
    - root: `b526594e-364c-48da-be8e-a401fdf430ad`
    - data: `857925c6-908a-4c4a-974e-96fb3f27d97f`
- Final Cloud DB result:
  - `ftctl_protection.id=98`
  - `protection_state=error`
  - `transport_state=failed`
  - `provisioning_state=Ready`
  - `active_side=primary`
  - `last_error=xcolo_colo_chardev_contract_not_ready`
  - standby VM `154` is still DB `Running` on host id `1`.
- Confirmed improvement:
  - generated primary and standby XML both normalized VNC graphics/listen to
    `0.0.0.0`.
  - `xcolo_guest_abi_manifest=ok`.
  - the previous Run 97 manifest failure on graphics/listen did not recur.
- Failure evidence:

```text
conversion_stage=handshake_failed
conversion_state=error
xcolo_protocol_failure_phase=post_migrate_chardev_contract
last_error=xcolo_colo_chardev_contract_not_ready
```

- Runtime evidence:
  - primary `i-2-54-VM` was restored/running on `10.10.32.3`.
  - primary current QMP `query-chardev` only shows normal libvirt channels
    after rollback; the COLO chardevs are gone because the generated primary
    domain was terminated and restored.
  - secondary `i-2-154-VM` remains `paused` / `inmigrate` on `10.10.32.1`.
  - secondary current QMP `query-chardev` shows:
    - `red0`: `frontend-open=false`, `disconnected:tcp:10.10.32.3:9003`
    - `red1`: `frontend-open=false`, tcp endpoint to `10.10.32.3:9004`
  - standby RBD images remain mapped on `10.10.32.1`:
    - `/dev/rbd10` for root
    - `/dev/rbd12` for data
- QEMU log evidence:

```text
primary:
  QEMU waiting for compare1 on 0.0.0.0:9004
  QEMU waiting for mirror0 on 0.0.0.0:9003
  Can't receive COLO message: Input/output error

secondary:
  Unable to connect character device red0:
    Failed to connect to '10.10.32.3:9003': Connection refused
  memory_region_add_subregion_common:
    Assertion `!subregion->container' failed.
```

- Interpretation:
  - Run 98 advanced past the Run 97 manifest gate.
  - The repeated lower-level QEMU assertion reappeared after the manifest gate
    passed, so guest-visible runtime equality is still insufficient.
  - The secondary QEMU crash happened before a stable COLO channel contract was
    established. After rollback/recreate, `red0` could no longer connect
    because primary generated-domain COLO listeners were already gone.
  - The current `xcolo_colo_chardev_contract_not_ready` is therefore a
    post-failure classification symptom; the root failure still includes the
    secondary-side QEMU migration assertion.
- Repetition guard:
  - VNC/graphics mismatch is not repeated.
  - `memory_region_add_subregion_common` is repeated and must be treated as the
    main unresolved issue for the next design step.
  - The next diagnosis must compare primary/secondary generated QEMU command
    lines and live QEMU topology at the point immediately before migration, not
    only the static manifest hash.

### Run 98 Fix Plan 2026-06-06

- Confirmed next focus:
  - static generated XML manifest is not enough.
  - Run 98 passed `xcolo_guest_abi_manifest=ok` and still reached the repeated
    QEMU `memory_region_add_subregion_common` assertion.
  - the next gate must inspect the actual running QEMU process state
    immediately before `primary.migrate`.
- Code direction:
  - add `ftctl_xcolo_verify_live_runtime_topology_pair` before the handshake
    path.
  - collect live primary/secondary QEMU argv from `/proc/<pid>/cmdline`.
  - collect live dumpxml, QMP block/chardev/status snapshots, and HMP
    `info pci`, `info qtree`, and `info mtree`.
  - compare normalized guest-visible live QEMU `-device` arguments.
  - compare HMP `info pci` output.
  - collect qtree/mtree as evidence, but do not fail on full qtree parity in
    the first gate because qtree includes role-specific COLO internals.
  - on mismatch, fail before `primary.migrate` with
    `xcolo_protocol_failure_phase=pre_migrate_live_topology`.
- New expected failure classifications:
  - `xcolo_live_runtime_snapshot_failed`
  - `xcolo_live_qemu_argv_mismatch`
  - `xcolo_live_pci_topology_mismatch`
- Repetition guard:
  - if the repeated QEMU assertion appears again after this gate passes, the
    next investigation must treat guest-visible `-device` and PCI topology as
    proven equal and move to qtree/mtree or QEMU internal migration state.

### Run 98 Fix Deployment And Cleanup 2026-06-06

- Implemented qemu-side live runtime topology gate:
  - commit: `c2bfd8dbd386299b6b2fbaa6427427400617767e`
  - added `ftctl_xcolo_verify_live_runtime_topology_pair`.
  - inserted the gate immediately before `primary.migrate`.
  - collected live QEMU argv from `/proc/<qemu-pid>/cmdline`.
  - collected live dumpxml, QMP status/chardev/block/named-block-node
    snapshots, and HMP `info pci`, `info qtree`, and `info mtree`.
  - compared normalized guest-visible live QEMU `-device` args.
  - compared HMP `info pci` topology.
  - wrote `live-topology-diff-before_migrate.txt` on both success and failure.
- Build:
  - GitHub Actions run: `27062512580`
  - RPM build and artifact upload completed.
  - final workflow conclusion was failed because the release publish step hit a
    GitHub secondary rate limit.
  - deployed RPM artifact was downloaded from the uploaded run artifact.
  - RPM:
    `/home/ablecloud/work/ftctl-artifacts/run-27062512580/ftctl-branch-rpm-27062512580/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `124e901c199edecfd50e148e8badaef9fed0280d7e4cbfd341bc345ddda1322f`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3` using `aspkg`.
  - verified installed script markers on all three hosts:
    - `verify_live_runtime_topology_pair`
    - `primary-live-qemu-argv`
    - `pre_migrate_live_topology`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts.
- Cleanup:
  - destroyed stale secondary runtime `i-2-154-VM` on `10.10.32.1`.
  - unmapped and removed stale standby RBD images:
    - `rbd/b526594e-364c-48da-be8e-a401fdf430ad`
    - `rbd/857925c6-908a-4c4a-974e-96fb3f27d97f`
  - marked protection row `98` as removed/stopped/stopped with
    `last_error=test_cleanup_after_live_runtime_topology_gate`.
  - removed active `ftctl.*` VM details for primary VM `54` and standby VM
    `154`.
  - marked standby VM `154` as `Expunging`.
  - marked standby volumes for VM `154` as `Expunged`.
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-154-VM`, and `r97-link-01` from the 32.x hosts.
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `54` remains DB `Running` on host id `3`
  - primary `virsh domstate i-2-54-VM`: `running`
  - primary QMP `query-block-jobs`: empty list
  - no `i-2-154-VM` / `r97-link-01-standby` runtime domain remains in libvirt
  - installed marker verification passed on all three hosts.

### Run 99 Monitoring Result 2026-06-06

- Test action:
  - user started FT protection for primary VM `54` / `i-2-54-VM`.
  - Cloud created standby VM `155` / `i-2-155-VM` and standby volumes:
    - root: `b5d6aa18-bf17-4311-913f-cfdb2835c9ed`
    - data: `652dbe33-910c-4775-9937-088ab63bb260`
- Final Cloud DB result:
  - `ftctl_protection.id=99`
  - `protection_state=error`
  - `transport_state=failed`
  - `provisioning_state=Ready`
  - `active_side=secondary`
  - `last_error=xcolo_live_runtime_snapshot_failed`
  - standby VM `155` is DB `Stopped` with no host id.
- Confirmed improvement:
  - `xcolo_guest_abi_manifest=ok`.
  - the new live runtime topology gate ran before `primary.migrate`.
  - the flow stopped at `xcolo_protocol_failure_phase=pre_migrate_live_topology`.
  - the repeated QEMU `memory_region_add_subregion_common` assertion was not
    reached in this run.
  - live evidence files were collected:
    - `primary-live-dumpxml-before_migrate.xml`
    - `secondary-live-dumpxml-before_migrate.xml`
    - `primary-info-pci-before_migrate.txt`
    - `secondary-info-pci-before_migrate.txt`
    - `primary-info-qtree-before_migrate.txt`
    - `secondary-info-qtree-before_migrate.txt`
    - `primary-info-mtree-before_migrate.txt`
    - `secondary-info-mtree-before_migrate.txt`
    - `live-topology-diff-before_migrate.txt`
- Failure evidence:

```text
error=xcolo_live_runtime_snapshot_failed
reason=missing_proc_argv primary_devices=0 secondary_devices=20
```

- Additional evidence:
  - `primary-live-qemu-argv-before_migrate.txt` was empty.
  - `secondary-live-qemu-argv-before_migrate.txt` contained 131 lines and 20
    guest-visible `-device` entries.
  - manual post-failure inspection on `10.10.32.3` found the primary generated
    QEMU process in `/proc/3508672/cmdline` with:
    - `guest=i-2-54-VM`
    - COLO `mirror0`, `compare1`, `redire0`, `redire1`, and `comp0` args
    - protected `scsi-hd` device args for both disks.
- Interpretation:
  - the live topology gate itself is in the right phase and prevented migration
    from reaching the previous QEMU assertion.
  - the new failure is not yet a topology mismatch.
  - the primary `/proc/<pid>/cmdline` capture path missed the actual generated
    QEMU process even though the process existed.
  - next fix must make live argv collection deterministic:
    - resolve the qemu PID from `virsh dominfo` / libvirt domain id / monitor
      process metadata instead of scanning all `/proc` entries by substring;
    - or fall back to parsing the latest `/var/log/libvirt/qemu/<domain>.log`
      commandline when `/proc` capture returns no `-device` entries.
- Repetition guard:
  - this run did not repeat the QEMU assertion.
  - this is a new instrumentation failure introduced by the live topology gate.
  - do not proceed to migrate-related topology conclusions until primary live
    argv collection is reliable.

### Run 99 Fix Plan 2026-06-06

- Correction target:
  - the previous failure was not a COLO protocol error and not a proven
    primary/secondary topology mismatch.
  - the gate stopped earlier because the primary live QEMU argv collection
    returned zero `-device` entries while the primary QEMU process still existed.
- Design update:
  - resolve live QEMU argv by QEMU executable identity and exact libvirt domain
    evidence instead of broad substring scanning.
  - score candidates by exact `-name guest=<domain>` and
    `/domain-<id>-<domain>/` paths.
  - write candidate metadata to:
    - `primary-qemu-pid-candidates-before_migrate.txt`
    - `secondary-qemu-pid-candidates-before_migrate.txt`
  - when `/proc` argv has no guest-visible devices, parse the latest
    `/var/log/libvirt/qemu/<domain>.log` command line as a fallback and record
    the source as `qemu_log_fallback`.
  - split the old generic `missing_proc_argv` result into concrete
    classifications:
    - `xcolo_live_runtime_argv_empty`
    - `xcolo_live_primary_argv_empty`
    - `xcolo_live_secondary_argv_empty`
    - `xcolo_live_runtime_argv_no_devices`
    - `xcolo_live_primary_argv_no_devices`
    - `xcolo_live_secondary_argv_no_devices`
- Repetition guard:
  - if the next run still fails before migrate, the report must identify
    whether argv capture, argv device extraction, PCI snapshot, or actual live
    topology comparison failed.
  - do not describe it as the old `memory_region_add_subregion_common`
    repetition unless QEMU actually reaches that assertion again.

### Run 99 Fix Deployment And Cleanup 2026-06-06

- Implemented deterministic live QEMU argv capture:
  - commit: `00e2f6e23f328fa5374924fc326fc1a5b702fc83`
  - `/proc` capture now filters by QEMU executable identity.
  - candidate scoring prefers exact `-name guest=<domain>` and libvirt
    `/domain-<id>-<domain>/` path evidence.
  - candidate metadata is written before topology comparison.
  - when `/proc` argv has no `-device` entries, FTCTL falls back to the latest
    `/var/log/libvirt/qemu/<domain>.log` command line.
  - primary and secondary argv source is recorded as `proc` or
    `qemu_log_fallback`.
  - old generic `missing_proc_argv` classification was split into empty-argv
    and argv-without-device variants.
- Build:
  - GitHub Actions run: `27063215593`
  - workflow conclusion: success
  - RPM artifact:
    `/home/ablecloud/work/ftctl-artifacts/run-27063215593/ftctl-branch-rpm-27063215593/ftctl-rpm-rocky9.6/ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - RPM SHA256:
    `de68fc4f1efdceb010055f465e20d0a3b21e7304298b19af9867946af5472b17`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3` using `aspkg`.
  - verified installed script markers on all three hosts:
    - `primary-qemu-pid-candidates`
    - `qemu_log_fallback`
    - `xcolo_live_primary_argv_no_devices`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three hosts.
- Cleanup:
  - marked protection row `99` as removed/stopped/stopped with
    `last_error=test_cleanup_after_deterministic_live_argv_capture_fix`.
  - removed active `ftctl.*` VM details for primary VM `54` and standby VM
    `155`.
  - marked standby VM `155` as `Expunging`.
  - marked standby volumes for VM `155` as `Expunged`.
  - unmapped and removed stale standby RBD images:
    - `rbd/b5d6aa18-bf17-4311-913f-cfdb2835c9ed`
    - `rbd/652dbe33-910c-4775-9937-088ab63bb260`
  - removed stale FTCTL runtime/profile/debug files for `i-2-54-VM`,
    `i-2-155-VM`, and `r97-link-01` from the 32.x hosts.
- Final readiness verification:
  - active protection rows for primary VM `54`: `0`
  - active `ftctl.*` details for `r97-link-01`: `0`
  - active standby VM rows: `0`
  - active standby volumes: `0`
  - primary VM `54` remains DB `Running` on host id `3`
  - primary `virsh domstate i-2-54-VM`: `running`
  - primary QMP `query-block-jobs`: empty list
  - no Run 99 standby RBD image remains mapped or present.

### Run 101 Monitoring Result 2026-06-06

- Test action:
  - user restarted the primary VM through Cloud, then started FT protection
    again.
  - Cloud created protection row `101` and standby VM `157` /
    `i-2-157-VM`.
- Confirmed improvement:
  - the previous Run 100 disk inventory failure did not repeat.
  - primary started from clean inactive libvirt XML first:
    - active disk count was `2` at the beginning of protection.
    - active `ftctl-` commandline marker count was `0` at the beginning of
      protection.
  - FTCTL reached `baseline_seeding`, then started the generated COLO primary.
  - `xcolo_guest_abi_manifest=ok`.
  - live argv capture succeeded on both sides:
    - primary source: `qemu_log_fallback`
    - primary device count: `20`
    - secondary source: `proc`
    - secondary device count: `20`
  - the previous `memory_region_add_subregion_common` assertion was not reached.
  - migration was stopped by the pre-migrate live topology gate.
- Final result:

```text
ftctl_protection.id=101
protection_state=error
transport_state=failed
active_side=secondary
last_error=xcolo_live_pci_topology_mismatch
xcolo_protocol_failure_phase=pre_migrate_live_topology
```

- Failure evidence:

```text
error=xcolo_live_pci_topology_mismatch
reason=info_pci_diff primary_hash=0540dde0a659e65de7918d65222abdcbb7a6de20a0af3fb3b9af86b92321c7d2 secondary_hash=790297d437b8cc07491919d16a60e8d376f01b9cdbd6ed4b47302ce449735c54
first_diff_index=7
primary=BAR0: 32 bit prefetchable memory at 0x80000000 [0x81ffffff]
secondary=BAR0: 32 bit prefetchable memory (not mapped)
```

- Interpretation:
  - this is progress, not a repeat of Run 100.
  - the next problem is not argv capture and not static manifest generation.
  - the secondary runtime is still in a pre-realized PCI state when the live
    topology gate samples it: many PCI bridge/device BARs are `not mapped`,
    bridge secondary bus values are `0`, and IRQ values are `0`.
  - the primary has fully realized PCI resources after start, while the
    secondary has not realized the same bus/resource assignment before
    migration.
- Repetition guard:
  - if the same error recurs, do not rework argv capture again.
  - next design must focus on making the secondary realize/settle PCI topology
    before the pre-migrate topology comparison, or on comparing a migration-safe
    topology identity that excludes runtime BAR allocation while still checking
    bus/slot/function/device identity.

### Run 101 Fix Plan 2026-06-06

- Correction target:
  - Run 101 proved that static guest ABI manifest generation and live argv
    capture are now working.
  - The remaining pre-migrate stop was caused by comparing complete HMP
    `info pci` text, including runtime BAR/IRQ/resource allocation state.
  - The first difference was `BAR0 ...` versus `BAR0 ... (not mapped)`, which
    is not by itself a migration ABI identity mismatch.
- Design update:
  - keep strict live QEMU `-device` argument comparison;
  - replace full `info pci` text comparison with PCI identity comparison:
    - bus/device/function address;
    - class/vendor/device id line;
    - PCI subsystem line;
    - QEMU device `id` line;
  - ignore and preserve as evidence only:
    - BAR lines;
    - IRQ lines;
    - bridge bus/resource windows;
    - `not mapped` runtime resource text.
  - classify a real identity difference as
    `xcolo_live_pci_identity_mismatch`.
  - record resource-only differences as
    `xcolo_live_pci_resource_diff_ignored`.
- Repetition guard:
  - if the next run passes this gate and fails later, do not rework argv capture
    or static manifest generation again.
  - if `xcolo_live_pci_identity_mismatch` appears, compare the stored identity
    records first; if only BAR/IRQ/resource differences appear, that is a bug
    in the gate and must be fixed before retrying.

### Run 102 Monitoring Result 2026-06-06

- Test action:
  - user started FT protection after Run 101 cleanup and deployment.
  - Cloud created protection row `102` and standby VM `158` /
    `i-2-158-VM`.
- Confirmed improvement:
  - the Run 101 resource-only BAR/`not mapped` comparison did not recur as the
    failure classification.
  - static generated guest ABI manifest stayed `ok`.
  - primary and secondary generated runtimes both started.
  - failure was still pre-migrate, before `primary.migrate`, so QEMU did not
    reach the old assertion or the COLO invalid-message phase.
- Final result:

```text
ftctl_protection.id=102
protection_state=error
transport_state=failed
active_side=secondary
last_error=xcolo_live_pci_identity_mismatch
xcolo_protocol_failure_phase=pre_migrate_live_topology
```

- Failure evidence:

```text
first_diff_index=3
primary={"addr":"bus=1 device=0 function=0","class":"PCI bridge: PCI device 1b36:000e","id":"id \"pci.6\""}
secondary={"addr":"bus=0 device=2 function=1","class":"PCI bridge: PCI device 1b36:000c","id":"id \"pci.2\""}
```

- Interpretation:
  - this is progress, not a repeat of Run 101.
  - live `info pci` is still too early as a fatal pre-migrate check for an
    incoming/paused secondary.
  - the secondary had not realized downstream PCI bridge bus numbers and child
    devices yet, so HMP `info pci` identity did not line up even though the
    generated manifest and live `-device` argv were already aligned.
  - primary QEMU logs also showed repeated `filter mirror send
    failed(Operation not permitted)`, but the run did not reach the phase where
    that can be treated as the primary failure cause.
- Repetition guard:
  - do not strengthen pre-migrate HMP `info pci` fatal comparison again.
  - next design must demote pre-migrate PCI identity/resource differences to
    evidence and let the run proceed to `primary.migrate`.
  - if the next run fails after migrate, classify it from QEMU migrate status,
    COLO invalid-message logs, and filter mirror errors with the stored
    PCI/qtree/mtree evidence as context.

### Run 102 Fix Plan 2026-06-06

- Correction target:
  - remove HMP `info pci` identity from the pre-migrate fatal gate.
  - keep `info pci`, normalized PCI identity, `info qtree`, and `info mtree`
    as persisted evidence.
  - keep strict fatal comparison for live QEMU `-device` argv because that is
    the startup commandline shape FTCTL actually controls.
- Design update:
  - `xcolo_live_qemu_argv_mismatch` remains fatal.
  - missing or mismatched `info pci` becomes warning/evidence:
    - `xcolo_live_pci_snapshot_missing`
    - `xcolo_live_pci_identity_missing`
    - `xcolo_live_pci_identity_diff_observed`
    - `xcolo_live_pci_resource_diff_ignored`
  - record the warning in state as `xcolo_live_pci_evidence`.
  - pre-migrate gate result remains `ok` when live `-device` argv matches.
- Repetition guard:
  - if a later run fails with `Operation not permitted` or invalid COLO
    messages, do not return to pre-migrate PCI gating unless the live
    `-device` argv or static ABI manifest actually differs.

### Run 103 Monitoring Result 2026-06-07

- Test action:
  - user started FT protection after Run 102 cleanup and deployment.
  - Cloud created protection row `103` and standby VM `159` /
    `i-2-159-VM`.
- Confirmed improvement:
  - Run 102 pre-migrate PCI identity failure did not recur.
  - generated primary/secondary runtime started.
  - `primary.migrate` was executed and accepted.
  - primary entered COLO/migrate state instead of failing before migrate.
- Final observed stuck state before this fix:

```text
ftctl_protection.id=103
protection_state=pairing
transport_state=planned
active_side=secondary
primary=i-2-54-VM on 10.10.32.3 status=colo/paused
secondary=i-2-159-VM on 10.10.32.1 missing from libvirt
```

- Secondary QEMU evidence:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
shutting down, reason=crashed
```

- Interpretation:
  - this is progress, not a repeat of Run 102.
  - the remaining issue is now post-migrate migration ABI/runtime topology
    compatibility.
  - Cloud DB said standby `Running` because the transient secondary QEMU domain
    crashed after libvirt start; FTCTL did not yet classify that crash and left
    the protect job/lock in a pending state.
- Repetition guard:
  - do not return to pre-migrate `info pci` fatal gating.
  - do not rework live argv/static manifest unless the new evidence shows a
    real commandline mismatch.
  - if `memory_region_add_subregion_common` appears again, it must be reported
    as a repeated post-migrate secondary QEMU assertion and investigated from
    the captured argv/qtree/mtree/PCI evidence.

### Run 103 Fix Plan 2026-06-07

- Correction target:
  - classify secondary disappearance after `primary.migrate` as an immediate
    post-migrate failure instead of runtime pending.
  - preserve evidence needed for the next ABI diff pass.
  - guarantee the protect job enters runtime recovery, releases its lock, and
    returns Cloud state to `error`/`failed`.
- Design update:
  - after primary migrate status becomes `active`/`colo`, or primary COLO mode
    becomes `primary`, missing secondary QMP/libvirt state is treated as
    `post_migrate_secondary_crash`.
  - if the secondary QEMU log contains `memory_region_add_subregion_common` or
    `subregion->container`, the exact error is:

```text
xcolo_secondary_qemu_assert_memory_region_container
```

  - otherwise the exact error is:

```text
xcolo_secondary_runtime_missing_after_migrate
```

  - evidence is stored under `debug/xcolo/<vm>/`, including
    `migration-abi-failure-summary-post_migrate_secondary_crash.txt`.

### Run 104 Monitoring Result 2026-06-07

- Test action:
  - user started FT protection after the Run 103 classification fix and
    cleanup.
  - Cloud created protection row `104` and standby VM `160` /
    `i-2-160-VM`.
- Confirmed improvement:
  - Run 103 `pairing/planned` stuck state did not recur.
  - `primary.migrate` reached the post-migrate path again.
  - FTCTL classified the secondary QEMU assertion as:

```text
xcolo_secondary_qemu_assert_memory_region_container
```

  - runtime recovery ran and restored the primary VM to `Running`.
  - protection state became `error` / `failed` with `active_side=primary`.
- Final state:

```text
ftctl_protection.id=104
protection_state=error
transport_state=failed
active_side=primary
last_error=xcolo_secondary_qemu_assert_memory_region_container
primary=i-2-54-VM on 10.10.32.3 running
secondary=i-2-160-VM on 10.10.32.1 DB Running
```

- Evidence summary:

```text
phase=post_migrate_secondary_crash
primary_argv_devices=20
secondary_argv_devices=20
primary_argv=sha256:c81dfae45e64d6166a2c315467ff251fc63044af535c1903dd6f36d06c126d42
secondary_argv=sha256:03280b27b061984a1f53933747a5f7d24b6301fb433b8ef5f7bc462339b5dd47
secondary_log_assertion=qemu-kvm: ../system/memory.c:2666:
memory_region_add_subregion_common: Assertion `!subregion->container' failed.
```

- Interpretation:
  - this is a repeated post-migrate secondary QEMU assertion.
  - the new classification/recovery code worked, so the next work must not
    revisit the stuck-state fix.
  - the next diagnosis must compare the persisted primary/secondary runtime
    ABI evidence, especially the one-byte-different QEMU argv and the
    unavailable post-crash secondary qtree/mtree snapshots.
- Repetition guard:
  - if the next run again ends with
    `xcolo_secondary_qemu_assert_memory_region_container`, report it as the
    same repeated post-migrate migration ABI issue.
  - do not rework baseline seed, pre-migrate PCI warning behavior, or the
    crash classification path unless new evidence points there.
  - next design should target deterministic primary/secondary QEMU commandline
    equivalence and migration ABI compatibility before `primary.migrate`.

### Run 104 Fix Plan 2026-06-07

- Design document:
  - `368-ft-xcolo-pre-migrate-contract-gate-design-20260607.md`
- Correction target:
  - stop treating primary/secondary QEMU argv as one identical blob because
    COLO primary and secondary roles intentionally differ.
  - split the pre-migrate contract into:
    - identical guest-visible `-device` ABI;
    - role-specific COLO chardev/object topology;
    - ready primary/secondary block replication graph.
  - run this contract gate after secondary NBD export and primary NBD child
    attachment, but before `primary.migrate`.
- Expected evidence:
  - `migration-abi-contract-pre_migrate_contract.txt`
  - `xcolo_pre_migrate_contract=ok|failed`
  - specific failure names:

```text
xcolo_guest_abi_contract_mismatch
xcolo_colo_role_contract_mismatch
xcolo_primary_block_replication_contract_incomplete
xcolo_secondary_block_replication_contract_incomplete
```

- Repetition guard:
  - if the contract fails, do not proceed to `primary.migrate`; report the
    exact contract failure.
  - if the contract passes and
    `xcolo_secondary_qemu_assert_memory_region_container` repeats, report it
    as a deeper QEMU migration-load compatibility problem rather than changing
    the already-fixed crash classification path.

### Build Artifact Correction 2026-06-07

- During deployment preparation for the Run 104 fix, GitHub Actions run
  `27067140063` succeeded at commit `84a014d`, but the downloaded RPM did not
  contain `ftctl_xcolo_validate_pre_migrate_contract`.
- Cause:
  - `make ftctl-rpm` reused the `rpmbuild_ftctl` working tree.
  - because the package version/release stayed constant, stale build contents
    could be packaged even though the checked-out source had the new code.
- Correction:
  - clean `rpmbuild_ftctl` at the start of the `ftctl-rpm` target before
    creating `BUILD`, `SOURCES`, `SPECS`, and output directories.
- Verification rule:
  - before deployment, extract the produced RPM and require the installed
    `xcolo.sh` to contain:

```text
ftctl_xcolo_validate_pre_migrate_contract
xcolo_pre_migrate_contract
migration-abi-contract
xcolo_primary_block_replication_contract_incomplete
```

### Run 105 Monitoring Result 2026-06-07

- Test action:
  - user started FT protection after the pre-migrate contract gate deployment.
  - Cloud created protection row `105` and standby VM `161` /
    `i-2-161-VM`.
- Confirmed progress:
  - baseline seed completed for both disks:
    - `sda` -> `2be4ca9a-db2c-42c2-b3ad-e2881d2a5044`
    - `sdb` -> `88b5a874-e572-4529-a0d7-e76e9cc75801`
  - generated primary and secondary runtimes both started.
  - startup disk graph validation passed for both roles.
  - guest ABI manifest hash matched.
  - the new pre-migrate contract gate passed:

```text
xcolo_pre_migrate_contract=ok
primary_guest_device_hash=300be4bcf48efd3a782ebb18f644c60234b33c7c293272b3c17e675e9a622b37
secondary_guest_device_hash=300be4bcf48efd3a782ebb18f644c60234b33c7c293272b3c17e675e9a622b37
primary_block_graph=yes
secondary_block_graph=yes
```

  - `primary.migrate` was accepted.
  - post-migrate startup-active validation initially saw both `9003` and
    `9004` established.
- Final state:

```text
ftctl_protection.id=105
protection_state=error
transport_state=failed
active_side=primary
last_error=xcolo_secondary_qemu_assert_memory_region_container
primary=i-2-54-VM running on 10.10.32.3
secondary=i-2-161-VM paused on 10.10.32.1
```

- Secondary QEMU evidence:

```text
qemu-kvm: ../system/memory.c:2666:
memory_region_add_subregion_common: Assertion `!subregion->container' failed.
shutting down, reason=crashed
```

- Additional evidence:
  - pre-migrate contract did not fail, so this is not a COLO role or block
    graph readiness failure.
  - `live-topology-diff-before_migrate.txt` still recorded a pre-migrate PCI
    identity warning:

```text
warning=xcolo_live_pci_identity_diff_observed
pci_first_diff_index=3
pci_primary={"addr":"bus=1 device=0 function=0","class":"PCI bridge: PCI device 1b36:000e","id":"id \"pci.6\"","subsystem":""}
pci_secondary={"addr":"bus=0 device=2 function=1","class":"PCI bridge: PCI device 1b36:000c","id":"id \"pci.2\"","subsystem":""}
```

- Repetition guard:
  - this is the same repeated post-migrate secondary QEMU assertion seen in
    Runs 103 and 104.
  - the new gate improved evidence quality but did not prevent the crash.
  - do not revisit baseline seed, network socket readiness, or block graph
    readiness for this failure unless new evidence contradicts Run 105.
- Next direction:
  - promote pre-migrate PCI identity mismatch from warning to hard failure.
  - extend the migration ABI contract beyond guest `-device` lists to require
    deterministic PCI bus identity/order from `info pci`, because QEMU crashes
    while applying incoming migration memory/device state after a known PCI
    identity mismatch.
  - the fix should target secondary generated runtime topology so that `info
    pci` identity matches primary before `primary.migrate`, rather than adding
    another post-crash classifier.

### Run 105 Fix Plan 2026-06-10

- Design document:
  - `369-ft-xcolo-live-pci-identity-hard-gate-design-20260610.md`
- Correction target:
  - convert `xcolo_live_pci_identity_diff_observed` from warning to hard
    pre-migrate failure.
  - keep BAR/IRQ/resource differences diagnostic-only.
  - require stable PCI identity fields from `info pci` to match before
    `primary.migrate`:
    - bus / device / function;
    - PCI class;
    - QEMU id;
    - subsystem identity when present.
- New failure names:

```text
xcolo_live_pci_snapshot_missing
xcolo_live_pci_identity_missing
xcolo_live_pci_identity_mismatch
```

- Expected result for the next run:
  - if the same Run 105 PCI identity mismatch repeats, fail before
    `primary.migrate` with `xcolo_live_pci_identity_mismatch`.
  - this is intentional progress because it prevents the repeated
    `memory_region_add_subregion_common` secondary crash and leaves deterministic
    PCI identity evidence.

### Run 105 Fix Deployment And Cleanup 2026-06-10

- Source commit:
  - `9f4ca5d fix: hard gate xcolo pci identity`
- GitHub Actions:
  - run `27219160231`
  - RPM artifact upload succeeded.
  - release publishing failed due GitHub secondary rate limit, so the run
    artifact was downloaded directly instead of using a release asset.
- Artifact:
  - `ablestack_vm_ftctl-0.8.0-1.noarch.rpm`
  - SHA256
    `41b622ca4692843b3bdd1a3785fee27786eec0716340a0a0d88a83efff1eb3ff`
- Installed marker verification:
  - `10.10.32.1`: installed and marker
    `xcolo_live_pci_identity_mismatch` present.
  - `10.10.32.2`: installed and marker
    `xcolo_live_pci_identity_mismatch` present.
  - `10.10.32.3`: not installed in this pass because the host is down and not
    reachable from management (`ping=fail`, `ssh22=closed`).
- Cleanup result:
  - `ftctl_protection.id=105` marked removed/stopped.
  - `ftctl.*` details for VM `54` and standby VM `161` removed.
  - standby domain `i-2-161-VM` removed from libvirt on `10.10.32.1`.
  - standby RBD images removed:
    - `2be4ca9a-db2c-42c2-b3ad-e2881d2a5044`
    - `88b5a874-e572-4529-a0d7-e76e9cc75801`
  - primary VM `i-2-54-VM` is now Running on host id `2`
    (`10.10.32.2`), and `query-block-jobs` is empty.
  - timers are active on `10.10.32.1` and `10.10.32.2`.
- Retest readiness note:
  - the target can be retested with the current primary on `10.10.32.2` and
    peer host `10.10.32.1`.
  - full 32.x cluster parity is not complete until `10.10.32.3` is recovered
    and the same RPM is installed there.

### Run 106 Monitoring Result 2026-06-10

- Trigger:
  - user started FT protection for `r97-link-01`.
- Runtime:
  - `ftctl_protection.id=106`
  - primary VM `i-2-54-VM`
  - standby VM `i-2-171-VM`
  - primary host `10.10.32.3`
  - peer host `10.10.32.1`
- Progress:
  - cloud-managed standby VM and volumes were created.
  - baseline seed completed for both disks:
    - `sda`: `30447406-b01a-42ea-8581-5277b05e9c1c`
    - `sdb`: `39708659-be24-4632-9325-34a65c525f4f`
  - primary runtime was restarted with COLO network objects.
  - validation stopped before `primary.migrate`.
- Final state:

```text
protection_state=error
transport_state=failed
last_error=xcolo_live_pci_identity_mismatch
conversion_stage=pre_migrate_live_topology_failed
conversion_state=error
xcolo_protocol_failure_phase=pre_migrate_live_topology
```

- Evidence:

```text
error=xcolo_live_pci_identity_mismatch
reason=info_pci_identity_diff
primary_hash=fcef3d1417811e51b2a8f245afd0a280fba92ce09d79f38ee03a05898cb8e94a
secondary_hash=cd06d6a9c91de206b99973143bf8c54b87b68ff7cf2cf75f8a847006a3a687c8
pci_first_diff_index=3
pci_primary={"addr":"bus=1 device=0 function=0","class":"PCI bridge: PCI device 1b36:000e","id":"id \"pci.6\"","subsystem":""}
pci_secondary={"addr":"bus=0 device=2 function=1","class":"PCI bridge: PCI device 1b36:000c","id":"id \"pci.2\"","subsystem":""}
```

- Repetition guard:
  - the previous `memory_region_add_subregion_common` QEMU assertion did not
    recur.
  - the new hard gate worked as intended: the same class of PCI identity drift
    was detected before migration memory/device state was injected.
  - this is progress, not a loop: the failure moved from post-migrate secondary
    QEMU crash to deterministic pre-migrate ABI evidence.
- Next direction:
  - generate the secondary runtime from the primary live PCI bridge topology,
    not from a partial/static standby XML shape.
  - specifically preserve the extra `pcie-pci-bridge` position where primary
    has `pci.6` at `bus=1 device=0 function=0`, instead of allowing secondary
    to keep `pci.2` as the next identity at `bus=0 device=2 function=1`.

### Run 106 Fix Plan 2026-06-10

- Additional inspection after Run 106:
  - `primary.generated.xml` and `standby.generated.xml` both preserve
    `pcie-to-pci-bridge` alias `pci.6` with address bus `0x01`, slot `0x00`.
  - generated qemu command-line guest disk devices also match for primary and
    secondary.
  - the mismatch is from live secondary `info pci` while the secondary is still
    an incoming migration target; its PCI bridge BARs and secondary bus numbers
    are not assigned yet.
- Correction:
  - keep generated argv/device mismatch as a hard pre-migrate failure.
  - keep fully assigned live PCI identity mismatch as a hard failure.
  - treat the secondary incoming unassigned PCI shape as a deferred evidence
    state, not as a pre-migrate hard failure:

```text
warning=xcolo_live_pci_identity_deferred_for_incoming
xcolo_live_pci_identity=deferred
```

- Design document:
  - `370-ft-xcolo-secondary-incoming-pci-deferred-gate-design-20260610.md`
- Repetition guard:
  - this is not a return to the earlier loop.  The previous fix prevented the
    QEMU assertion and exposed that the live `info pci` gate itself was too
    strict for secondary `-incoming`.
  - the next run must either pass pre-migrate topology and reach migration, or
    fail with a new post-gate reason backed by the preserved evidence.

### Run 106 Fix Deployment And Cleanup 2026-06-10

- Code commit:
  - `b1d8e2d50d2dc809d470f12b8e458827f7992ce1`
  - `fix: defer incoming pci identity`
- Build:
  - GitHub Actions run `27246968152` completed successfully.
  - Built RPM SHA256:
    `aed200ef34671e5161e5f5f9818c59fb343e43f0c99c18baa723929641e3cfc6`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
  - all hosts reported `ablestack_vm_ftctl-0.8.0-1.noarch`.
  - installed script markers were verified on all hosts:
    - `xcolo_live_pci_identity_deferred_for_incoming`
    - `pci_incoming_unassigned`
- Cleanup:
  - Run 106 active protection was marked removed.
  - `ftctl.*` details for VM `54` and standby VM `171` were removed.
  - standby VM `i-2-171-VM` was marked `Expunging`.
  - standby volumes `327` and `328` were marked `Expunged`.
  - standby RBD images were unmapped and removed:
    - `30447406-b01a-42ea-8581-5277b05e9c1c`
    - `39708659-be24-4632-9325-34a65c525f4f`
  - primary VM `i-2-54-VM` was restored from the non-COLO `primary.xml` and
    restarted on `10.10.32.3`.
- Retest readiness checks:
  - active protection count for VM `54`/`171`: `0`.
  - active `ftctl.*` details for VM `54`/`171`: `0`.
  - active standby volumes for VM `171`: `0`.
  - primary VM `i-2-54-VM` state: `Running` on host id `3`.
  - primary QMP `query-block-jobs`: empty list.
  - primary qemu command line no longer contains COLO runtime markers such as
    `colo-compare`, `filter-mirror`, `ftctl-colo`, `9003`, or `9004`.
  - `ablestack-vm-ftctl.timer` is active on all three 32.x hosts.

### Run 107 Monitoring Result 2026-06-10

- User started FT protection for `r97-link-01`.
- Runtime:
  - `ftctl_protection.id=107`
  - primary VM `i-2-54-VM`
  - standby VM `i-2-172-VM`
  - primary host `10.10.32.3`
  - peer host `10.10.32.1`
- Progress:
  - cloud-managed standby VM and volumes were created.
  - baseline seed proceeded.
  - the previous pre-migrate hard stop was not repeated:

```text
xcolo_live_pci_identity=deferred
xcolo_live_pci_identity_warning=xcolo_live_pci_identity_deferred_for_incoming
xcolo_pre_migrate_contract=ok
xcolo_channel_mirror_established=yes
xcolo_channel_compare_established=yes
xcolo_primary_filter_status_pre_migrate=on
```

  - `primary.migrate` was reached.
  - QMP `query-migrate` reported `status=colo` for a period.
- Final state:

```text
protection_state=error
transport_state=failed
last_error=xcolo_secondary_qemu_assert_memory_region_container
xcolo_protocol_failure_phase=post_migrate_secondary_crash
```

- Secondary QEMU assertion:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

- Repetition guard:
  - this is progress from Run 106 because the pre-migrate PCI identity gate was
    passed and the workflow reached actual COLO migration.
  - the recurring assertion is now the active bottleneck and must be analyzed
    from post-migrate `pci/qtree/mtree` evidence instead of being described as a
    generic topology mismatch.

### Run 107 Fix Plan 2026-06-10

- Design document:
  - `371-ft-xcolo-post-migrate-topology-analyzer-design-20260610.md`
- Correction:
  - keep current QEMU command-line, disk graph, RBD path, and COLO filter
    ordering intact.
  - add PCI identity/resource diff counts to the pre-migrate gate.
  - add post-migrate secondary crash topology analysis for:
    - live qemu argv;
    - `info pci`;
    - `info qtree`;
    - `info mtree`.
  - record candidate device/region keys so the next failure can be classified as
    either a new narrowed candidate or a true repeated loop.

### Run 107 Fix Deployment And Cleanup 2026-06-10

- Code commit:
  - `b9da26c39c12b2b1a3a4a1bf41187a17eb772fcd`
  - `fix: analyze xcolo post-migrate topology`
- Build:
  - GitHub Actions run `27248774739` completed successfully.
  - Built RPM SHA256:
    `964b6d59184dc536e44f385135e3e20ccdbf02ab5dc1d619d1c635c07aacab47`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
  - all hosts reported `ablestack_vm_ftctl-0.8.0-1.noarch`.
  - installed script markers were verified on all hosts:
    - `ftctl_xcolo_analyze_runtime_topology_diff`
    - `runtime-topology-analysis`
    - `xcolo_live_pci_identity_diff_count`
- Cleanup:
  - Run 107 active protection was marked removed.
  - `ftctl.*` details for VM `54` and standby VM `172` were removed.
  - standby VM `i-2-172-VM` was destroyed, undefined, and marked `Expunging`.
  - standby volumes `329` and `330` were marked `Expunged`.
  - standby RBD images were unmapped and removed:
    - `8eef18c3-3f37-4925-8160-d8eed643d740`
    - `9de78f02-a618-40a1-99dc-cba16d6376a9`
- Retest readiness checks:
  - active protection count for VM `54`/`172`: `0`.
  - active `ftctl.*` details for VM `54`/`172`: `0`.
  - active standby volumes for VM `172`: `0`.
  - primary VM `i-2-54-VM` state: `Running` on host id `3`.
  - primary QMP `query-block-jobs`: empty list.
  - primary qemu command line does not contain COLO runtime markers such as
    `colo-compare`, `filter-mirror`, `ftctl-colo`, `9003`, `9004`, or `9998`.
  - `ablestack-vm-ftctl.timer` is active on all three 32.x hosts.

### Run 108 Result 2026-06-10

- Test:
  - user started FT protection for `r97-link-01` after Run 107 deployment.
- Observed progress:
  - `primary.migrate` was reached.
  - primary QMP reached `query-migrate status=colo`.
  - primary recovered back to normal `running` after failure handling.
- Final state:

```text
protection_state=error
transport_state=failed
last_error=xcolo_secondary_qemu_assert_memory_region_container
xcolo_protocol_failure_phase=post_migrate_secondary_crash
```

- Secondary QEMU assertion repeated:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

- Analyzer evidence:

```text
xcolo_live_pci_identity_primary_count=18
xcolo_live_pci_identity_secondary_count=12
xcolo_live_pci_identity_diff_count=15
xcolo_live_pci_identity_missing_count=6
xcolo_live_pci_resource_diff_count=129
xcolo_post_migrate_crash_qtree_diff_count=95
xcolo_post_migrate_crash_mtree_diff_count=498
```

- Repetition guard:
  - this is not a new COLO channel/firewall/disk hypothesis.
  - the repeated assertion means migration is still being attempted before the
    secondary live guest topology is proven complete.
  - the next fix must stop before `primary.migrate` when `qtree/mtree` evidence
    already shows an incomplete secondary topology.

### Run 108 Fix Plan 2026-06-10

- Design document:
  - `372-ft-xcolo-pre-migrate-topology-gate-design-20260610.md`
- Correction:
  - keep existing QEMU COLO command sample alignment, RBD path policy, disk
    graph, and filter ordering intact.
  - reuse the topology analyzer before `primary.migrate`, not only after a
    secondary crash.
  - fail with `xcolo_protocol_failure_phase=pre_migrate_topology_analysis` if
    secondary `qtree/mtree` is empty or missing primary guest-visible device
    entries.
  - preserve `info pci` resource differences as evidence because secondary
    `-incoming` can legitimately defer PCI resource assignment before
    migration.

### Run 108 Fix Deployment And Cleanup 2026-06-10

- Code commit:
  - `4b057cfdb52c08afc4b901c8d30b65858e848fce`
  - `fix: gate xcolo pre-migrate topology`
- Build:
  - GitHub Actions run `27252986066` completed successfully.
  - Built RPM SHA256:
    `77893361a2c37c999c16c45f939d9a0b527681263cb0a78eff842a88746d4957`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
  - all hosts reported `ablestack_vm_ftctl-0.8.0-1.noarch`.
  - installed script markers were verified on all hosts:
    - `ftctl_xcolo_require_pre_migrate_runtime_topology_gate`
    - `xcolo_pre_migrate_topology_gate_state`
    - `qtree_missing_device_count`
- Cleanup:
  - Run 108 active protection was marked removed.
  - `ftctl.*` details for VM `54` and standby VM `173` were removed.
  - standby VM `i-2-173-VM` was destroyed, undefined, and marked `Expunging`.
  - standby volumes `331` and `332` were marked `Expunged`.
  - standby RBD images were unmapped and removed:
    - `40b41b61-b1b0-4027-a114-909887a8b5b9`
    - `cd645099-506d-4e88-bf28-d64d673e2c60`
- Retest readiness checks:
  - active protection count for VM `54`/`173`: `0`.
  - active `ftctl.*` details for VM `54`/`173`: `0`.
  - active standby volumes for VM `173`: `0`.
  - primary VM `i-2-54-VM` state: `Running` on host id `3`.
  - primary QMP `query-block-jobs`: empty list.
  - primary qemu command line does not contain COLO runtime markers such as
    `colo-compare`, `filter-mirror`, `ftctl-colo`, `9003`, `9004`, or `9998`.
  - standby RBD images for Run 108 were absent from the RBD pool.
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` are active on
    all three 32.x hosts.

### Run 109 Monitor Result 2026-06-10

- Test:
  - user started FT protection for `r97-link-01` after Run 108 topology gate
    deployment.
- Run identity:
  - protection id: `109`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `174` / `i-2-174-VM`
  - primary host: `10.10.32.3`
  - secondary host: `10.10.32.1`
- Progress observed:
  - baseline seed completed for both `sda` and `sdb`.
  - generated primary and secondary domains started.
  - pre-migrate live topology capture completed.
  - pre-migrate runtime topology gate passed:

```text
xcolo_pre_migrate_topology_gate_state=ok
xcolo_pre_migrate_qtree_diff_count=0
xcolo_pre_migrate_mtree_diff_count=493
xcolo_pre_migrate_pci_diff_count=15
```

  - `primary.migrate` was executed and accepted.
  - post-migrate transition initially reported `primary_migrate=active` and
    `secondary_migrate=active`.
- Final state:

```text
protection_state=error
transport_state=failed
last_error=xcolo_colo_chardev_contract_not_ready
xcolo_protocol_failure_phase=post_migrate_chardev_contract
```

- Chardev evidence:

```text
xcolo_post_migrate_startup_active_validation_chardev_contract_ready=yes
xcolo_post_migrate_startup_active_validation_chardev_contract_directional_ready=yes
xcolo_post_migrate_startup_active_validation_chardev_contract_strict_frontend_ready=no
xcolo_post_migrate_startup_active_validation_chardev_contract_primary_mirror0=present_closed
xcolo_post_migrate_startup_active_validation_chardev_contract_primary_mirror0_backend=connected
xcolo_post_migrate_startup_active_validation_chardev_contract_secondary_red0=present_open
xcolo_post_migrate_startup_active_validation_chardev_contract_secondary_red0_backend=connected
xcolo_primary_filter_activation_failed_reason=mirror_path_secondary_red0=query_failed,compare_path_secondary_red1=query_failed/query_failed
```

- Repetition guard:
  - this is progress from Run 108.
  - the previous `memory_region_add_subregion_common` assertion was not the
    observed failure in this run.
  - the active bottleneck moved to post-migrate chardev contract verification
    and secondary chardev query/availability during filter activation.

### Run 109 Fix Plan 2026-06-10

- Design document:
  - `373-ft-xcolo-post-migrate-role-transition-gate-design-20260610.md`
- QEMU 9.2.4 code basis:
  - `query-chardev` frontend-open reflects QEMU chardev frontend handler state,
    not only socket backend connectivity.
  - COLO source/secondary role transition happens after `migrate` is accepted,
    before checkpoint exchange is stable.
- Correction:
  - keep the current QEMU COLO command sample alignment, XML topology, RBD
    stable path policy, disk graph, and filter object order unchanged.
  - classify `query-chardev` failure as `query_state` and
    `query_transient` instead of collapsing it into a final contract failure
    immediately.
  - add a post-migrate role-transition gate before the final chardev contract
    gate.
  - retry QMP status, migration status, COLO mode, socket snapshot, and chardev
    contract evidence during the role-transition window.
  - fail with `xcolo_protocol_failure_phase=post_migrate_role_transition` and
    `last_error=xcolo_secondary_chardev_query_unstable_after_migrate` only when
    secondary chardev query remains unavailable for the whole transition
    window.
- Repetition guard:
  - if the next run still fails with `Received invalid message 0x0000` or
    `Can't receive COLO message`, this fix did not address the channel contract
    root cause and the next analysis must return to QEMU protocol ordering.
  - if the next run fails with the new role-transition state keys, the failure
    is expected to be more precisely localized than Run 109.

### Run 109 Fix Deployment And Cleanup 2026-06-10

- Code commit:
  - `4c8ea943c30b5fd97aa9ec9c7bbd85457a966ec6`
  - `fix: wait xcolo post-migrate role transition`
- Build:
  - GitHub Actions run `27255659381` completed successfully.
  - Built RPM SHA256:
    `6b6a9a901892001cfb177ab8555df759aa17e00c6da9c1c87f11d0acf33a3203`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
  - all hosts reported `ablestack_vm_ftctl-0.8.0-1.noarch`.
  - installed script markers were verified on all hosts:
    - `ftctl_xcolo_wait_post_migrate_role_transition`
    - `query_transient`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` were active on
    all three hosts after deployment and cleanup.
- Cleanup:
  - Run 109 active protection was marked removed.
  - `ftctl.*` details for VM `54` and standby VM `174` were removed.
  - standby VM `i-2-174-VM` was destroyed, undefined, and marked `Expunging`.
  - standby volumes `333` and `334` were marked `Expunged`.
  - standby RBD images were unmapped and removed:
    - `3c246c5d-d19d-49ec-98ce-197df3ca97fe`
    - `69982112-c591-4481-84f6-10645a21452f`
  - stale `/run/ablestack-vm-ftctl/xcolo-primary-create.i-2-54-VM.*`
    directories were removed from `10.10.32.3`.
- Retest readiness checks:
  - active protection count for VM `54`/`174`: `0`.
  - active `ftctl.*` details for VM `54`/`174`: `0`.
  - active standby volumes `333`/`334`: `0`.
  - primary VM `i-2-54-VM` state: `Running` on host id `3`.
  - primary QMP `query-block-jobs`: empty list.
  - no remaining FTCTL runtime/profile files matched `i-2-54-VM`,
    `i-2-174-VM`, or `r97-link-01`.
  - standby RBD images for Run 109 were absent from the RBD pool.

### Run 110 Monitor Result 2026-06-10

- Test:
  - user started FT protection for `r97-link-01` after Run 109
    role-transition gate deployment.
- Run identity:
  - protection id: `110`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `175` / `i-2-175-VM`
  - primary host: `10.10.32.3`
  - secondary host: `10.10.32.1`
- Progress observed:
  - standby VM was created in Cloud DB and later reached DB `Running`.
  - primary and secondary libvirt domains entered paused runtime during XCOLO
    activation.
  - pre-migrate runtime topology gate passed again:

```text
xcolo_pre_migrate_topology_gate_state=ok
```

  - post-migrate role-transition gate was entered and retried:

```text
xcolo_post_migrate_role_transition_gate=waiting
xcolo_post_migrate_role_transition_attempts=28
xcolo_post_migrate_role_transition_primary_migrate=colo
xcolo_post_migrate_role_transition_secondary_migrate=
xcolo_post_migrate_role_transition_chardev_query_state=secondary_query_failed
xcolo_post_migrate_role_transition_chardev_query_transient=yes
```

- Final state:

```text
protection_state=error
transport_state=failed
active_side=primary
last_error=xcolo_secondary_chardev_query_unstable_after_migrate
xcolo_protocol_failure_phase=post_migrate_role_transition
xcolo_post_migrate_role_transition_gate=failed
xcolo_post_migrate_role_transition_attempts=30
xcolo_post_migrate_role_transition_reason=chardev_query_transient
```

- Secondary QEMU evidence:

```text
Unable to connect character device red0: Failed to connect to '10.10.32.3:9003': Connection refused
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
shutting down, reason=crashed
```

- Repetition guard:
  - this is not a successful COLO activation.
  - the new role-transition gate improved classification: the failure is no
    longer reported as generic `xcolo_colo_chardev_contract_not_ready`.
  - the same secondary QEMU memory-region assertion reappeared behind the
    chardev query failure, so the next fix must return to secondary migration
    ABI/topology parity rather than extending chardev wait time.
  - the secondary also attempted `red0` before primary `9003` was available;
    the next analysis must decide whether this is a symptom of the secondary
    crash/start ordering or an independent channel ordering defect.

### Run 110 Fix Plan 2026-06-10

- Design document:
  - `374-ft-xcolo-secondary-mtree-materialization-gate-design-20260610.md`
- QEMU 9.2.4 code basis:
  - `memory_region_add_subregion_common()` asserts when a MemoryRegion already
    has a container and QEMU attempts to add it again.
  - Run 110 secondary mtree showed PCI bridge aliases and BAR-backed regions
    still materialized as zero-range entries while primary had assigned runtime
    BAR ranges.
- Correction:
  - keep generated QEMU command sample alignment, COLO filter order, disk graph,
    and RBD path policy unchanged.
  - extend runtime topology analysis with zero-range PCI alias counts from
    `info mtree`.
  - fail before `primary.migrate` when secondary has materially more zero-range
    PCI aliases than primary.
  - classify role-transition timeout as
    `xcolo_secondary_qemu_assert_memory_region_container` if secondary QEMU log
    contains `memory_region_add_subregion_common` or `subregion->container`.
- Repetition guard:
  - if the next run fails before `primary.migrate` with
    `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`, the change is
    working as a crash-prevention gate, but the next fix must materialize or
    eliminate the secondary PCI resource mismatch.
  - if the next run still reaches QEMU assertion after `primary.migrate`, the
    mtree zero-alias detector is incomplete and must be expanded with a more
    precise PCI BAR/mtree materialization rule.

### Run 110 Fix Deployment And Cleanup 2026-06-10

- Code commit:
  - `c262e7b9d12b64fddfa4a48c3e2744bd7912d380`
  - `fix: gate xcolo secondary mtree materialization`
- Build:
  - GitHub Actions run `27259176324` completed successfully.
  - Built RPM SHA256:
    `fb7e945e1567c38d3fdd3d04672871375e06161cc93c3bd45e314b9932e7e666`
- Deployment:
  - deployed to `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
  - all hosts reported `ablestack_vm_ftctl-0.8.0-1.noarch`.
  - installed script markers were verified on all hosts:
    - `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`
    - `secondary_qemu_assert_memory_region_container`
  - `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer` were active on
    all three hosts after deployment and cleanup.
- Cleanup:
  - Run 110 active protection was marked removed.
  - `ftctl.*` details for VM `54` and standby VM `175` were removed.
  - standby VM `i-2-175-VM` was destroyed, undefined, and marked `Expunging`.
  - standby volumes `335` and `336` were marked `Expunged`.
  - standby RBD images were unmapped and removed:
    - `21e24b9b-7167-4918-9c19-d5ae84f97427`
    - `5fc9a137-5c11-4a89-8f48-aec5e0da55d4`
- Retest readiness checks:
  - active protection count for VM `54`/`175`: `0`.
  - active `ftctl.*` details for VM `54`/`175`: `0`.
  - active standby volumes `335`/`336`: `0`.
  - primary VM `i-2-54-VM` state: `Running` on host id `3`.
  - primary QMP `query-block-jobs`: empty list.
  - no remaining FTCTL runtime/profile files matched `i-2-54-VM`,
    `i-2-175-VM`, or `r97-link-01`.
  - standby RBD images for Run 110 were absent from the RBD pool.

### Run 111 Monitor Result 2026-06-10

- Test target:
  - primary VM: `r97-link-01`, VM id `54`, domain `i-2-54-VM`.
  - standby VM: `r97-link-01-standby`, VM id `176`, domain `i-2-176-VM`.
  - protection id: `111`.
  - primary host: `10.10.32.3`.
  - secondary host: `10.10.32.1`.
- Final state:
  - `protection_state=error`.
  - `transport_state=failed`.
  - `active_side=primary`.
  - `last_error=xcolo_pre_migrate_secondary_pci_resources_unmaterialized`.
  - primary VM `i-2-54-VM` remained `Running` on host id `3`.
  - standby VM `i-2-176-VM` remained `Running` in Cloud DB on host id `1`,
    while libvirt reported the domain as paused.
- Primary FTCTL state evidence:
  - `xcolo_protocol_failure_phase=pre_migrate_topology_analysis`.
  - `xcolo_pre_migrate_topology_gate_state=failed`.
  - `xcolo_pre_migrate_topology_gate_error=xcolo_pre_migrate_secondary_pci_resources_unmaterialized`.
  - `xcolo_pre_migrate_qtree_diff_count=0`.
  - `xcolo_pre_migrate_mtree_diff_count=497`.
  - `xcolo_pre_migrate_mtree_primary_zero_pci_alias_count=0`.
  - `xcolo_pre_migrate_mtree_secondary_zero_pci_alias_count=48`.
  - `xcolo_pre_migrate_topology_gate_reason=0000000000000000-0000000000000000_(prio_1,_i/o):_alias_pci_bridge_mem_@pci_bridge_pci_0000000000000000-0000000000000000`.
- Captured debug analysis:

```text
context=pre_migrate
phase=before_migrate
pci_primary_count=18
pci_secondary_count=12
pci_diff_count=15
pci_first_diff_index=3
qtree_primary_lines=95
qtree_secondary_lines=95
qtree_diff_count=0
qtree_primary_device_count=57
qtree_secondary_device_count=57
qtree_missing_device_count=0
qtree_extra_device_count=0
mtree_primary_lines=498
mtree_secondary_lines=285
mtree_diff_count=497
mtree_primary_zero_pci_alias_count=0
mtree_secondary_zero_pci_alias_count=48
mtree_first_secondary_zero_pci_alias=0000000000000000-0000000000000000 (prio 1, i/o): alias pci_bridge_mem @pci_bridge_pci 0000000000000000-0000000000000000
assert_candidate_reason=secondary_zero_range_pci_alias
topology_gate_state=failed
topology_gate_error=xcolo_pre_migrate_secondary_pci_resources_unmaterialized
```

- Migration ABI contract check:

```text
state=ok
guest_device_count=20
primary_guest_device_hash=300be4bc...
secondary_guest_device_hash=300be4bc...
primary_block_graph=yes
secondary_block_graph=yes
```

- Secondary QEMU log:

```text
qemu-kvm: Unable to connect character device red0: Failed to connect to '10.10.32.3:9003': Connection refused
```

- Result interpretation:
  - this run did not complete FT protection.
  - the Run 110 gate improved behavior: the system stopped before
    `primary.migrate`, so the previous secondary QEMU
    `memory_region_add_subregion_common` assertion was not reached.
  - guest-visible qtree and command contract still match, but the secondary
    incoming VM has not materialized PCI resources to the same runtime mtree
    shape as the primary.
  - the next correction must materialize or eliminate the secondary PCI resource
    mismatch before migrate. Waiting longer or retrying the same migrate path is
    a repeat-risk because `qtree_diff_count=0` while `mtree_diff_count=497`.
  - the `red0` connection refusal is still present. In this run it is secondary
    QEMU attempting to connect before primary `9003` is listening, but the run
    is gated earlier by mtree materialization; handle it after or together with
    the secondary startup/materialization fix.
- Evidence retention:
  - debug files were copied from
    `10.10.32.3:/run/ablestack-vm-ftctl/debug/xcolo/i-2-54-VM` to
    `/tmp/run111-evidence/i-2-54-VM`.
  - cleanup was not performed after this failure so the failed state remains
    available for follow-up analysis.
- Repetition guard:
  - this is progress from Run 110 because QEMU did not crash and the gate
    identified the exact pre-migrate topology mismatch.
  - if the next run again fails with
    `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`, report it as a
    repeated blocker unless the secondary mtree or PCI materialization counts
    materially changed.
  - do not classify another identical run as a new network or chardev issue
    unless `mtree_secondary_zero_pci_alias_count` is fixed first.

### Run 111 Fix Plan 2026-06-10

- Design document:
  - `375-ft-xcolo-secondary-mtree-deferred-materialization-design-20260610.md`
- Conflict resolution:
  - `374-ft-xcolo-secondary-mtree-materialization-gate-design-20260610.md`
    now states that its hard pre-migrate zero-alias failure rule is superseded
    in part by the deferred materialization design.
- Correction:
  - keep hard failures for missing guest qtree devices and empty secondary
    qtree/mtree snapshots.
  - change pre-migrate secondary zero-range PCI alias mismatch from hard fail to
    deferred when guest topology is otherwise present.
  - after `primary.migrate`, run a new post-migrate materialization gate before
    treating filter activation as stable.
  - if secondary zero-range PCI aliases remain after migration, fail with
    `xcolo_post_migrate_secondary_pci_resources_unmaterialized`.
- Local validation:
  - targeted selftests passed:
    - `selftest_case_xcolo_mtree_zero_alias_deferred_before_migrate`
    - `selftest_case_xcolo_mtree_zero_alias_fails_after_migrate`
- Repetition guard:
  - if the next run reaches `primary.migrate` and then fails at
    `post_migrate_materialization`, this is progress and means the deferred
    incoming hypothesis was exercised.
  - if the next run still fails before `primary.migrate` with
    `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`, the new code is
    not installed or guest topology is no longer equal.
  - if the next run reaches the old QEMU assertion again, the post-migrate
    materialization gate is too late or incomplete and must capture evidence
    before secondary exits.

### Run 111 Fix Deployment And Cleanup 2026-06-10

- Code commit:
  - `bded92f09ff8ca374ba22dbb921f9d656aee40ef`
  - `fix: defer xcolo incoming mtree materialization`
- Local validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed.
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed.
  - `git diff --check`: passed.
  - targeted selftests passed:
    - `selftest_case_xcolo_mtree_zero_alias_deferred_before_migrate`
    - `selftest_case_xcolo_mtree_zero_alias_fails_after_migrate`
  - full selftest with shellcheck mocked did not complete cleanly; it stopped
    in an existing backend-validation area before reaching all later cases.
- Build:
  - GitHub Actions run `27263803133` completed successfully.
  - Built RPM SHA256:
    `1313c17b4826bb6828b6d9a4ef521fc5b1c830044d5b519896457bda57ae5fe9`.
- Deployment:
  - deployed `ablestack_vm_ftctl-0.8.0-1.noarch` to `10.10.32.1`,
    `10.10.32.2`, and `10.10.32.3`.
  - all three hosts reported active `ablestack-vm-ftctl.timer` and
    `ablestack-vm-hangctl.timer`.
  - installed script markers were verified on all three hosts:
    - `xcolo_pre_migrate_secondary_pci_resources_deferred_for_incoming`
    - `xcolo_post_migrate_secondary_pci_resources_unmaterialized`
- Cleanup:
  - Run 111 active protection row was marked removed/disabled.
  - `ftctl.*` VM details for VM `54` and standby VM `176` were removed.
  - standby domain `i-2-176-VM` was destroyed/undefined.
  - standby VM `176` was marked `Expunging`.
  - standby volumes `337` and `338` were marked `Expunged`.
  - standby RBD images were removed:
    - `361039a4-3557-4e37-84fb-191b1d634fe8`
    - `f7646f32-f880-4923-9fe5-9717720c8926`
  - stale secondary-host maps for the primary/standby images were removed from
    `10.10.32.1`; primary host maps on `10.10.32.3` were preserved.
- Retest readiness checks:
  - active protection count for primary VM `54`: `0`.
  - active `ftctl.*` details for VM `54`/`176`: `0`.
  - primary VM `i-2-54-VM` state: `running` on `10.10.32.3`.
  - primary QMP `query-block-jobs`: empty list.
  - no standby domain `i-2-176-VM` remains on the 32.x hosts.
  - no FTCTL runtime/profile files matched `i-2-54-VM`, `i-2-176-VM`, or
    `r97-link-01`.
  - standby RBD images were absent from the RBD pool.

### Run 112 Monitor Result 2026-06-10

- Trigger:
  - user started FT protection for `r97-link-01` after Run 111 cleanup.
- Runtime identifiers:
  - protection row: `112`
  - primary VM: `54` / `i-2-54-VM`
  - standby VM: `177` / `i-2-177-VM`
  - primary host: `10.10.32.3`
  - standby host: `10.10.32.1`
  - standby root volume image:
    `83e067d2-4e30-453f-b821-349401a6c37a`
  - standby data volume image:
    `b26917ab-fd07-4283-a12e-1296f4694e2e`
- Final Cloud state:
  - `ftctl_protection`: `protection_state=error`,
    `transport_state=failed`, `active_side=primary`.
  - `last_error=xcolo_secondary_qemu_assert_memory_region_container`.
  - primary VM was recovered to `Running`.
  - standby VM remained `Running` in Cloud DB and `paused` in libvirt.
- Progress confirmed:
  - the Run 111 deferred-mtree change was installed and active.
  - pre-migrate topology gate no longer stopped the run with
    `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`.
  - `primary.migrate` was reached and accepted.
  - pre-guest traffic gate passed:
    - `primary_status=paused`
    - `chardev_contract=yes`
  - socket/chardev contract was valid before guest traffic:
    - primary `9003/9004`: listening
    - secondary `9003/9004`: established
    - mirror path:
      `primary:m0 -> mirror0 -> secondary:red0 -> f1`
    - compare path:
      `secondary:f2 -> red1 -> primary:compare1 -> comp0`
- Failure:
  - after `primary.migrate`, secondary QEMU hit:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

  - primary QEMU then reported:

```text
Can't receive COLO message: Input/output error
```

  - post-migrate role transition timed out after 30 attempts because secondary
    QMP/chardev queries failed after the assertion.
- Debug evidence:
  - pre-migrate contract was `state=ok`.
  - primary and secondary guest device hashes matched:
    `300be4bcf48efd3a782ebb18f644c60234b33c7c293272b3c17e675e9a622b37`.
  - primary and secondary block graphs were both detected as valid.
  - live PCI identity was still not equal:
    - primary PCI identity count: `18`
    - secondary PCI identity count: `12`
    - missing secondary PCI identity count: `6`
    - first diff:
      primary `bus=1 device=0 function=0 id "pci.6"` versus secondary
      `bus=0 device=2 function=1 id "pci.2"`.
- Recovery evidence:
  - `block_conversion.handshake_recover result=ok`.
  - `xcolo.runtime_recover result=ok`.
  - primary QMP `query-status`: `running`.
  - primary QMP `query-block-jobs`: empty list.
  - no primary-side lock file remained.
- Interpretation:
  - this is real progress from Run 111 because the test crossed the previous
    pre-migrate gate and entered QEMU migration/COLO state transfer.
  - the deferred secondary PCI materialization hypothesis is only partially
    valid. Deferring the PCI resource mismatch allowed migrate to start, but
    QEMU 9.2.4 still asserted while applying migration state to a secondary
    PCI topology whose live identity/resource materialization was not equal to
    the primary.
  - the repeated root is not the 9003/9004 network path in this run. The
    network/chardev contract was ready before guest traffic; the sockets closed
    only after secondary QEMU crashed.
- Next improvement direction:
  - stop treating `xcolo_live_pci_identity_deferred_for_incoming` as safe
    enough to enter `primary.migrate`.
  - the next code change must make the secondary live PCI identity/materialized
    bridge topology match the primary before migration state load, or fail
    earlier with an explicit ABI error instead of allowing QEMU to assert.
  - concrete focus: clone and verify the primary's live PCI bridge/device
    realization from the libvirt QEMU argv and QMP `info pci`/`info mtree`,
    especially the six missing secondary PCI identities, before issuing
    `primary.migrate`.
- Repetition guard:
  - if another run reaches `primary.migrate` with primary/secondary PCI identity
    counts still `18` versus `12` and fails with the same
    `memory_region_add_subregion_common` assertion, it is a repeated blocker,
    not a new network/chardev issue.
  - the next run should be judged improved only if the pre-migrate secondary
    live PCI identity count and resource layout materially converge toward the
    primary, or the system refuses migrate before QEMU crash with a specific
    ABI mismatch report.

### Run 112 Fix Plan 2026-06-10

- Design document:
  - `376-ft-xcolo-premigrate-pci-identity-hard-abi-gate-design-20260610.md`
- Conflict resolution:
  - `375-ft-xcolo-secondary-mtree-deferred-materialization-design-20260610.md`
    now marks the Run 111 deferred-materialization strategy as superseded for
    pre-migrate success decisions.
- Correction:
  - stop treating incoming secondary PCI identity mismatch as a warning.
  - when secondary `info pci` shows unassigned incoming PCI bridge/device
    identity, fail before `primary.migrate` with
    `xcolo_live_pci_identity_unmaterialized`.
  - when secondary mtree has materially more zero-range PCI bridge aliases than
    primary before migrate, fail before `primary.migrate` with
    `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`.
  - keep debug capture so the next topology-cloning change can compare primary
    and secondary QEMU argv, `info pci`, `info qtree`, and `info mtree`.
- Validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed.
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed.
  - `git diff --check`: passed.
  - targeted selftests passed with shellcheck no-op because the repository has
    pre-existing shellcheck warnings unrelated to this change:
    - `selftest_case_xcolo_mtree_zero_alias_fails_before_migrate`
    - `selftest_case_xcolo_mtree_zero_alias_fails_after_migrate`
- Expected next test result:
  - QEMU should no longer reach the
    `memory_region_add_subregion_common` assertion for the same PCI mismatch.
  - If the secondary PCI topology is still not materialized like primary, FTCTL
    should stop before `primary.migrate` with a specific ABI/topology error.
  - A later success-oriented fix must make the secondary live PCI identity match
    primary, likely by cloning secondary command/device ordering from the
    primary libvirt QEMU argv rather than only matching normalized device hash.

### Run 112 Fix Build Deployment And Cleanup 2026-06-10

- Code commit:
  - `6645c2e7bedbd837978f2bbfd3780dd9b62d43ef`
  - `fix: hard gate xcolo secondary pci identity`
- Build:
  - GitHub Actions run `27278740809` completed successfully.
  - Built RPM SHA256:
    `fb3a9bb8ab11dffcc1d0c52a932495d9bdf85df0d04101361fb0e50637decf20`.
- Deployment:
  - deployed `ablestack_vm_ftctl-0.8.0-1.noarch` to `10.10.32.1`,
    `10.10.32.2`, and `10.10.32.3`.
  - all three hosts reported active `ablestack-vm-ftctl.timer` and
    `ablestack-vm-hangctl.timer`.
  - installed script markers were verified on all three hosts:
    - `xcolo_live_pci_identity_unmaterialized`
    - `xcolo_pre_migrate_secondary_pci_resources_unmaterialized`
  - the obsolete pre-migrate success marker
    `xcolo_pre_migrate_secondary_pci_resources_deferred_for_incoming` was absent
    from installed `xcolo.sh` on all three hosts.
- Cleanup:
  - Run 112 active protection row was marked removed/disabled.
  - `ftctl.*` VM details for VM `54` and standby VM `177` were removed.
  - standby domain `i-2-177-VM` was destroyed/undefined.
  - standby VM `177` was marked `Expunging`.
  - standby volumes `339` and `340` were marked `Expunged`.
  - standby RBD images were removed after unmapping stale `/dev/rbd1` and
    `/dev/rbd2` watchers on `10.10.32.1`:
    - `83e067d2-4e30-453f-b821-349401a6c37a`
    - `b26917ab-fd07-4283-a12e-1296f4694e2e`
  - FTCTL runtime/profile/debug files for `i-2-54-VM`, `i-2-177-VM`, and
    `r97-link-01` were removed from the 32.x hosts.
- Retest readiness checks:
  - active protection count for primary VM `54`: `0`.
  - active `ftctl.*` details for VM `54`/`177`: `0`.
  - primary VM `i-2-54-VM` state: `running` on `10.10.32.3`.
  - primary QMP `query-block-jobs`: empty list.
  - no standby domain `i-2-177-VM` remains on the 32.x hosts.
  - no FTCTL runtime/profile files matched `i-2-54-VM`, `i-2-177-VM`, or
    `r97-link-01`.
  - standby RBD images were absent from the RBD pool.

### Run 113 Result 2026-06-10

- Test target:
  - primary VM `54`, domain `i-2-54-VM`, display name `r97-link-01`.
  - standby VM `178`, domain `i-2-178-VM`.
  - primary host `10.10.32.3`, secondary host `10.10.32.1`.
- Result:
  - failed before `primary.migrate`.
  - `ftctl_protection` row `113` ended with
    `protection_state=error`, `transport_state=failed`, and
    `last_error=xcolo_live_pci_identity_unmaterialized`.
- Progress made:
  - baseline seed for both disks completed.
  - generated primary/secondary startup disk graph validation passed.
  - primary generated listener startup succeeded.
  - secondary incoming domain startup succeeded.
  - COLO channel attach succeeded.
  - FTCTL stopped before QEMU migration/assertion, which confirmed the Run 112
    crash-prevention gate worked.
- Root cause:
  - the hard pre-migrate PCI identity gate was too strict for an incoming
    secondary waiting for migration state.
  - secondary `info pci` showed the expected incoming-unassigned shape:
    root ports with `secondary bus 0`, `subordinate bus 0`, `IRQ 0`, and BARs
    not mapped.
  - primary already had materialized bridge/BAR resources, so the identity hash
    differed before migration even though this does not by itself prove a bad
    migration target.
- Additional cleanup issue:
  - rollback destroyed the secondary, but primary restoration failed and left
    primary running with FT generated quorum/overlay block nodes.
  - Cloud API stop/start was required to restore the primary to the normal
    Cloud/libvirt RBD graph.

### Run 113 Fix Plan 2026-06-10

- Design document:
  - `377-ft-xcolo-incoming-secondary-premigrate-deferred-pci-design-20260610.md`
- Conflict resolution:
  - `376-ft-xcolo-premigrate-pci-identity-hard-abi-gate-design-20260610.md`
    now marks the pre-migrate incoming-secondary hard failure as superseded by
    the Run 113 design.
- Correction:
  - pass `phase` into the live PCI identity analyzer.
  - at `before_migrate`, treat the known incoming-secondary unassigned PCI/BAR
    shape as `xcolo_live_pci_identity_deferred_for_incoming`, not as a hard
    failure.
  - after migration, keep the same unassigned shape as
    `xcolo_live_pci_identity_unmaterialized`.
  - restore the pre-migrate mtree zero-alias gate to deferred state:
    `xcolo_pre_migrate_secondary_pci_resources_deferred_for_incoming`.
  - keep post-migrate mtree zero-alias materialization as a hard failure.
  - on rollback primary-restore failure, set explicit state:
    `active_side=primary`, `peer_domain_expected=false`,
    `standby_state=stopped`, and sticky `*:primary_restore_failed`.
- Validation:
  - `bash -n lib/ftctl/xcolo.sh`: passed.
  - `bash -n bin/ablestack_vm_ftctl_selftest.sh`: passed.
  - `git diff --check`: passed.
  - targeted selftests passed:
    - `selftest_case_xcolo_mtree_zero_alias_defers_before_migrate`
    - `selftest_case_xcolo_mtree_zero_alias_fails_after_migrate`
    - `selftest_case_xcolo_live_pci_incoming_defers_before_migrate`
    - `selftest_case_xcolo_live_pci_incoming_fails_after_migrate`
  - full selftest still stops at repository pre-existing shellcheck warnings,
    unrelated to this change.

### Run 113 Fix Build Deployment And Cleanup 2026-06-10

- Code commit:
  - `894ec767951353fefa4225508b5977322e10791b`
  - `fix: defer incoming xcolo pci materialization`
- Build:
  - GitHub Actions run `27282329090` completed successfully.
  - Built RPM SHA256:
    `3a15fa7b55afe20b4e3d35f872b10fbb8b9684c71b85a607b1cb38e99983831a`.
- Deployment:
  - deployed `ablestack_vm_ftctl-0.8.0-1.noarch` to `10.10.32.1`,
    `10.10.32.2`, and `10.10.32.3`.
  - all three hosts reported active `ablestack-vm-ftctl.timer` and
    `ablestack-vm-hangctl.timer`.
  - installed script marker verified on all three hosts:
    `xcolo_live_pci_identity_deferred_for_incoming`.
- Cleanup:
  - host-side `unprotect --force-cleanup` completed successfully.
  - because primary remained on the FT generated block graph, Cloud API
    stop/start was executed for VM `d08503ff-ea56-4e35-bdf8-2f0ebf81382c`.
  - after Cloud restart, primary `query-named-block-nodes` showed only normal
    `libvirt-*` RBD nodes and no `ftctl-*`, `primary-active`, or `quorum` nodes.
  - standby VM `178` was destroyed/expunged through Cloud API.
  - standby RBD images were unmapped from `10.10.32.1` and removed:
    - `9a30c0b7-553f-4e87-840e-d03cc12697c9`
    - `b8f0ac21-9ee8-47ea-af07-a037512f1055`
  - Run 113 active protection row was marked removed/disabled.
  - `ftctl.*` VM details for VM `54` and standby VM `178` were removed.
  - standby volumes `341` and `342` were marked `Expunged`.
  - FTCTL runtime/profile/debug files for `i-2-54-VM`, `i-2-178-VM`, and
    `r97-link-01` were removed from 32.x hosts.
- Retest readiness checks:
  - active protection count for primary VM `54`: `0`.
  - active `ftctl.*` details for VM `54`/`178`: `0`.
  - primary VM `i-2-54-VM` state: `running` on `10.10.32.3`.
  - primary QGA `guest-ping`: OK.
  - primary QMP `query-block-jobs`: empty list.
  - no standby domain `i-2-178-VM` remains on the 32.x hosts.
  - standby RBD images are absent from the RBD pool.

### Run 114 Result 2026-06-12

- Test target:
  - primary VM `54`, domain `i-2-54-VM`, display name `r97-link-01`.
  - standby VM `179`, domain `i-2-179-VM`.
  - primary host `10.10.32.3`, secondary host `10.10.32.1`.
- Result:
  - baseline seed, generated XML startup, COLO channel attach, pre-migrate guest
    traffic gate, and `primary.migrate` completed.
  - post-migrate startup active validation passed and 9003/9004 sockets were
    established.
  - secondary QEMU then crashed while applying migration state:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

- Classification:
  - this is the same materialization blocker family as Runs 112/113, but Run
    114 proved the Run 113 deferral policy was unsafe.
  - the repeated issue is not the older invalid COLO message/network path.
  - evidence showed `qtree_diff_count=0`, but live PCI/mtree resources were not
    materialized on the secondary:
    - `pci_primary_count=18`
    - `pci_secondary_count=12`
    - `pci_identity_diff_count=15`
    - `pci_identity_missing_count=6`
    - `mtree_primary_zero_pci_alias_count=0`
    - `mtree_secondary_zero_pci_alias_count=48`
    - `assert_candidate_reason=secondary_zero_range_pci_alias`
- Run 114 state after rollback:
  - primary restored to running normal runtime on `10.10.32.3`.
  - standby was left as paused libvirt runtime on `10.10.32.1` while Cloud DB
    still showed the standby as `Running`.
  - protection row `114` remained present with
    `last_error=xcolo_secondary_qemu_assert_memory_region_container`.

### Run 114 Fix Plan 2026-06-12

- Design document:
  - `378-ft-xcolo-premigrate-materialization-failfast-design-20260612.md`
- Conflict resolution:
  - `377-ft-xcolo-incoming-secondary-premigrate-deferred-pci-design-20260610.md`
    is now marked superseded by the Run 114 fail-fast design.
  - `376-ft-xcolo-premigrate-pci-identity-hard-abi-gate-design-20260610.md`
    now records that the temporary Run 113 deferral was reversed after Run 114.
- Correction:
  - if the secondary incoming VM shows unassigned PCI/BAR resources before
    migration, FTCTL must stop before `primary.migrate` with:
    `xcolo_secondary_pci_resource_unmaterialized_before_migrate`.
  - if secondary mtree shows substantially more zero-range PCI aliases than the
    primary before migration, FTCTL must stop with the same error.
  - post-migrate materialization failure remains a hard error, but the expected
    repeated Run 114 condition should no longer reach that phase.
- Repetition control:
  - if the next run returns
    `xcolo_secondary_pci_resource_unmaterialized_before_migrate`, that is the
    same blocker caught earlier and safer than Run 114.
  - if the next run still reaches QEMU
    `memory_region_add_subregion_common`, the pre-migrate evidence gate is
    incomplete and must be extended before another topology change is attempted.
## Run 115 - Generated Runtime Reaches Pre-Migrate Fail-Fast

Date: 2026-06-16

### Result

Run 115 confirmed that the pre-migrate materialization fail-fast gate prevents
the previous QEMU assertion path, but it also confirmed that Primary and
Secondary runtime PCI topology equality is not yet guaranteed.

Observed state:

- protection row: `115`;
- primary VM: `i-2-54-VM`, Cloud VM id `54`, running on `10.10.32.3`;
- standby VM: `i-2-180-VM`, Cloud VM id `180`;
- final protection state: `error/failed`;
- last error:
  `xcolo_secondary_pci_resource_unmaterialized_before_migrate:primary_restore_failed`.

Primary/Secondary live evidence before `primary.migrate`:

- primary PCI identity count: `18`;
- secondary PCI identity count: `12`;
- PCI identity diff count: `15`;
- PCI identity missing count: `6`;
- first diff: primary `pci.6 bus=1 device=0`, secondary
  `pci.2 bus=0 device=2 function=1`.

Rollback evidence:

- the primary domain remained running, but `query-named-block-nodes` still
  showed generated FTCTL block graph nodes such as `ftctl-colo-*`,
  `ftctl-primary-active-*`, and `quorum`;
- this means rollback must verify Cloud-managed graph restoration, not only
  domain running state.

### Repetition Control

This is not a new protocol error. It is the same materialization family caught
earlier than Run 114. The improvement is that QEMU did not reach
`memory_region_add_subregion_common`.

The next change must not keep repeating live-only diagnosis. It must add a
generated Primary/Secondary PCI manifest equality gate and explicit rollback
graph restoration checks as described in
`379-ft-xcolo-canonical-pci-manifest-and-rollback-design-20260616.md`.

## Run 116 - Generated Manifest Passes, Live Secondary Still Unmaterialized

Date: 2026-06-16

### Result

Run 116 reached the new generated manifest gate and passed it. This proves the
new pre-runtime manifest check is active and that the generated Primary and
Secondary definitions are identical at the canonical PCI manifest level.

Observed state:

- protection row: `116`;
- primary VM: `i-2-54-VM`, Cloud VM id `54`, running on `10.10.32.3`;
- standby VM: `i-2-181-VM`, Cloud VM id `181`;
- final protection state: `error/failed`;
- last error: `xcolo_secondary_pci_resource_unmaterialized_before_migrate`.

Generated gate evidence:

- `xcolo.guest_abi_manifest`: `ok`;
- `xcolo.generated_pci_manifest`: `ok`;
- generated PCI manifest hash:
  `c1c417aab462dbc1c5f3cd31359b178b807153160102cce5c60ca4bd37d029df`;
- primary/secondary generated manifest counts: `17` / `17`;
- generated diff file result:
  `ok primary=c1c417... secondary=c1c417...`.

Live runtime evidence before `primary.migrate`:

- `xcolo.live_runtime_topology`: `fail`;
- error: `xcolo_secondary_pci_resource_unmaterialized_before_migrate`;
- primary PCI identity count: `18`;
- secondary PCI identity count: `12`;
- PCI identity diff count: `15`;
- PCI identity missing count: `6`;
- first diff:
  - primary: `bus=1 device=0 function=0`, `PCI bridge 1b36:000e`, `id "pci.6"`;
  - secondary: `bus=0 device=2 function=1`, `PCI bridge 1b36:000c`, `id "pci.2"`.

Rollback evidence:

- secondary generated runtime was destroyed;
- primary generated runtime was destroyed;
- primary was reactivated from backup XML;
- rollback graph validation passed:
  `block_conversion.rollback.primary_restore_graph=ok`;
- after rollback, Primary had no active block jobs and no `ftctl-*` or `quorum`
  nodes in `info block`.

### Repetition Control

This is the same live secondary incoming PCI materialization blocker, but it is
not the same diagnostic state as Run 115.

Progress since Run 115:

- generated Primary/Secondary PCI manifest equality is now proven before
  runtime startup;
- rollback no longer leaves Primary on generated FT block graph;
- the failure is narrowed to the gap between generated XML/QEMU command-line
  equality and what QEMU/libvirt materializes for the incoming secondary before
  migration.

The next fix must therefore focus on why the secondary incoming domain keeps
PCI bridges/resources unassigned despite matching generated manifest, not on
another static manifest change.

## Run 117 - Materialization Pipeline Diagnostics Implementation

Date: 2026-06-16

### Design Target

Run 116 proved generated manifest equality and rollback restoration, but it did
not explain where the Secondary runtime lost PCI materialization. Run 117
therefore adds a pipeline diagnostic layer instead of repeating another broad
static manifest change.

The new diagnostic path is:

```text
generated manifest -> QEMU argv -> qtree -> info pci -> mtree
```

Expected evidence files for the next test:

- `materialization-pipeline-before_migrate.json`;
- `materialization-pipeline-diff-before_migrate.txt`;
- `materialization-pipeline-summary-before_migrate.txt`.

### Repetition Control

If the next test still fails with
`xcolo_secondary_pci_resource_unmaterialized_before_migrate`, it must be treated
as the same failure family only if the materialization layer also repeats.

The report must include:

- `xcolo_materialization_failure_layer`;
- `xcolo_materialization_first_missing_id`;
- `xcolo_materialization_first_missing_driver`;
- `xcolo_materialization_first_missing_path`;
- whether generated manifest, live argv, qtree, `info pci`, or mtree is the
  first failing layer.

If these fields repeat unchanged, the next change must target that exact layer.
Do not cycle back into generic PCI topology or COLO protocol explanations.

## Run 117 - Pre-Migrate PCI Materialization Is Deferred, Not Missing Intent

Date: 2026-06-16

### Result

Run 117 failed with the same top-level error:

```text
xcolo_secondary_pci_resource_unmaterialized_before_migrate
```

However, the new materialization pipeline evidence narrowed the actual layer:

- generated manifest: `ok`;
- live QEMU argv: `ok`;
- qtree: `ok`;
- materialization failure layer: `pci_missing`;
- first missing id: `scsi0-0-0-0`;
- first missing driver: `scsi-hd`;
- first missing path: `generated:True,argv:True,qtree:True,pci:False`;
- secondary mtree zero PCI alias count: `48`.

### Repetition Control

This is the same failure family but not the same diagnosis. We now know the
device intent exists through qtree and only PCI resource/mtree materialization
is incomplete before migration.

The next change must not alter generated topology again. It must move
PCI-resource-only checks from a pre-migrate hard gate to a pre-migrate deferred
warning, then enforce them as a post-migrate hard materialization gate.

## Run 118 - Deferred Pre-Migrate Materialization Implementation Target

Date: 2026-06-16

### Design Target

Pre-migrate must allow this exact condition to proceed:

```text
generated:True, argv:True, qtree:True, pci:False
```

The condition must be recorded as:

```text
xcolo_live_runtime_topology=deferred
xcolo_live_pci_identity=deferred
xcolo_pre_migrate_pci_materialization_deferred=yes
```

Post-migrate must not allow the same condition. If it remains, the expected
hard error is:

```text
xcolo_post_migrate_pci_materialization_failed
```

The next retest should therefore show whether the flow reaches
`primary.migrate` and then fails or succeeds at the post-migrate materialization
gate.

## Run 119 - Primary Reached COLO, Secondary Crashed During Incoming Materialization

Date: 2026-06-16

### Result

Run 119 confirmed that the Run 118 change moved the flow past the previous
pre-migrate blocker:

- `xcolo_guest_abi_manifest=ok`;
- `xcolo_generated_pci_manifest=ok`;
- `xcolo_materialization_phase=before_migrate`;
- `xcolo_materialization_failure_layer=pci_missing`;
- `xcolo_materialization_first_missing_id=scsi0-0-0-0`;
- `xcolo_materialization_first_missing_path=generated:True,argv:True,qtree:True,pci:False`;
- `xcolo_live_runtime_topology=deferred`;
- `xcolo_live_pci_identity=deferred`;
- `xcolo_pre_migrate_pci_materialization_deferred=yes`;
- `xcolo_pre_migrate_contract=ok`;
- `xcolo_pre_guest_traffic_gate=ready`.

The primary then reached COLO mode:

```text
virsh domstate i-2-54-VM: paused
query-migrate.status: colo
```

The secondary domain `i-2-183-VM` crashed on host `10.10.32.1`:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

The primary then logged:

```text
Can't receive COLO message: Input/output error
```

### Repetition Control

This is not a repeat of the Run 117 pre-migrate hard stop. The deferred gate
worked: the flow reached `primary.migrate`, entered COLO, and failed when the
secondary incoming runtime tried to materialize the migrated state.

The repeating symptom is the QEMU memory-region assertion. The next fix must
therefore focus on why the secondary incoming process still has a PCI/mtree
shape that causes QEMU to add a memory subregion twice or into an already owned
container during migration load.

Do not go back to static generated manifest edits unless evidence shows the
live command line or qtree diverged. In Run 119, generated manifest, live argv,
and qtree were already present; the remaining failure is in incoming migration
materialization.

## Run 120 - Fail Fast Before Unsafe Incoming Materialization

Date: 2026-06-16

### Design Target

Run 119 proved that the Run 118 defer rule is unsafe for the current QEMU 9.2.4
COLO path. The secondary incoming runtime crashed during migration state load:

```text
memory_region_add_subregion_common: Assertion `!subregion->container' failed.
```

The immediate correction is to prevent the crash loop. If the secondary
incoming runtime still shows:

```text
generated:True, argv:True, qtree:True, pci:False
```

or mtree zero-length PCI bridge aliases before `primary.migrate`, FTCTL must
fail before migration with:

```text
xcolo_pre_migrate_secondary_pci_resource_unmaterialized
```

### Repetition Control

The next test is expected to stop before `primary.migrate` if the same
secondary materialization condition exists. That is progress compared with Run
119 because it prevents the QEMU assertion and keeps both Cloud/libvirt state
recoverable.

If the next test still reaches `query-migrate.status=colo` and the secondary
crashes with `memory_region_add_subregion_common`, then this Run 120 guard did
not fire and the implementation must be treated as incomplete.

If the next test fails fast with
`xcolo_pre_migrate_secondary_pci_resource_unmaterialized`, the next development
step is not another guard. It must implement secondary incoming runtime
construction from the primary's actual launch ABI.
