# FT XCOLO Incoming Secondary Pre-Migrate PCI Deferral Design

Date: 2026-06-10

## Background

Run 113 stopped before `primary.migrate` with:

```text
xcolo_live_pci_identity_unmaterialized
secondary_incoming_pci_unassigned
```

The Run 112 hard gate was useful because it prevented a QEMU assertion path.
However, Run 113 proved that the gate was too strict for the `before_migrate`
phase. The secondary was an incoming VM waiting for migration state, so QEMU
reported root ports, BARs, IRQs, and bridge ranges as unassigned. That state is
not enough by itself to prove migration ABI incompatibility before migration is
issued.

## Principle

FT startup must distinguish between:

1. guest ABI shape mismatch that is already known before migration and must
   fail;
2. expected incoming-secondary runtime materialization that can only become
   final after migration state is loaded;
3. post-migration PCI or mtree mismatch, which remains a hard failure.

The QEMU COLO command-line alignment, stable RBD path policy, and no hot-plug
principle remain unchanged. FTCTL must not dynamically mutate the protected VM
topology after startup to make migration work.

## Design

### Pre-Migrate Live Topology Gate

`ftctl_xcolo_verify_live_runtime_topology_pair(vm, secondary, before_migrate)`
continues to collect:

- live QEMU argv for both sides;
- `info pci`;
- `info qtree`;
- `info mtree`;
- a live topology diff file.

At `before_migrate`, these remain hard failures:

- missing QEMU argv;
- missing guest-visible `-device` entries;
- guest device command-line mismatch;
- missing `info pci`;
- missing PCI identity records;
- PCI identity mismatch that is not the known incoming-secondary unassigned
  shape.

At `before_migrate`, the known incoming-secondary unassigned shape is a deferred
warning, not a hard failure:

- multiple root ports show `secondary bus 0` / `subordinate bus 0`;
- BARs or device resources are not mapped;
- secondary PCI identity differs only because incoming migration state has not
  materialized the bus topology yet.

For this case FTCTL records:

```text
xcolo_live_runtime_topology=ok
xcolo_live_pci_identity=deferred
xcolo_live_pci_identity_warning=xcolo_live_pci_identity_deferred_for_incoming
xcolo_live_pci_evidence=xcolo_live_pci_identity_deferred_for_incoming
```

The event remains `xcolo.live_runtime_topology result=ok`, with a warning detail
so the test log clearly shows that migration is proceeding with expected
incoming materialization.

### Post-Migrate Live Topology Gate

After migration state has been applied, the same incoming-secondary unassigned
shape is no longer acceptable. Any non-`before_migrate` phase must continue to
fail with:

```text
xcolo_live_pci_identity_unmaterialized
```

This keeps the hard ABI protection while avoiding a false positive before QEMU
has had a chance to realize incoming state.

### Rollback Runtime Safety

If a startup/pre-migrate gate fails after the primary was re-created with
generated FT XML, rollback must leave a coherent primary-side state.

Rollback must:

- destroy the transient secondary if it exists;
- unmap any secondary RBD mappings managed by FTCTL;
- attempt to restore the primary from the backed-up Cloud/libvirt XML;
- set `active_side=primary`, `peer_domain_expected=false`, and
  `standby_state=stopped`;
- preserve a sticky failure reason;
- if primary restoration fails, surface `primary_restore_failed` instead of
  silently leaving an ambiguous generated-XML runtime.

Failure evidence is preserved until explicit cleanup.

## Expected Retest Flow

The next run should no longer fail at `before_migrate` solely because the
secondary incoming VM has unassigned PCI/BAR resources.

Expected progression:

1. baseline seed completes;
2. generated primary and secondary startup succeeds;
3. pre-migrate live topology reports `ok` with deferred PCI warning;
4. COLO handshake and `primary.migrate` are attempted;
5. any further failure is classified at the later phase where it actually
   occurs.

If the invalid COLO message path appears again, the report must include:

- whether `before_migrate` was deferred correctly;
- whether the first hard mismatch occurred after migration;
- primary/secondary QEMU logs;
- `query-migrate` error description;
- filter/chardev state at failure.
