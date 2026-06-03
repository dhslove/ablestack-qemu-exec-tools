# FT XCOLO Storage Compatibility Gate Design - 2026-06-02

## Background

Run 63 proved that the FT XCOLO external network path is available:

- firewall service/ports were present on both primary and secondary hosts
- 9003/9004 data sockets were established
- 9001/9005 loopback compare sockets were present
- 10809 NBD was connected
- 9998 migration endpoint was listening on the secondary

Despite that, the same QEMU protocol failure repeated:

- primary: `Received invalid message 0x0000 length 0x0000`
- secondary: `Can't receive COLO message: Input/output error`

The remaining high-value difference is storage layout:

- primary disks: `block/raw`
- secondary disks: `file/qcow2`

For FT, the secondary is not a loose backup target. It must act as a runtime
clone with equivalent device semantics. Therefore the default FT XCOLO path must
require storage backend/format compatibility.

## Principle

FT XCOLO protection must select target storage that is compatible with the
primary disk backend and format.

Default allowed examples:

- `block/raw -> block/raw`
- `file/qcow2 -> file/qcow2`

Default blocked examples:

- `block/raw -> file/qcow2`
- `file/qcow2 -> block/raw`
- mixed multi-disk layouts where any disk differs

This is stricter than DR or HA block copy. DR/HA can tolerate backend conversion
because they primarily copy blocks and manage lifecycle transitions. FT XCOLO
depends on QEMU runtime replication and checkpoint protocol behavior, so the
runtime disk graph must be treated as a compatibility contract.

## Behavior

During FT cloud-managed protection:

1. Cloud may create the standby VM and pass an explicit disk map.
2. qemu FTCTL collects the primary disk plan.
3. qemu FTCTL records:
   - `xcolo_storage_primary_layouts`
   - `xcolo_storage_secondary_layouts`
   - `xcolo_storage_symmetry`
   - `xcolo_storage_symmetry_reason`
4. If `xcolo_storage_symmetry=warning`, qemu FTCTL stops before primary shutdown.
5. The state records:
   - `xcolo_storage_compatibility=blocked`
   - `xcolo_storage_mismatch_override=false`
   - `conversion_stage=storage_compatibility_failed`
   - `conversion_state=error`
   - `last_error=xcolo_storage_backend_mismatch`

## Experimental Override

An explicit override can be used only for investigation:

- `FTCTL_XCOLO_ALLOW_STORAGE_MISMATCH=1`

When enabled:

- qemu FTCTL records `xcolo_storage_compatibility=experimental`
- qemu FTCTL records `xcolo_storage_mismatch_override=true`
- the run is not considered a default FT compatibility pass

## Repeated Invalid Message Classification

Run 63 also showed that failure-time strict chardev state can become `no` after
QEMU has already failed migration. The repeated-message classifier must use
pre-migrate evidence instead.

Classify as `xcolo_repeated_protocol_invalid_message` when:

- primary migrate error contains `Received invalid message 0x0000 length 0x0000`
- `xcolo_premigrate_primary_filter_chardev_ready=yes`
- pre-migrate filter QOM or command-line evidence was ready
- pre-migrate channel evidence was ready
- secondary block graph was ready
- firewall was ready or not explicitly failed
- runtime socket evidence was captured or not required by the current path

This keeps the investigation from cycling through already-cleared filter,
firewall, and socket hypotheses.

## Next Test Expectation

For the current `r97-link-01` setup, selecting local filesystem/qcow2 secondary
storage should fail early with `xcolo_storage_backend_mismatch` before the
primary VM is shut down.

To continue FT XCOLO runtime validation, the next target storage must match the
primary layout, for example `block/raw -> block/raw`.

## Cloud-Managed RBD Metadata Inference

Run 64 selected compatible `block/raw -> block/raw` storage, but generated XML
preparation failed before primary shutdown:

- `xcolo_storage_symmetry=ok`
- `last_error=xcolo_block_generated_xml_prepare_failed`

The failure was caused by a wrong metadata probe assumption. For cloud-managed
standby VMs, the secondary RBD volume can be allocated in Cloud while the
secondary host still has no `/dev/rbd/...` KRBD mapping. The mapping may be
created only when libvirt starts or attaches the transient standby runtime.

Therefore qemu FTCTL must not require this to succeed during generated XML
preparation:

```text
qemu-img info --force-share /dev/rbd/rbd/<secondary-volume-path>
```

When all of the following are true, qemu FTCTL must infer disk metadata from
the Cloud-managed plan instead of probing the secondary host path:

- `FTCTL_PROFILE_PROVISIONING_BACKEND=cloud-managed`
- the selected storage is compatible and recorded as `block/raw`
- the disk map destination is a `/dev/rbd/...` path

The inferred metadata is:

```text
<target>=<rbd-path>|raw|dev|block
```

This keeps generated XML preparation aligned with the Cloud-managed lifecycle:
Cloud owns VM and volume creation, while qemu FTCTL prepares and runs the FT
runtime without assuming pre-existing host-side KRBD mappings.

## Generated XML Diagnostics

`xcolo_block_generated_xml_prepare_failed` is too broad for repeated FT test
iterations. The generated XML preparation function must record the failed
sub-step in state and events before returning.

Required sub-step errors include:

- `xcolo_primary_disk_rewrite_failed`
- `xcolo_standby_disk_metadata_failed`
- `xcolo_standby_disk_rewrite_failed`
- `xcolo_primary_network_xml_failed`
- `xcolo_standby_network_xml_failed`
- `xcolo_standby_host_xml_failed`
- `xcolo_primary_iothread_xml_failed`
- `xcolo_primary_qemu_commandline_xml_failed`
- `xcolo_standby_qemu_commandline_xml_failed`
- `xcolo_primary_disk_targets_xml_failed`
- `xcolo_standby_disk_targets_xml_failed`
- `xcolo_primary_iothread_contract_failed`

After standby disk rewrite, qemu FTCTL should verify that every target in
`FTCTL_PROFILE_DISK_MAP` appears in the generated standby XML as the final disk
source. If this check fails, record:

- `last_error=xcolo_standby_disk_source_mismatch`

The next expected Run 65 result is that cloud-managed compatible RBD storage
passes generated XML preparation even when secondary `/dev/rbd/...` paths are
not mapped before the transient standby runtime starts.

## Cloud-Managed RBD Baseline Seed Mapping

Run 65 confirmed that generated XML preparation passed, but baseline seed copy
failed at `sda`:

- `last_error=xcolo_baseline_seed_failed:sda`
- `block_conversion.baseline_seed.nbd_start` succeeded
- `block_conversion.baseline_seed.copy.final_fail` failed with `rc=95`

The secondary RBD image existed in the pool, but the secondary host still had no
host-side KRBD path:

```text
/dev/rbd/rbd/<secondary-image>
```

Cloud creates and owns the volume lifecycle, but qemu FTCTL performs the
baseline seed copy before libvirt starts the transient standby runtime. At that
moment libvirt has not mapped the secondary RBD device yet.

Therefore, during baseline seed copy only, qemu FTCTL must prepare a temporary
host-side KRBD mapping for cloud-managed RBD targets.

Required behavior:

1. Detect cloud-managed RBD seed targets:
   - `FTCTL_PROFILE_PROVISIONING_BACKEND=cloud-managed`
   - secondary destination matches `/dev/rbd/<pool>/<image>`
   - target layout is `block/raw`
2. On the secondary host, before `qemu-img convert`, run:
   - `rbd map <pool>/<image>`
3. Resolve the actual mapped block device:
   - prefer the expected `/dev/rbd/<pool>/<image>`
   - otherwise inspect `rbd device list` for the mapped image
4. Use the resolved block device only as the seed-copy destination.
5. Preserve the original `/dev/rbd/<pool>/<image>` in generated XML and runtime
   state, because libvirt should still open the Cloud-managed volume normally.
6. Always unmap the temporary device after copy success or failure.

Failure reporting must be specific:

- `xcolo_baseline_seed_rbd_map_failed:<target>`
- `xcolo_baseline_seed_rbd_device_missing:<target>`
- `xcolo_baseline_seed_copy_failed:<target>`
- `xcolo_baseline_seed_rbd_unmap_failed:<target>`

Remote stdout/stderr must be captured into the event details in bounded form so
the next failure does not appear as `error=""`.

The next expected Run 66 result is that baseline seed passes both `sda` and
`sdb`, then proceeds to standby/primary generated runtime creation.
