# 333. FT X-COLO QMP Primary Filter Object Attach Design

## Background

During the `r97-link-01` FT validation on the 32.x cluster, the run after
the parent-node NBD export change progressed further than previous attempts:

- Cloud created the standby VM and volumes.
- Baseline seeding completed.
- Secondary block graph creation completed.
- COLO peer channels reached the expected connected state.
- The secondary entered `query-migrate=colo` and `query-colo-status=secondary`.

The remaining failure was:

```text
last_error=xcolo_runtime_validation_failed:primary_migrate_failed
primary query-migrate: failed
secondary log: Can't receive COLO message: Input/output error
primary log: filter mirror send failed(Operation not permitted)
```

This means the storage graph and secondary COLO entry path are no longer the
primary blocker. The primary packet filter path is being activated too early.

## Root Cause

The generated primary XML still placed both chardev endpoints and packet
filter objects in the QEMU command line:

- `filter-mirror,id=m0`
- `filter-redirector,id=redire0`
- `filter-redirector,id=redire1`
- `colo-compare,id=comp0`

Even though the domain starts with `-S`, QEMU creates these filter objects when
the NIC/netdev is created. That allows the packet mirror path to become active
before qemu FTCTL has completed the block graph, NBD export/client setup, and
the final migration command. In the observed run, that premature activation
surfaced as `filter mirror send failed(Operation not permitted)` and then the
primary migration transitioned to `failed`.

## Design

The primary XML and QMP responsibilities are split:

1. Primary generated XML keeps only the minimal startup contract:
   - `-S`
   - COLO chardev endpoints/listeners:
     - `mirror0`
     - `compare1`
     - `compare0`
     - `compare0-0`
     - `compare_out`
     - `compare_out0`
   - native libvirt iothread declaration.
2. Primary generated XML must not include packet filter objects:
   - no `filter-mirror`
   - no `filter-redirector`
   - no `colo-compare`
3. qemu FTCTL starts the primary generated domain paused and waits for the
   required listener/channel readiness.
4. qemu FTCTL starts the secondary generated domain and verifies peer channel
   connectivity.
5. qemu FTCTL builds the secondary and primary block graph/NBD topology.
6. Only after block graph and channel readiness does qemu FTCTL attach primary
   packet filter objects with QMP.
7. The QMP attach point is delayed, but the attach order must match the QEMU
   primary COLO filter order:
   - `filter-mirror m0`
   - `filter-redirector redire0`
   - `filter-redirector redire1`
   - `colo-compare comp0`
8. qemu FTCTL validates chardev binding, QOM filter topology, and channel
   state before issuing primary `migrate`.

## Progress Management Rule

Every FT validation run must update a separate progress document with:

- test target and run id;
- last reached stage;
- new progress compared with the previous run;
- repeated failure signature, if any;
- whether the run is making forward progress or circling on the same failure;
- next exact improvement direction.

For the current `r97-link-01` chain this is tracked in:

```text
docs/ftctl/399-ft-validation-progress-r97-link-01-20260601.md
```

Design 334 extends this rule with a hard repeat gate: the next run must record
pre-migrate QOM/chardev/channel evidence and `query-migrate.error-desc` before
any recovery path can erase the generated runtime state.

## Expected Result

The next run should no longer show primary QEMU command-line filter objects
before QMP handshaking. The desired runtime evidence is:

- primary command line has COLO chardevs but no filter objects;
- QMP/QOM shows `m0`, `redire0`, `redire1`, and `comp0` only after qemu FTCTL
  attaches them in QEMU documented primary order;
- channel state remains established after QMP object attach;
- primary migration does not fail immediately with filter mirror send errors.

Design 336 supersedes the earlier mirror-last experiment. The safe model is now
late QMP attach with QEMU documented primary filter order, plus the Design 335
QOM hard gate before primary `migrate`.
