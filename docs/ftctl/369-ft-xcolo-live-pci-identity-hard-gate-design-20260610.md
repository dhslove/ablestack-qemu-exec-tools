# 369. FT X-COLO Live PCI Identity Hard Gate Design

Date: 2026-06-10

## Trigger

Run 105 proved that the pre-migrate commandline and block graph contracts were
not enough:

- both disk baseline seeds completed;
- primary and secondary generated runtimes started;
- the guest `-device` ABI hash matched;
- COLO role objects and chardevs were present;
- primary and secondary block graphs were ready;
- `primary.migrate` was accepted;
- secondary QEMU still crashed while applying incoming migration state:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

The remaining pre-migrate evidence showed that `info pci` identity was already
different before migration:

```text
warning=xcolo_live_pci_identity_diff_observed
pci_first_diff_index=3
```

## Design Principle

For X-COLO, matching guest `-device` commandline entries is necessary but not
sufficient. QEMU incoming migration applies live device and memory topology
state. Therefore the secondary must match the primary's live PCI identity before
`primary.migrate`.

The live PCI identity contract is based on `info pci`, normalized to stable
identity fields:

- bus / device / function;
- PCI class;
- QEMU id;
- subsystem identity when present.

Runtime resource allocation details such as BAR and IRQ lines can still differ
and remain diagnostic-only. PCI identity differences are migration ABI
differences and must be hard failures.

## Implementation Direction

`ftctl_xcolo_verify_live_runtime_topology_pair()` now treats these conditions as
hard failures:

```text
xcolo_live_pci_snapshot_missing
xcolo_live_pci_identity_missing
xcolo_live_pci_identity_mismatch
```

On failure it records:

```text
xcolo_live_runtime_topology=failed
xcolo_live_pci_identity=failed
xcolo_live_pci_identity_first_diff_index=<index>
xcolo_live_pci_identity_primary=<normalized primary record>
xcolo_live_pci_identity_secondary=<normalized secondary record>
xcolo_protocol_failure_phase=pre_migrate_live_topology
last_error=<exact error>
```

It also preserves the same evidence files:

```text
live-topology-diff-before_migrate.txt
primary-info-pci-before_migrate.txt
secondary-info-pci-before_migrate.txt
primary-info-qtree-before_migrate.txt
secondary-info-qtree-before_migrate.txt
primary-info-mtree-before_migrate.txt
secondary-info-mtree-before_migrate.txt
```

## Expected Test Effect

If the Run 105 PCI identity mismatch repeats, the next run must fail before
`primary.migrate` with `xcolo_live_pci_identity_mismatch`. That is progress:
QEMU secondary crash is replaced by deterministic pre-migrate diagnosis.

If the PCI identity contract passes and the same QEMU assertion still appears,
the next design must inspect deeper QEMU migration ABI differences outside PCI
identity, using the preserved qtree and mtree evidence.
