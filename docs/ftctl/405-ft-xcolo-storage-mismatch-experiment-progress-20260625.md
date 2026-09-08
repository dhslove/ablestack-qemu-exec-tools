# FT XCOLO Storage Mismatch Experiment Progress - 2026-06-25

This document records the experimental `raw` to `qcow2` FT validation run for
`r97-link-02`. The goal is to avoid repeating the same failure loop and to keep
the exact reached stage visible before making more code changes.

## Experiment Scope

- Target VM: `r97-link-02`
- Primary VM id/name: `197` / `i-2-197-VM`
- Standby VM id/name: `198` / `i-2-198-VM`
- Primary host: `10.10.32.3`
- Secondary host: `10.10.32.1`
- Primary storage layout: `block/raw` on RBD
- Secondary storage layout: `file/qcow2` on host local storage
- Temporary host override:
  `FTCTL_XCOLO_ALLOW_STORAGE_MISMATCH="1"`

## Progress Scale

1. Cloud registration accepted.
2. Standby VM and volumes created.
3. Storage mismatch experimental gate accepted.
4. Baseline disk seed completed.
5. Primary and secondary generated manifests matched.
6. Secondary incoming runtime started.
7. Primary generated runtime started.
8. COLO peer channels connected.
9. Primary migrate issued.
10. Primary and secondary enter COLO.
11. Stable FT mirroring observed.

## Runs

### Run 2026-06-25-01

- Result: failed
- Last reached stage: 6
- Repetition status: not_repeat
- Evidence:
  - Cloud DB protection row `128` reached `protection_state=error`,
    `transport_state=failed`, `active_side=primary`.
  - Standby VM `i-2-198-VM` was created on local storage and remained in
    libvirt on `10.10.32.1` as `paused`.
  - Primary VM `i-2-197-VM` was no longer present in libvirt on
    `10.10.32.3` after rollback, while Cloud DB still showed it as `Running`.
  - Primary volumes were `RAW` on RBD; standby volumes were `QCOW2` on local
    storage.
  - `xcolo_storage_symmetry=warning`,
    `xcolo_storage_compatibility=experimental`, and
    `xcolo_storage_mismatch_override=true`.
  - Baseline seed completed for both disks:
    `xcolo_disk_sda_baseline_seeded=true` and
    `xcolo_disk_sdb_baseline_seeded=true`.
  - Generated ABI and PCI manifests matched:
    `xcolo_guest_abi_manifest=ok` and `xcolo_generated_pci_manifest=ok`.
  - Secondary generated QEMU runtime started with `-incoming defer`.
- Failure signature:
  - `last_error=xcolo_block_primary_create_failed:primary_restore_failed`
  - `primary.create_generated` failed before migrate.
  - QEMU stderr:
    `-chardev socket,id=compare1,host=0.0.0.0,port=9004,server=on,wait=on:
    Failed to find an available port: Address already in use`
  - Post-failure inventory repeatedly reported
    `primary_domain_state=not-found` and `standby_domain_state=paused`.
- Interpretation:
  - This run did not reach the actual `raw` to `qcow2` COLO protocol test.
  - The storage mismatch gate and baseline conversion path progressed further
    than the previous strict same-storage gate.
  - The active failure is a COLO socket lifecycle and rollback problem:
    secondary-side connections to primary ports were left alive while the
    generated primary was being created, and failed rollback did not restore
    the original primary runtime.
- Next improvement:
  - Make generated-primary port ownership deterministic before create:
    verify no stale `9003/9004/9001/9005/9998/10809` listeners or peer
    connections for the target VM remain.
  - If the primary create path fails, destroy the generated secondary runtime
    before attempting primary restore.
  - Treat `primary_restore_failed` as a hard cleanup defect, not as an FT
    protocol result.
  - Keep the storage mismatch override temporary and remove it after the
    experiment unless another explicit run is requested.

### Cleanup And Retest Preparation 2026-06-25-01

- Protection release:
  - Cloud forced release was issued for VM UUID
    `2885c59e-bfbc-430e-9fc2-5bbd384a41a0`.
  - Protection row `128` is now `disabled/stopped/inactive` and has
    `removed=2026-06-25 05:45:19`.
  - Host-side forced unprotect returned `result=ok` on both
    `10.10.32.3` and `10.10.32.1`.
- Cleanup result:
  - Stale standby runtime `i-2-198-VM` was destroyed on `10.10.32.1`.
  - Standby VM row `198` is `Expunging/removed`; standby volumes `381` and
    `382` are `Expunged/removed`.
  - Primary VM `197` has zero active `ftctl.*` details.
  - Cloud DB and libvirt runtime were resynchronized by Cloud API
    stop/start of `r97-link-02`; `i-2-197-VM` is now running on
    `10.10.32.3` and QGA `guest-ping` succeeds.
- Port-conflict finding:
  - Existing protected VM `r97-link-01` owns the default COLO/NBD ports:
    primary `10.10.32.3` listens on `9001`, `9003`, `9004`, `9005`; secondary
    `10.10.32.1` listens on `10809`.
  - The previous run therefore did not validate raw-to-qcow2 compatibility.
    It failed before that point due to default port reuse.
- Temporary retest port range:
  - Added an experiment block to `/etc/ablestack/ablestack-vm-ftctl.conf` on
    `10.10.32.1`, `10.10.32.2`, and `10.10.32.3`.
  - Backup path on each host:
    `/root/ablestack-vm-ftctl.conf.pre-r97-link-02-port-experiment-20260625-144925`.
  - Effective override values:
    `FTCTL_XCOLO_MIRROR_PORT=9103`,
    `FTCTL_XCOLO_COMPARE_PORT=9104`,
    `FTCTL_XCOLO_COMPARE_LOCAL_PORT=9101`,
    `FTCTL_XCOLO_COMPARE_OUT_PORT=9105`,
    `FTCTL_XCOLO_CTRL_PORT=9198`,
    `FTCTL_REMOTE_NBD_PORT_BASE=11809`,
    `FTCTL_REMOTE_NBD_PORT_COUNT=64`.
  - Firewalld was opened on all three hosts for `9100-9105/tcp`,
    `9198/tcp`, and `11809-11872/tcp`.
  - Verification found no active sockets on `910x`, `9198`, or `11809`
    before the next retest.

### Run 2026-06-25-02

- Result: invalid / cleaned up
- Last reached stage: 8
- Repetition status: not_repeat
- Invalid reason:
  - The retest was started with a mixed endpoint set.
  - Correctly changed values:
    `ftctl.xcolo.migrate.uri=tcp:10.10.32.1:9198` and
    `ftctl.xcolo.proxy.endpoint=tcp:10.10.32.1:9100`.
  - Incorrectly unchanged values:
    `ftctl.remote.nbd.export.addr=10.10.32.1:10809` and
    `ftctl.xcolo.nbd.endpoint=tcp:10.10.32.1:10809`.
  - Port `10809` was already owned by the existing `r97-link-01` standby QEMU
    process on `10.10.32.1`.
- Evidence:
  - New protection row `129` was created for primary VM `197` and standby VM
    `199`.
  - Standby volumes `383` and `384` were created on local storage.
  - Baseline seed completed for both disks and generated primary/secondary
    command contracts reached `ok`.
  - Temporary COLO ports `9101`, `9103`, `9104`, and `9105` were observed in
    transient states, so the host config override was active.
  - The run failed with `last_error=xcolo_block_handshake_failed`.
- Cleanup result:
  - Host-side forced unprotect returned `result=ok` on both `10.10.32.3` and
    `10.10.32.1`.
  - Stale standby runtime `i-2-199-VM` was destroyed on `10.10.32.1`.
  - Cloud forced release completed for row `129`; it is now
    `disabled/stopped/inactive` with `removed=2026-06-25 06:02:49`.
  - Standby VM `199` is `Expunging`; volumes `383` and `384` are
    `Expunged/removed`.
  - Primary VM `197` remains `Running` on `10.10.32.3`, QGA `guest-ping`
    succeeds, and active primary `ftctl.*` details are `0`.
- Required next retest input:
  - `remote NBD export addr`: `10.10.32.1:11809`
  - `XCOLO NBD endpoint`: `tcp:10.10.32.1:11809`
  - `XCOLO migrate URI`: `tcp:10.10.32.1:9198`
  - `XCOLO proxy endpoint`: `tcp:10.10.32.1:9100`

### Run 2026-06-25-03

- Result: failed
- Last reached stage: 10
- Repetition status: not_repeat
- Endpoint input:
  - `ftctl.xcolo.nbd.endpoint=tcp:10.10.32.1:11809`
  - `ftctl.xcolo.migrate.uri=tcp:10.10.32.1:9198`
  - `ftctl.xcolo.proxy.endpoint=tcp:10.10.32.1:9100`
  - `ftctl.remote.nbd.export.addr` still showed `10.10.32.1:10809` in Cloud
    details.
  - The UI did not expose an editable `remote.nbd.export.addr` field, so the
    operator could not correct this value during registration.
- Evidence of progress:
  - Protection row `130` was created for primary VM `197` and standby VM
    `200`.
  - Standby volumes `385` and `386` were created on local storage.
  - Baseline seed completed for both disks.
  - Generated primary and secondary command contracts reached `ok`.
  - Temporary network ports were actually used:
    primary `9101`, `9103`, `9104`, `9105`; migration `9198`.
  - Both COLO network channels were established:
    `10.10.32.3:9103 <-> 10.10.32.1:*` and
    `10.10.32.3:9104 <-> 10.10.32.1:*`.
  - Final secondary QEMU runtime still listened on
    `10.10.32.1:10809`, proving the remote NBD export port did not follow the
    intended `11809` XCOLO endpoint.
  - `primary.migrate` returned `ok`.
  - QMP showed `query-migrate.status=colo` on both primary and secondary.
  - Events confirmed role transition:
    `primary_colo=primary`, `secondary_colo=secondary`, `invalid_message=no`.
  - `block_conversion.handshake` returned `ok` with
    `state=commands_accepted`.
- Final blocking point:
  - `block_conversion.steady_state_gate` emitted `result=start` but no
    completion event was observed before failure.
  - Cloud row `130` ended at `protection_state=error`,
    `transport_state=failed`, `active_side=primary`,
    `last_error=xcolo_runtime_validation_failed:runtime_converging`.
  - Primary VM `i-2-197-VM` was restored to `running` and no longer reported
    COLO migration state.
  - Secondary VM `i-2-200-VM` remained `Running` in Cloud DB but its QEMU
    runtime was paused/incoming and still had the stale `10809` NBD listener.
- Interpretation:
  - This is progress beyond the previous port-conflict run.
  - The repeating `invalid COLO message` signature was not observed in the
    current run window.
  - The active issue is now a combination of FTCTL steady-state completion
    after QEMU reports COLO migration status and inconsistent NBD endpoint
    propagation.
  - The lingering `ftctl.remote.nbd.export.addr=10.10.32.1:10809` Cloud detail
    is not only cosmetic: final secondary QEMU still used `10809`.
  - This was not an operator input mistake because the UI had no field for
    changing `remote.nbd.export.addr`.
- Next improvement:
  - Reconcile Cloud UI/backend detail persistence so remote NBD export address
    and XCOLO NBD endpoint always agree; either derive
    `remote.nbd.export.addr` from `ftctl.xcolo.nbd.endpoint` or expose it as a
    validated editable field.
  - Add a backend preflight that rejects registration when
    `remote.nbd.export.addr` and `ftctl.xcolo.nbd.endpoint` disagree.
  - Inspect and revise `block_conversion.steady_state_gate` so it recognizes
    the QEMU 9.2.4 COLO state where `query-migrate=colo`, replication block
    jobs are empty, and replication nodes are present with clean backing
    chains.
  - Add a bounded timeout with explicit diagnostics for the steady-state gate
    instead of leaving the registration job in `pairing/planned` indefinitely.

### Cleanup And Retest Preparation 2026-06-25-03

- Cloud forced release:
  - `releaseFtctlProtection` was called for VM UUID
    `2885c59e-bfbc-430e-9fc2-5bbd384a41a0` with `force=true`.
  - Async job `91a38a09-dc72-4314-8062-a3eb40447f67` completed with
    `jobstatus=1`, `jobresultcode=0`.
  - Host-side output reported
    `remote_nbd_required=true` and `remote_nbd_released=true`.
- Final Cloud state:
  - Active `r97-link-02` protection rows: `0`.
  - Primary VM `197` remains `Running` on host `3`.
  - Primary VM `197` active `ftctl.*` details: `0`.
  - Standby VM `200` is `Expunging` with `removed=2026-06-25 06:33:17`.
  - Standby volumes `385` and `386` are `Expunged` with the same removal
    timestamp.
- Final host state:
  - No `i-2-200-VM` libvirt domain or QEMU process remained on
    `10.10.32.1`, `10.10.32.2`, or `10.10.32.3`.
  - `r97-link-02` host runtime directories under
    `/run/ablestack-vm-ftctl`, `/etc/ablestack/ftctl.d`, and
    `/var/lib/ablestack-vm-ftctl/blockcopy/i-2-197-VM` were cleared.
  - The `10.10.32.1:10809` listener observed after cleanup belongs to the
    active `r97-link-01` secondary `i-2-196-VM`, not to `r97-link-02`.
- Primary health:
  - `i-2-197-VM` is `running`.
  - `query-block-jobs` is empty.
  - `query-migrate` is empty.
  - QGA `guest-ping` succeeds.
- Retest caution:
  - The environment is clean for `r97-link-02`, but the product defect remains:
    the UI still cannot set `remote.nbd.export.addr`.
  - A UI-only retest can recreate the stale `10809` NBD export value unless
    Cloud UI/backend is fixed or the registration path is otherwise given a
    matching remote NBD export address.
