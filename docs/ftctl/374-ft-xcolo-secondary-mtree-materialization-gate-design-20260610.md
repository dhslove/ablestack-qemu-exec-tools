# FT XCOLO Secondary Mtree Materialization Gate Design

Date: 2026-06-10

## Background

Run 110 showed that the post-migrate role-transition gate improved failure
classification, but did not solve activation. The new evidence is:

```text
xcolo_post_migrate_role_transition_gate=failed
xcolo_post_migrate_role_transition_reason=chardev_query_transient
last_error=xcolo_secondary_chardev_query_unstable_after_migrate
```

Secondary QEMU also logged:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion `!subregion->container' failed.
```

The pre-migrate qtree comparison passed, but mtree evidence showed secondary
PCI bridge aliases and BAR-backed regions still materialized as zero-range
entries, while primary had assigned runtime BAR ranges. QEMU 9.2.4 asserts in
`memory_region_add_subregion_common()` when a MemoryRegion that already belongs
to a container is added again. In this run, migration state was applied while
secondary PCI memory mapping was still not materialized in a migration-safe
shape.

## Design

Keep the existing generated command line, disk graph, RBD stable path policy,
and COLO filter order unchanged. Add a stricter pre-migrate runtime gate:

- parse primary and secondary `info mtree` before `primary.migrate`;
- count zero-range PCI alias mappings such as:

```text
0000000000000000-0000000000000000 ... alias pci_bridge_mem
0000000000000000-0000000000000000 ... alias pci_bridge_pref_mem
0000000000000000-0000000000000000 ... alias pci_bridge_io
```

- if secondary has materially more zero-range PCI aliases than primary, fail
  before `primary.migrate`.

The pre-migrate failure should be explicit:

```text
xcolo_protocol_failure_phase=pre_migrate_topology_analysis
last_error=xcolo_pre_migrate_secondary_pci_resources_unmaterialized
```

This intentionally prefers an early, explainable failure over letting secondary
QEMU abort while applying migration state.

Also improve post-migrate classification:

- if the role-transition gate times out and secondary QEMU log contains
  `memory_region_add_subregion_common` or `subregion->container`, classify the
  failure as secondary QEMU assertion rather than a chardev wait failure.

Expected post-migrate classification:

```text
xcolo_protocol_failure_phase=post_migrate_secondary_crash
last_error=xcolo_secondary_qemu_assert_memory_region_container
```

## Non-Goals

This change does not:

- change primary or secondary disk graph construction;
- hot-plug guest-visible devices;
- modify existing QEMU COLO command sample alignment;
- treat `red0` connection refusal as the root cause unless it remains after
  the secondary mtree/materialization problem is removed.
