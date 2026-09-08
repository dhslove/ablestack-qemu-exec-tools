# 329. FT X-COLO Pre-Migrate Channel Gate Split Design

Date: 2026-05-31

## Context

After design 328, the FT run no longer started migration with an incomplete
primary filter graph. The new pre-migrate rebuild executed before
`primary.migrate`:

```text
primary.filter_chardev_binding defer
primary.net_filters.rebuild start source=pre_migrate_xml_chardev_incomplete
primary.chardev_add.* ok
primary.object_add_* ok
primary.net_filters.rebuild ok
```

The run then failed before `primary.migrate` with:

```text
colo_compare_peer_channel_not_established
```

The channel evidence was:

```text
mirror=yes compare=no compare_local=yes compare_out=yes
```

This proves the previous fix moved the failure boundary earlier and avoided the
`finish-migrate`/`inmigrate` deadlock. The remaining issue is that the
pre-migrate channel gate required the peer-side compare channel to already be
`ESTABLISHED`.

## Problem

The primary compare peer channel on port 9004 is expected to be accepted by the
primary side and completed by the secondary side during the COLO migration path.
Before `primary.migrate`, it may legitimately be only `LISTEN`.

Using the same condition for pre-migrate readiness and post-migrate runtime
readiness is therefore too strict.

## Design

Split primary channel validation into two scopes.

### Pre-Migrate Gate

Before `primary.migrate`, require only the
topology that must already exist:

- mirror channel: `LISTEN` or already `ESTABLISHED`
- compare peer channel: `LISTEN` or already `ESTABLISHED`
- compare local loopback-in channel: `ESTABLISHED`
- compare loopback-out channel: `ESTABLISHED`
- primary filter/chardev binding: pre-migrate topology-aware
  `xcolo_primary_filter_chardev_ready=yes`

If the compare peer channel is not yet `ESTABLISHED` but is `LISTEN`, the
pre-migrate gate passes.

### Runtime Gate

After migration starts, runtime validation keeps the strict runtime condition:

- mirror channel: `ESTABLISHED`
- compare peer channel: `ESTABLISHED`
- compare local loopback-in channel: `ESTABLISHED`
- compare loopback-out channel: `ESTABLISHED`
- primary role: `query-colo-status=primary`
- secondary role: `query-colo-status=secondary`

If port 9004 never becomes established after migration starts, runtime
validation must still fail with `colo_compare_peer_channel_not_established`.

## Code Shape

Add a pre-migrate-specific readiness helper:

```bash
ftctl_xcolo_primary_channels_premigrate_ready
ftctl_xcolo_primary_premigrate_channel_failure_reason
```

Use these helpers from `ftctl_xcolo_validate_primary_channel_paths`, which is
currently used by the pre-migrate attach path. Keep
`ftctl_xcolo_primary_channels_ready` and
`ftctl_xcolo_primary_channel_failure_reason` strict for runtime diagnostics.

## Expected Evidence

Pre-migrate success can now look like this:

```text
primary.channel_paths ok mode=pre_migrate mirror_listen=yes compare_listen=yes
primary.filter_chardev_binding ok phase=pre_migrate topology_aware=yes
primary.net_filters ok mode=qmp-rebuild
primary.migrate ok
```

Runtime success still requires peer establishment:

```text
xcolo.runtime_validate ok ... mirror=yes compare=yes compare_local=yes compare_out=yes
```

Runtime failure, if the peer never attaches, remains explicit:

```text
xcolo.runtime_validate fail reason=colo_compare_peer_channel_not_established
```

## Relationship To Design 328

Design 328 remains valid: the primary filter/chardev graph must be constructed
before migration. This design refines the channel gate used by that same
pre-migrate boundary so that listener readiness and runtime peer establishment
are not conflated.

`330-ft-xcolo-premigrate-chardev-topology-aware-gate-design-20260531.md`
extends the same split to chardev frontend validation: pre-migrate listener
frontends may remain closed when the corresponding channel topology is ready,
while runtime validation remains strict.
