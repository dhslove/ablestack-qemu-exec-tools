# 320. FT X-COLO QEMU Procedure Alignment And Checkpoint Defer Design

Date: 2026-05-30

## Superseded Checkpoint Note - 2026-06-04

The checkpoint-delay portion of this design is superseded by
[345. FT XCOLO Pre-Migrate Checkpoint Hard Gate Design](345-ft-xcolo-premigrate-checkpoint-hard-gate-design-20260604.md).

The migration capability portion is superseded by
[362. FT XCOLO QEMU 9.2.4 Return-Path Capability Conflict Design](362-ft-xcolo-qemu-924-return-path-capability-conflict-design-20260605.md).
Current QEMU 9.2.4-aligned FTCTL behavior enables `x-colo` but explicitly
keeps generic migration `return-path` disabled for COLO.

The earlier conclusion treated `x-checkpoint-delay` as post-start tuning. Run
68 later proved that the remaining blocker is primary COLO role transition
after `primary.migrate`, so ABLESTACK FT validation now requires
`migrate-set-parameters x-checkpoint-delay` to be set and verified before
`primary.migrate`.

The filter direction and QEMU topology sections below remain historical design
context; do not use the "Defer Checkpoint Delay" section as current
implementation guidance.

## Context

The retest after design 319 proved two things:

- the generated primary XML was active and contained the new `redire0` /
  `redire1` direction,
- QOM properties matched the generated XML, but the run still failed at
  `primary_filter_chardev_frontend_incomplete`.

The failure state was still:

```text
primary:   status=finish-migrate, migrate=active, colo=none
secondary: status=inmigrate,      migrate=colo,   colo=secondary
```

The newly added diagnostics were useful: they proved this is not stale
deployment and not a simple object-property mismatch. The official QEMU COLO
procedure documents the primary filter direction as:

```text
filter-mirror,id=m0,netdev=hn0,queue=tx,outdev=mirror0
filter-redirector,netdev=hn0,id=redire0,queue=rx,indev=compare_out
filter-redirector,netdev=hn0,id=redire1,queue=rx,outdev=compare0
colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1
```

It also shows the primary startup QMP sequence as:

1. `qmp_capabilities`
2. `blockdev-add` for the NBD client
3. `x-blockdev-change`
4. `migrate-set-capabilities` with `x-colo` only; generic migration
   `return-path` must stay disabled
5. `migrate`

The same document describes `migrate-set-parameters x-checkpoint-delay` as an
operation that can be issued after the above steps to adjust the idle
checkpoint period. Therefore, setting `x-checkpoint-delay` before `migrate` is
not part of the minimal documented COLO entry path.

## Principles

1. FT testing must stay anchored to the QEMU COLO procedure unless local QEMU
   behavior proves a controlled deviation is required.
2. The primary/secondary clone-takeover goal remains unchanged: the secondary
   must preserve guest identity and be ready to take over the service role.
3. Topology experiments must leave clear documentation when they are rejected,
   so the same branch is not retried later.
4. Runtime diagnostics must show both QOM object existence and the properties
   that control packet-filter placement.
5. Optional tuning commands must not block the minimal COLO start path.

## Design

### Restore Primary Filter Direction

Restore the generated primary XML and QMP fallback to the official QEMU
direction:

```text
-object filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0
-object filter-redirector,id=redire0,netdev=hostnet0,queue=rx,indev=compare_out
-object filter-redirector,id=redire1,netdev=hostnet0,queue=rx,outdev=compare0
-object colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1
```

In the original 320 design this was written with `hostnet0` as the local
single-NIC value. Design 326 refines that point: `hostnet0` is not a constant.
The implementation must resolve the actual libvirt/QEMU netdev ID from the
generated XML and then apply the same QEMU COLO topology to that netdev.

### Defer Checkpoint Delay

Remove pre-migrate `migrate-set-parameters x-checkpoint-delay` from the
handshake path. The minimal startup path must be:

```text
secondary qmp_capabilities
secondary migrate-set-capabilities
secondary nbd-server-start
secondary nbd-server-add
primary qmp_capabilities
primary blockdev-add
primary x-blockdev-change
primary filter topology already in XML or attached by fallback
primary migrate-set-capabilities
primary migrate
```

After runtime validation succeeds, attempt to apply
`x-checkpoint-delay` as a post-start tuning step. Failure to apply that tuning
must be logged as a warning and must not convert an otherwise valid COLO start
into a failed protection action.

### QOM Diagnostics

Keep the QOM snapshot mechanism from design 319, but correct and expand the
properties:

- use `primary_in` and `secondary_in`, not `primary-in` and `secondary-in`,
- capture `status`, `insert`, and `position` on net filter objects,
- keep `netdev`, `queue`, `indev`, `outdev`, and `iothread`.

These snapshots should prove whether QEMU inserted the filters into the live
netdev path or merely accepted the objects.

## Expected Result

The next retest should answer a narrower question:

- If the primary enters COLO mode, the rejected topology experiment and
  pre-migrate checkpoint setup were the blocking factors.
- If the primary remains at `finish-migrate` with frontend chardevs closed, the
  next target is filter insertion state (`status`, `insert`, `position`) or a
  QEMU/libvirt interaction around XML-started net filters.

The failure artifact must be sufficient to decide that without another broad
topology guess.

## Follow-up In Design 321

The retest after this design showed the official QEMU topology and deferred
checkpoint setup were both applied, but the runtime still stopped at
`primary_filter_chardev_frontend_incomplete`. The QOM evidence showed
`status=on`, `insert=behind`, and `position=tail` for the primary filter chain,
so design 321 changes validation policy: a healthy QOM filter chain with live
migration is preserved as a `colo_established_candidate` instead of being
destroyed only because filter-facing chardev frontends are still closed.

Design 322 further refines that rule. QOM property reads may be empty on this
QEMU/libvirt stack even when the live QEMU command line contains the expected
filter objects. Therefore QOM is diagnostic, while live command-line/XML
topology plus established 9000-series channels are sufficient to preserve a
candidate runtime.
