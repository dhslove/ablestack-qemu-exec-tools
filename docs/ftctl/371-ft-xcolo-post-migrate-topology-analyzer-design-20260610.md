# FT XCOLO Post-Migrate Topology Analyzer Design

Date: 2026-06-10

## Background

Run 107 proved that the secondary `-incoming` PCI identity deferral is useful:
the protection workflow passed the pre-migrate topology gate and entered QEMU
COLO migration. The failure then moved to the secondary QEMU process while it
was applying the incoming migration state:

```text
memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

This means the next useful change is not another blind topology tweak. The
runtime must record enough structured evidence to identify which device or
memory region is still not migration-compatible.

## Design

The FTCTL runtime keeps the existing hard gates:

- guest-visible `-device` argument mismatch remains a hard failure;
- fully assigned PCI identity mismatch remains a hard failure;
- block graph, COLO channel, and primary filter readiness remain hard
  pre-migrate contract checks;
- secondary `-incoming` PCI bus/BAR unassigned shape remains a deferred
  evidence state, not a hard failure.

The new analyzer adds structured counts and candidates.

## Pre-Migrate PCI Counts

The pre-migrate live topology gate now records:

```text
xcolo_live_pci_identity_primary_count
xcolo_live_pci_identity_secondary_count
xcolo_live_pci_identity_diff_count
xcolo_live_pci_identity_missing_count
xcolo_live_pci_identity_extra_count
xcolo_live_pci_resource_diff_count
```

This prevents future reports from stopping at "first diff only". Every run can
say whether the PCI shape is unchanged, improved, or repeated.

## Post-Migrate Crash Analyzer

When a secondary crash is detected after `primary.migrate`, FTCTL captures and
analyzes:

- live qemu argv;
- `info pci`;
- `info qtree`;
- `info mtree`;
- primary and secondary QEMU log tails.

The analyzer writes:

```text
runtime-topology-analysis-post_migrate_secondary_crash.txt
```

and stores state keys:

```text
xcolo_post_migrate_crash_topology_analyzed=yes
xcolo_post_migrate_crash_pci_diff_count
xcolo_post_migrate_crash_qtree_diff_count
xcolo_post_migrate_crash_mtree_diff_count
xcolo_assert_candidate_device
xcolo_assert_candidate_region
xcolo_assert_candidate_reason
```

Compatibility aliases are also stored for UI/backend reporting:

```text
xcolo_post_migrate_crash_analyzed
xcolo_post_migrate_pci_diff_count
xcolo_post_migrate_qtree_diff_count
xcolo_post_migrate_mtree_diff_count
```

## Interpretation Rule

If `memory_region_add_subregion_common` appears again:

- it is progress if the analyzer produces a new narrower candidate device or
  memory region;
- it is a repeated loop if the assertion and the same candidate repeat;
- a repeated candidate must trigger a targeted topology fix for that device or
  region instead of another generic COLO/network/disk hypothesis.

## Non-Goals

This change does not alter the current QEMU command-line layout, RBD path
policy, disk graph, COLO filter order, or primary/secondary VM lifecycle. It is
a diagnostic hardening change whose purpose is to make the next topology fix
evidence-driven.
