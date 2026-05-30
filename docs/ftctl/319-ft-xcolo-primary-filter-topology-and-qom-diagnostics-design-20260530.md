# 319. FT X-COLO Primary Filter Topology And QOM Diagnostics Design

Date: 2026-05-30

## Context

The retest after design 318 proved that the generated primary XML path is being
used:

- primary COLO filter objects existed under QOM,
- 9000-series channel paths were created,
- block conversion and migration setup progressed,
- failure moved to runtime validation.

The final failure was:

```text
xcolo_runtime_validation_failed:primary_filter_chardev_frontend_incomplete
```

The captured QEMU command line showed that the primary runtime contained:

```text
filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0
filter-redirector,id=redire0,netdev=hostnet0,queue=rx,indev=compare_out
filter-redirector,id=redire1,netdev=hostnet0,queue=rx,outdev=compare0
colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0
```

This was initially interpreted as a reversed primary RX redirector direction.
That interpretation was tested and rejected by the next run. The QEMU official
COLO procedure uses this primary RX topology:

```text
filter-redirector,id=redire0,queue=rx,indev=compare_out
filter-redirector,id=redire1,queue=rx,outdev=compare0
```

Design 320 supersedes this document's topology change. The useful part of this
document is the QOM diagnostics direction: object presence alone is not enough,
and property values must be captured.

## Principles

1. FT remains a clone-takeover feature, not an HA restart feature. The
   secondary must preserve guest identity and be able to take over from the
   primary service role.
2. A successful `object-add` or QOM object listing is not sufficient. The
   packet path must match the official QEMU COLO direction and expose enough
   property evidence to prove it.
3. 9000-series TCP channel establishment and QOM object presence must be
   diagnosed separately from QOM property correctness.
4. The runtime failure artifact must be enough to distinguish wrong topology
   from a QEMU role transition failure.

## Design

### Primary Filter Topology

This topology was tested and rejected:

```text
-object filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0
-object filter-redirector,id=redire0,netdev=hostnet0,queue=rx,outdev=compare0
-object filter-redirector,id=redire1,netdev=hostnet0,queue=rx,indev=compare_out
-object colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1
```

Do not use this topology as the current implementation target. Design 320
restores the QEMU procedure direction.

The secondary topology remains unchanged:

```text
-object filter-redirector,id=f1,netdev=hostnet0,queue=tx,indev=red0
-object filter-redirector,id=f2,netdev=hostnet0,queue=rx,outdev=red1
-object filter-rewriter,id=rew0,netdev=hostnet0,queue=all
```

### Diagnostics

Failure snapshots already include `qom-list` output for the known COLO objects.
They must now also include `qom-get` snapshots for topology-defining
properties:

- `netdev`
- `queue`
- `outdev`
- `indev`
- `primary_in`
- `secondary_in`
- `status`
- `insert`
- `position`
- `iothread`

The debug files remain under:

```text
/run/ablestack-vm-ftctl/debug/xcolo/<vm>/
```

Expected diagnostic value:

- If QOM properties match this design and validation still fails, the next
  issue is likely QEMU COLO primary role transition rather than object
  construction.
- If QOM properties do not match this design, the problem is in XML/QMP
  construction or stale deployed scripts.
- If chardev frontends remain closed while properties match, the next check is
  whether filter insertion/order properties are exposed by this QEMU build and
  need to be explicitly controlled.

## Expected Result

The retest reached the same runtime boundary and proved this topology did not
fix primary filter frontend binding. The next design must restore the QEMU
documented topology and isolate whether pre-migrate checkpoint parameter setup
is delaying or preventing primary COLO role transition.

If it still fails, the added QOM property snapshots must make the next change a
targeted correction instead of another broad topology guess.
