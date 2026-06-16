# FT XCOLO Canonical PCI Manifest And Rollback Design

Date: 2026-06-16

## Background

Run 115 proved that the Run 114 crash-prevention gate is working: FTCTL did
not issue `primary.migrate` when the secondary incoming VM still had
unmaterialized PCI resources. The run failed before migration with:

```text
xcolo_secondary_pci_resource_unmaterialized_before_migrate
```

The evidence also showed the remaining root problem:

- primary PCI identity count: `18`;
- secondary PCI identity count: `12`;
- first identity difference: primary `pci.6 bus=1 device=0`, secondary
  `pci.2 bus=0 device=2 function=1`;
- primary still had generated XCOLO block nodes after rollback, including
  `ftctl-colo-*`, `ftctl-primary-active-*`, and `quorum`.

Therefore the previous fix must be treated as a safety stop, not as the final
topology solution.

## Principle

FTCTL must prove Primary and Secondary migration ABI equality before it starts
the generated runtimes and before it can ever reach `primary.migrate`.

The core rule is:

```text
Primary generated manifest == Secondary generated manifest
```

The manifest is not a cosmetic XML diff. It is a canonical migration ABI
manifest containing the guest-visible PCI fabric and QEMU `-device` topology
that QEMU migration depends on.

The no-hot-plug rule remains unchanged:

- FTCTL must not dynamically mutate an already running Primary or Secondary to
  make COLO pass;
- FT-specific disk graph, network filters, chardevs, and incoming migration
  wiring are startup-time command-line concerns;
- the Primary and Secondary generated startup definitions must be shaped from
  the same canonical manifest;
- `/dev/rbd/rbd/<image>` remains the stable RBD path policy. FTCTL must not use
  `/dev/rbdN` as the durable XML or QEMU command-line contract.

## Design

### Generated PCI Manifest Gate

Add a generated-manifest gate after generated XML/QEMU command-line assembly
and before runtime creation.

The gate must compare a canonical manifest from both generated XMLs:

- domain type and machine type;
- CPU, memory/currentMemory, vCPU, and feature surface;
- PCI controller fabric:
  - controller type/model/index;
  - alias;
  - model attributes;
  - PCI address bus/slot/function/domain;
  - chassis/port/target if present;
- SCSI controller fabric:
  - model/index/alias/address;
  - queue count if present;
- guest NIC identity:
  - MAC, model, alias, PCI address;
- guest-visible QEMU `-device` entries:
  - `pcie-root-port`;
  - `pci-bridge`;
  - `virtio-scsi-pci`;
  - `scsi-hd`;
  - `virtio-blk-pci`;
  - `virtio-net-pci`;
  - `virtio-serial-pci`;
  - `virtio-balloon-pci`;
  - `virtio-rng-pci`;
  - `qxl`, `virtio-vga`, `VGA`, `cirrus-vga`.

The manifest must intentionally exclude host-local or role-local values:

- VM name and transient runtime id;
- security labels and resource paths;
- VNC/listen/console/channel host endpoints;
- host file paths, sockets, PIDs, and network ports;
- COLO role-specific non-guest objects and chardevs.

If the manifest differs, FTCTL must fail before creating the runtime:

```text
xcolo_generated_pci_manifest_mismatch
```

The failure evidence must include:

- primary and secondary manifest hashes;
- role item counts;
- first diff path;
- debug files containing the normalized primary/secondary manifests and diff.

### Live Runtime Gate

The existing live runtime gate remains active. Its role is now different:

- generated manifest gate proves what FTCTL intended to start;
- live runtime gate proves what QEMU actually materialized after libvirt/QEMU
  startup.

If generated manifest equality passes but live topology still differs, the
next fix must focus on libvirt/QEMU materialization, not on startup manifest
construction.

### Rollback Restoration Gate

Rollback must not report success merely because the Primary domain is running.
It must verify that the Primary has returned to the Cloud-managed runtime graph.

After a failed startup gate:

1. Destroy the secondary generated runtime if present.
2. Unmap secondary runtime RBD mappings.
3. Destroy the generated primary runtime if it is still active.
4. Recreate the primary from `primary_xml_backup`.
5. Verify the restored primary QMP block nodes no longer contain generated
   FTCTL graph markers:
   - `ftctl-colo-`;
   - `ftctl-primary-active-`;
   - `ftctl-primary-parent-`;
   - `quorum` nodes belonging to the FT graph.

If the generated graph is still present, rollback must report:

```text
xcolo_primary_restore_generated_graph_present
```

This is a cleanup blocker and must not be hidden behind a generic
`primary_restore_failed` message.

## Retest Expectation

The next retest must produce one of these outcomes:

1. Generated PCI manifest mismatch is caught before runtime startup. This is
   progress because the mismatch is now deterministic and pre-runtime.
2. Generated manifest equality passes, runtime creation succeeds, and the live
   runtime gate catches a QEMU materialization difference. This narrows the
   issue to libvirt/QEMU materialization.
3. Generated and live manifests both match, and the flow proceeds beyond the
   previous pre-migrate blocker.

Repeated `xcolo_secondary_pci_resource_unmaterialized_before_migrate` without
generated manifest evidence is not acceptable after this change. If that error
appears again, the report must include whether the generated manifest gate
passed and exactly what differed after QEMU materialization.

## Run 116 Follow-Up

Run 116 proved that this generated manifest gate and rollback restoration gate
work, but also proved that generated equality is not sufficient by itself.

The generated Primary and Secondary manifests matched, yet the live secondary
incoming runtime still materialized fewer PCI identities than the Primary before
`primary.migrate`. Therefore the next design layer is not another static
manifest-only comparison. It must trace the full materialization pipeline:

```text
generated manifest -> QEMU argv -> qtree -> info pci -> mtree
```

The follow-up design is recorded in
`380-ft-xcolo-materialization-pipeline-diagnostics-design-20260616.md`.
