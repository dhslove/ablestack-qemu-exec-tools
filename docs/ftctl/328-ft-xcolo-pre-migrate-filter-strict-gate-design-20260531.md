# FT X-COLO Pre-Migrate Filter Strict Gate Design

## Background

The latest FT protection run for `r97-link-01` progressed farther than earlier
runs:

- baseline seed completed for both disks,
- standby VM creation and secondary block graph attachment completed,
- primary block graph attachment completed,
- QMP chardev/object rebuild completed during runtime validation.

However, the run still failed with:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

The evidence showed that `primary.migrate` had already started before the
primary filter/chardev graph was complete. The runtime validation repair then
rebuilt chardevs and objects too late, while primary QEMU was already stuck in
`finish-migrate` and secondary QEMU was in `inmigrate`/`colo`.

## Root Cause

`ftctl_xcolo_observe_primary_filter_chardev_binding()` is an observation helper.
It logs `defer` when required chardev frontends are not open, but returns success
so the main flow can continue gathering diagnostics.

The protection path incorrectly used that observation return code as a strict
pre-migrate gate:

```bash
if ! ftctl_xcolo_observe_primary_filter_chardev_binding "${vm}"; then
  ftctl_xcolo_primary_net_filters_qmp_rebuild ...
fi
```

Because `defer` returned success, pre-migrate rebuild was skipped. The later
runtime validation rebuild proved that the QMP rebuild primitive worked, but it
was executed after the migration state machine had already moved past the safe
attachment point.

## Design Principle

For FT, the primary and secondary must enter COLO as a matched pair. Runtime
validation may diagnose a bad COLO graph, but it must not be the normal place to
construct the primary network filter graph.

The primary network filter/chardev graph must be complete before:

1. `primary.cont_before_migrate`
2. `primary.migrate`

If that precondition is not met, FTCTL must fail early and preserve a clear
diagnostic reason instead of starting a migration that cannot converge.

## New Flow

### Channel gate refinement

This design requires the primary filter/chardev graph to be complete before
migration. The channel readiness condition is refined by
`329-ft-xcolo-premigrate-channel-gate-split-design-20260531.md`: pre-migrate
validation requires listener/local-loopback readiness, while runtime validation
keeps the stricter peer `ESTABLISHED` requirement.

### Primary XML marker path

When the generated primary XML already contains X-COLO runtime markers:

1. validate the expected channel paths,
2. observe current chardev binding state,
3. if `xcolo_primary_filter_chardev_ready != yes`, run QMP rebuild with source
   `pre_migrate_xml_chardev_incomplete`,
4. validate channel paths again,
5. wait for pre-migrate topology-aware `xcolo_primary_filter_chardev_ready=yes`,
6. only then mark `primary.net_filters` as ready and allow migration.

### Primary QMP-only path

When XML markers are not available:

1. run QMP rebuild with source `pre_migrate_no_xml_markers`,
2. validate channel paths,
3. wait for pre-migrate topology-aware `xcolo_primary_filter_chardev_ready=yes`,
4. only then mark `primary.net_filters` as ready and allow migration.

### Runtime validation

Runtime validation no longer attempts to rebuild the primary network filter
graph after migration has started. It remains responsible for:

- collecting QMP status,
- collecting COLO status,
- collecting filter/chardev/block graph diagnostics,
- classifying failure reasons such as
  `primary_filter_chardev_frontend_incomplete`.

## State And Events

Expected successful pre-migrate evidence:

```text
primary.net_filters.rebuild start source=pre_migrate_xml_chardev_incomplete
primary.chardev_add.*
primary.object_add_*
primary.net_filters.rebuild ok
primary.filter_chardev_binding ok phase=pre_migrate topology_aware=yes
primary.net_filters ok mode=qmp-rebuild
primary.cont_before_migrate ok
primary.migrate ok
```

Expected early failure evidence:

```text
primary.filter_chardev_binding fail
primary.net_filters.pre_migrate_gate fail
last_error=primary_filter_chardev_frontend_incomplete
```

In the early failure case, `primary.migrate` must not be emitted after the
failed pre-migrate gate.

## Compatibility

This keeps the earlier runtime rebuild implementation as a reusable QMP rebuild
primitive, but changes its primary responsibility from runtime repair to
pre-migrate construction. Existing diagnostic state names are kept so Cloud UI
and existing logs remain readable.

The design supersedes the part of
`327-ft-xcolo-primary-filter-runtime-rebuild-design-20260531.md` that allowed
`source=runtime_validation` to be a normal repair path.

`330-ft-xcolo-premigrate-chardev-topology-aware-gate-design-20260531.md`
refines this document: the pre-migrate gate is strict about required topology
and missing labels, but it does not require every listener/server-side chardev
to report `frontend-open=true` before migration starts.
