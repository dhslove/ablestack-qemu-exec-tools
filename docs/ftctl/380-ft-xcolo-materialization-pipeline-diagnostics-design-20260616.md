# FT XCOLO Materialization Pipeline Diagnostics Design

Date: 2026-06-16

## Background

Run 116 changed the failure shape:

- generated guest ABI manifest: `ok`;
- generated PCI manifest: `ok`;
- rollback restored the Primary Cloud-managed graph successfully;
- live runtime still failed before `primary.migrate` with
  `xcolo_secondary_pci_resource_unmaterialized_before_migrate`.

This means the code no longer lacks a pre-runtime manifest gate. The remaining
gap is between the generated definition and the live QEMU/libvirt runtime that
actually exists immediately before migration.

## Principle

The next test must not repeat a generic "PCI topology mismatch" report. It must
show where each expected guest-visible device disappeared or failed to
materialize:

```text
generated manifest -> QEMU argv -> qtree -> info pci -> mtree
```

The existing no-hot-plug and no-runtime-mutation rules remain unchanged:

- do not dynamically alter the Primary or Secondary guest-visible device model
  after startup to make migration pass;
- keep FT/COLO graph construction as startup-time command-line generation;
- preserve `/dev/rbd/rbd/<image>` as the stable RBD path contract;
- keep the Run 116 rollback restoration check in place.

## Design

### Expanded Generated Device Manifest

The generated manifest must include all guest-visible `-device` entries that
can affect migration ABI and PCI materialization. The existing list covered the
main virtio and display devices, but missed device classes seen in the live
QEMU command line.

Add coverage for:

- `pcie-pci-bridge`;
- `qemu-xhci`;
- `i6300esb`;
- `ich9-intel-hda`;
- `hda-duplex`;
- `usb-tablet`;
- `isa-serial`;
- `virtserialport`;
- `ide-cd`.

If any of these differs between Primary and Secondary generated XML, the
generated manifest gate must fail before runtime startup.

### Materialization Pipeline Analyzer

Add a best-effort analyzer that runs after the live runtime snapshots are
captured and before the existing live topology result is reported.

Inputs:

- `primary-generated-pci-manifest-startup_disk_graph.json`;
- `secondary-generated-pci-manifest-startup_disk_graph.json`;
- `primary-live-qemu-argv-<phase>.txt`;
- `secondary-live-qemu-argv-<phase>.txt`;
- `primary-info-qtree-<phase>.txt`;
- `secondary-info-qtree-<phase>.txt`;
- `primary-info-pci-<phase>.txt`;
- `secondary-info-pci-<phase>.txt`;
- `primary-info-mtree-<phase>.txt`;
- `secondary-info-mtree-<phase>.txt`.

Output files:

- `materialization-pipeline-<phase>.json`;
- `materialization-pipeline-diff-<phase>.txt`;
- `materialization-pipeline-summary-<phase>.txt`.

State keys:

- `xcolo_materialization_pipeline`;
- `xcolo_materialization_phase`;
- `xcolo_materialization_context`;
- `xcolo_materialization_failure_layer`;
- `xcolo_materialization_missing_count`;
- `xcolo_materialization_first_missing_id`;
- `xcolo_materialization_first_missing_driver`;
- `xcolo_materialization_first_missing_path`;
- `xcolo_materialization_first_reason`.

Failure layers:

- `generated_missing`: generated Primary has a device absent from generated
  Secondary;
- `argv_missing`: generated device is absent from one live QEMU command line;
- `qtree_missing`: QEMU started without the expected device appearing in qtree;
- `pci_missing`: qtree/argv exist but `info pci` does not show the device;
- `pci_unassigned`: `info pci` shows the device but secondary PCI resources are
  unassigned or not mapped;
- `mtree_unmapped`: PCI identity exists but mtree still shows zero-length bridge
  aliases beyond the Primary baseline.

The analyzer must not overwrite the main `last_error`. It supplements the
existing error so repetition can be tracked precisely.

### Repetition Control

If `xcolo_secondary_pci_resource_unmaterialized_before_migrate` appears again,
the report must include:

- generated manifest result;
- materialization failure layer;
- first missing or unassigned id;
- first missing driver;
- path such as
  `generated:True,argv:True,qtree:True,pci:False`;
- the debug files listed above.

If the failure layer repeats unchanged across two consecutive runs, the next
change must target that exact layer. It must not introduce another broad
manifest or topology rewrite.

## Retest Expectation

The next run should end in one of these states:

1. Generated manifest now catches a previously missed guest-visible device
   mismatch before runtime startup.
2. Generated manifest still passes, and the materialization analyzer identifies
   whether `pci.6` or another bridge is missing at argv, qtree, PCI, or mtree.
3. Materialization passes and the flow proceeds beyond the previous pre-migrate
   blocker.

The desired near-term result is not necessarily a full FT pass. It is an
unambiguous answer to why the live Secondary runtime differs from the Primary
despite matching generated definitions.

## Run 117 Follow-Up: Deferred Pre-Migrate PCI Materialization

Run 117 produced the intended pipeline evidence. The result was:

```text
generated manifest: ok
live QEMU argv: ok
qtree: ok
materialization failure layer: pci_missing
first missing id: scsi0-0-0-0
first missing path: generated:True,argv:True,qtree:True,pci:False
```

This means the Secondary incoming runtime had the intended guest devices in the
generated definition, in the actual command line, and in qtree. The remaining
gap was PCI resource assignment and mtree mapping before `primary.migrate`.

That condition must no longer be treated as a pre-migrate hard failure. It is a
deferred materialization condition that must be rechecked after migration starts
the incoming side.

### Updated Gate Rule

Pre-migrate hard failures:

- generated manifest mismatch;
- live QEMU argv mismatch;
- missing qtree devices;
- missing QMP/domain snapshots;
- COLO socket/filter/channel readiness failures.

Pre-migrate deferred warnings:

- `pci_missing`;
- `pci_unassigned`;
- secondary bridge `secondary bus 0` / `subordinate bus 0`;
- secondary BAR `(not mapped)`;
- secondary mtree zero-length PCI bridge aliases.

Post-migrate hard failures:

- any remaining `pci_missing`;
- any remaining `pci_unassigned`;
- any remaining mtree zero-length PCI bridge aliases;
- any Primary/Secondary PCI identity divergence after incoming materialization.

The post-migrate hard error is:

```text
xcolo_post_migrate_pci_materialization_failed
```

### Implementation Notes

`ftctl_xcolo_verify_live_runtime_topology_pair()` must return success for a
pre-migrate PCI-resource-only difference when generated/argv/qtree checks have
already succeeded. It must set:

```text
xcolo_live_runtime_topology=deferred
xcolo_live_pci_identity=deferred
xcolo_pre_migrate_pci_materialization_deferred=yes
```

`ftctl_xcolo_require_pre_migrate_runtime_topology_gate()` must also treat
mtree/PCI-resource-only differences as `deferred` and allow orchestration to
continue to `primary.migrate`.

`ftctl_xcolo_require_post_migrate_materialization_gate()` must run the
materialization analyzer and reject any remaining PCI/mtree materialization
failure as a hard post-migrate error.

## Run 119 Correction: Pre-Migrate Defer Is Unsafe For QEMU 9.2.4

Run 119 disproved the assumption that `generated:True, argv:True, qtree:True,
pci:False` can safely be deferred until after `primary.migrate`.

The flow did proceed past the previous blocker, but the secondary incoming QEMU
crashed while loading the migration state:

```text
memory_region_add_subregion_common: Assertion `!subregion->container' failed
```

The primary-side `Can't receive COLO message: Input/output error` was only a
consequence of the secondary crash.

### Superseded Rule

The following pre-migrate rule is superseded:

```text
generated:True, argv:True, qtree:True, pci:False -> defer
```

For QEMU 9.2.4 in this FTCTL path, that condition means the secondary incoming
runtime is not yet migration-ABI materialized enough to accept the primary
state safely.

### New Gate Rule

Pre-migrate hard failures now include:

- `pci_missing`;
- `pci_unassigned`;
- secondary bridge `secondary bus 0` / `subordinate bus 0`;
- secondary BAR `(not mapped)`;
- secondary mtree zero-length PCI bridge aliases.

The pre-migrate hard error is:

```text
xcolo_pre_migrate_secondary_pci_resource_unmaterialized
```

### Implementation Target

The immediate implementation must prevent another QEMU assertion loop by
failing before `primary.migrate` when the secondary incoming runtime shows this
condition. The state must preserve enough evidence to continue the real fix:

- `xcolo_materialization_failure_layer`;
- `xcolo_materialization_first_missing_path`;
- `xcolo_pre_migrate_pci_materialization_failure_layer`;
- `xcolo_pre_migrate_pci_materialization_failure_path`;
- `xcolo_protocol_failure_phase=pre_migrate_materialization`.

The longer-term fix remains to build the secondary incoming runtime from the
primary's actual launch ABI so that the target reaches a migration-compatible
PCI/mtree state before migration is attempted.
