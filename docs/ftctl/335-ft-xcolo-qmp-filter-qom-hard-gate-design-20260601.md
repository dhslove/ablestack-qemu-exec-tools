# 335. FT X-COLO QMP Filter QOM Hard Gate Design

## Background

Run `2026-06-01-04` proved that pre-migrate evidence is now preserved. The
run still failed at primary migration, but the preserved evidence narrowed the
cause:

- COLO channels were established.
- Primary chardev topology was accepted.
- Migration capabilities were present.
- `xcolo_primary_net_filters_attached=true` was set.
- Pre-migrate QOM evidence did not confirm `m0`, `redire0`, `redire1`, and
  `comp0` as valid primary filter objects.

The top-level failure remained `primary_migrate_failed`, but the actionable
root is earlier: qemu FTCTL treated QMP `object-add` as sufficient proof of
filter topology. That is too weak for FT.

## Design

qemu FTCTL must promote primary filter QOM validation from diagnostic evidence
to a hard pre-migrate gate.

After QMP `object-add`:

1. Discover each runtime object path from `qom-list /objects`.
2. Persist the discovered paths:
   - `xcolo_primary_filter_qom_m0_path`
   - `xcolo_primary_filter_qom_redire0_path`
   - `xcolo_primary_filter_qom_redire1_path`
   - `xcolo_primary_filter_qom_comp0_path`
3. Validate required object properties before declaring filters attached:
   - `m0`: `netdev`, `queue=tx`, `outdev=mirror0`, `status=on`,
     `insert=behind`, `position=tail`
   - `redire0`: `netdev`, `queue=rx`, `indev=compare_out`, `status=on`,
     `insert=behind`, `position=tail`
   - `redire1`: `netdev`, `queue=rx`, `outdev=compare0`, `status=on`,
     `insert=behind`, `position=tail`
   - `comp0`: `primary_in=compare0-0`, `secondary_in=compare1`,
     `outdev=compare_out0`, `iothread=iothread1`
4. Set `xcolo_primary_net_filters_attached=true` only after QOM validation
   returns `xcolo_primary_filter_qom_ready=yes`.
5. If validation fails, stop before primary `migrate` and persist:
   - `xcolo_primary_net_filters_attached=false`
   - `last_error=primary_filter_qom_topology_missing`
   - `xcolo_primary_filter_qom_topology_failed_reason=<reason>`

## Expected Behavior

The next run must not enter primary QMP `migrate` unless the primary filter
QOM topology is confirmed. If the topology is still invalid, the run should
fail earlier and explicitly at `primary_filter_qom_topology_missing`, not later
as the opaque COLO protocol error:

```text
Received invalid message 0x0000 length 0x0000
```

If QOM topology is confirmed and the same COLO protocol error still appears,
that is a new failure signature and the progress document must record it as
forward progress, not a repeated loop.
