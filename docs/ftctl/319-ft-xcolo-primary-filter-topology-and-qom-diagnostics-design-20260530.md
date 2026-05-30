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

This is close to the intended COLO topology, but the primary RX redirector
direction is reversed from the standard primary-side packet path. The expected
primary RX chain is:

```text
guest rx -> redire0 outdev=compare0 -> colo-compare -> redire1 indev=compare_out -> guest
```

The previous topology tried to consume `compare_out` before the local compare
input path was produced, so QEMU could accept the objects without completing
the filter-facing chardev frontend binding.

## Principles

1. FT remains a clone-takeover feature, not an HA restart feature. The
   secondary must preserve guest identity and be able to take over from the
   primary service role.
2. A successful `object-add` or QOM object listing is not sufficient. The
   packet path must be connected in the direction QEMU COLO expects.
3. 9000-series TCP channel establishment and QOM object presence must be
   diagnosed separately from QOM property correctness.
4. The runtime failure artifact must be enough to distinguish wrong topology
   from a QEMU role transition failure.

## Design

### Primary Filter Topology

The primary generated XML must use this topology:

```text
-object filter-mirror,id=m0,netdev=hostnet0,queue=tx,outdev=mirror0
-object filter-redirector,id=redire0,netdev=hostnet0,queue=rx,outdev=compare0
-object filter-redirector,id=redire1,netdev=hostnet0,queue=rx,indev=compare_out
-object colo-compare,id=comp0,primary_in=compare0-0,secondary_in=compare1,outdev=compare_out0,iothread=iothread1
```

The QMP fallback path must use the same `redire0` and `redire1` semantics so
legacy runtimes and XML-started runtimes do not diverge.

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
- `primary-in`
- `secondary-in`
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

The next retest should reach at least the same boundary as design 318, but with
the primary RX COLO path correctly ordered. The desired result is for runtime
validation to leave the primary in COLO primary state and the secondary in COLO
secondary state.

If it still fails, the added QOM property snapshots must make the next change a
targeted correction instead of another broad topology guess.
