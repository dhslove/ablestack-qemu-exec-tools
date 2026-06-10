# FT XCOLO Pre-Migrate Runtime Topology Gate Design

Date: 2026-06-10

## Background

Run 108 showed that the post-migrate analyzer from design 371 works, but it
observes the secondary too late. The secondary QEMU process had already crashed
with:

```text
memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

The captured state proved two things:

- `primary.migrate` was reached and QEMU entered COLO migration.
- the post-crash secondary `qtree/mtree` snapshot was mostly empty because the
  secondary process had already failed.

The next correction must therefore move the same analysis before
`primary.migrate`.

## QEMU COLO Command Sample Difference

The QEMU COLO document sample assumes both sides already have compatible guest
device and memory topology before migration starts. Its command sequence then
connects the COLO NBD, compare, mirror, redirector, and migration channels and
executes migration.

The existing FTCTL path had already aligned the documented COLO channel/filter
sequence, but it still differed in one important way:

- it verified command-line/filter readiness before `migrate`;
- it recorded live `pci/qtree/mtree` evidence;
- but it did not use `qtree/mtree` evidence as a hard pre-migrate gate.

That allowed QEMU to discover a guest topology mismatch only while applying
incoming migration state, which surfaced as the QEMU memory-region assertion.

## Design

Before any `primary.migrate` command, FTCTL now performs a runtime topology
gate:

1. Capture primary and secondary live runtime state:
   - `info pci`
   - `info qtree`
   - `info mtree`
   - qemu argv
2. Analyze the pair with the existing topology analyzer using
   `context=pre_migrate`.
3. Keep PCI resource differences as evidence because secondary `-incoming`
   devices can be unassigned before migration.
4. Fail before migration if `qtree/mtree` indicates that the secondary runtime
   is not ready to receive the primary migration stream.

## Hard Fail Conditions

The gate fails with `xcolo_protocol_failure_phase=pre_migrate_topology_analysis`
when:

- primary has guest-visible `qtree` devices but secondary `qtree` has no device
  entries;
- primary has a populated memory tree but secondary `mtree` is empty or only a
  placeholder;
- primary guest-visible `qtree` device IDs are missing from secondary.

Representative errors:

```text
xcolo_pre_migrate_secondary_qtree_empty
xcolo_pre_migrate_secondary_mtree_empty
xcolo_pre_migrate_guest_topology_missing
```

## State And Evidence

The gate writes:

```text
runtime-topology-analysis-before_migrate.txt
xcolo_pre_migrate_topology_analyzed=yes
xcolo_pre_migrate_topology_gate_state=ok|failed
xcolo_pre_migrate_topology_gate_error
xcolo_pre_migrate_topology_gate_reason
xcolo_pre_migrate_pci_diff_count
xcolo_pre_migrate_qtree_diff_count
xcolo_pre_migrate_mtree_diff_count
```

If the gate fails, the protection flow stops before `primary.migrate`. This is
intentional: a controlled FTCTL error with actionable topology evidence is
preferable to letting secondary QEMU crash and leaving Cloud DB/libvirt runtime
state divergent.

## Repetition Guard

If the same assertion appears again after this change, it means one of two
things:

- the pre-migrate gate incorrectly passed an incomplete topology; or
- the topology looked complete before migration but QEMU still rejected a
  specific memory-region mapping during migration.

In either case, the next fix must compare the recorded
`runtime-topology-analysis-before_migrate.txt` with the post-failure evidence
and target the first missing guest device or memory region. Do not return to
generic COLO network, disk, or firewall hypotheses unless the evidence points
there.
