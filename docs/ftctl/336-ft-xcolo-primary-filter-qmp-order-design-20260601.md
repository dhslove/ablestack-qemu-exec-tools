# 336. FT X-COLO Primary Filter QMP Order Design

## Background

Run `2026-06-01-05` proved that the Design 335 QOM hard gate works:

- primary QMP filter objects were attached dynamically;
- `primary.filter_qom_topology=ok`;
- pre-migrate evidence showed `filter_qom=yes`, `chardev=yes`, and all COLO
  channel checks as `yes`;
- primary `migrate` returned `ok`.

The run still failed during runtime validation:

```text
last_error=xcolo_runtime_validation_failed:primary_migrate_failed
primary query-migrate.error-desc=Received invalid message 0x0000 length 0x0000
secondary log=Can't receive COLO message: Input/output error
```

This is no longer a missing QOM object or missing channel problem. The remaining
known mismatch is the primary QMP filter attach order.

## Root Cause

The previous mitigation delayed packet filter creation until the block graph and
channels were ready, but it attached objects in this order:

```text
redire0 -> redire1 -> comp0 -> m0
```

That order was chosen to avoid early mirror traffic while filter objects still
lived in the primary command line. After Design 333 and Design 335, the attach
point is already late and guarded. Keeping `m0` last now diverges from QEMU's
documented primary COLO filter chain.

## Design

qemu FTCTL must keep late QMP attach, but the primary object-add order must
match QEMU's primary COLO procedure:

```text
m0 -> redire0 -> redire1 -> comp0
```

The concrete rules are:

1. Primary generated XML still contains only COLO chardev endpoints and no
   packet filter objects.
2. qemu FTCTL attaches primary filters only after secondary startup, block
   graph setup, NBD export/client setup, and channel readiness.
3. QMP `object-add` order is:
   - `filter-mirror id=m0`
   - `filter-redirector id=redire0`
   - `filter-redirector id=redire1`
   - `colo-compare id=comp0`
4. After attach, qemu FTCTL persists:
   - `xcolo_primary_filter_qmp_attach_order=qemu-doc-primary`
5. The Design 335 QOM hard gate remains mandatory before primary `migrate`.

## Expected Behavior

The next run must prove the attach order changed before interpreting any
further COLO protocol failure:

- `primary.object_add_filter_mirror` appears before redirector and compare
  object-add events;
- `xcolo_primary_filter_qmp_attach_order=qemu-doc-primary`;
- `primary.filter_qom_topology=ok`;
- `primary.pre_migrate_evidence` is still complete.

If the same `Received invalid message 0x0000 length 0x0000` failure appears
after these conditions are true, it is a new failure signature beyond primary
filter object ordering and must be recorded separately in the progress log.
