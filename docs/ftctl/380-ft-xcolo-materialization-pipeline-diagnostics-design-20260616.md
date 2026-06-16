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
