# FT XCOLO Pre-Migrate PCI Materialization Hard Gate Design - 2026-06-18

## Background

The current FT cold-conversion path does not synchronize the primary and
secondary while the original cloud-managed VM keeps running. FTCTL stops the
primary, seeds the secondary baseline disks, creates primary and secondary COLO
runtime XMLs, starts both generated QEMU processes, starts secondary incoming
with QMP, and only then runs primary `migrate`.

Disk baseline synchronization happens before the generated QEMU pair is started.
Memory, device, and COLO runtime state synchronization happens when primary
`migrate` is executed. That migration step requires the secondary QEMU runtime
to already be migration-ABI compatible with the primary.

## Failure Observed

Run 124 preserved evidence for the repeated crash path:

```text
xcolo_materialization_failure_layer=pci_missing
xcolo_materialization_first_missing_id=scsi0-0-0-0
xcolo_materialization_first_missing_path=generated:True,argv:True,qtree:True,pci:False
last_error=xcolo_secondary_qemu_assert_memory_region_container
```

The generated XML and command line described the expected devices, and qtree
showed the device objects. However, `info pci` did not show the corresponding
materialized PCI resource state. Treating that condition as deferred allowed
`primary.migrate` to enter the QEMU crash path.

## Design Decision

`generated=True,argv=True,qtree=True,pci=False` is not a safe defer condition
for a real PCI endpoint, bridge, or controller in the QEMU 9.2.4 FTCTL
cold-conversion path.

For that device class it is a hard pre-migrate failure:

```text
xcolo_pre_migrate_secondary_pci_resource_unmaterialized
```

This change does not claim that primary and secondary live topology equality is
solved. It prevents unsafe migration when equality has not been reached.

## Runtime Contract

Before `primary.migrate`, all of the following must pass:

1. generated primary/secondary manifest equality;
2. command-line device presence for both QEMU processes;
3. qtree device presence for both QEMU processes;
4. PCI resource materialization for the secondary for PCI endpoints, bridges,
   and controllers;
5. mtree PCI bridge/resource materialization for the secondary;
6. COLO channel and firewall readiness;
7. secondary `migrate-incoming` readiness.

If any PCI/mtree materialization gate fails, FTCTL must not run
`primary.migrate`.

Bus child devices such as `scsi-hd` are not direct PCI endpoints. They are
covered by [403. FT XCOLO Bus Child Materialization Classification Design](403-ft-xcolo-bus-child-materialization-classification-design-20260619.md):
they must exist in `qtree` with their parent controller, but they must not be
required to appear directly in `info pci`.

## Implementation Plan

- Remove the `before_migrate` branch that records
  `xcolo_live_runtime_topology=deferred` for PCI/mtree materialization gaps.
- Make `ftctl_xcolo_require_secondary_startup_materialization_gate()` fail for
  `pci_missing`, `pci_unassigned`, and `mtree_unmapped`.
- Treat any legacy `xcolo_pre_migrate_topology_gate_state=deferred` as failure.
- Record:

```text
xcolo_live_runtime_topology=failed
xcolo_live_pci_identity=failed
xcolo_pre_migrate_pci_materialization_deferred=no
xcolo_protocol_failure_phase=pre_migrate_materialization
last_error=xcolo_pre_migrate_secondary_pci_resource_unmaterialized
```

- Keep post-migrate crash detection as a safety net, not as the expected
  control path.

## Retest Expectation

The next retest should stop before `primary.migrate` if the same runtime shape
appears again. A QEMU assertion or `Can't receive COLO message` after
`primary.migrate` would be a regression of this guard.

The desired next failure, if topology is still not solved, is:

```text
conversion_stage=pre_migrate_live_topology_failed
last_error=xcolo_pre_migrate_secondary_pci_resource_unmaterialized
```

The desired success path is:

```text
xcolo_secondary_startup_materialization=ok
xcolo_pre_migrate_topology_gate_state=ok
xcolo_live_runtime_topology=ok
primary.migrate=ok
```
