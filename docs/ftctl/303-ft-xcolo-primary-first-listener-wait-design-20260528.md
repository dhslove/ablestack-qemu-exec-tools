# FT X-COLO Primary-First Listener Wait Design

> Superseded note, 2026-06-05: the default `mirror0 wait=off` assumption in
> this document is superseded for the active cloud-managed/libvirt path by
> [356. FT XCOLO Premigrate Frontend Open Before Migrate Design](356-ft-xcolo-premigrate-frontend-open-before-migrate-design-20260605.md).
> The historical deadlock concern remains valid for synchronous primary create,
> but the active implementation uses asynchronous primary create and can start
> the secondary after observing the mirror listener.

## Background

During FT validation for `r97-link-01`, registration progressed beyond Cloud sync and generated XML creation. The block-backed cold conversion stopped the primary, generated the COLO primary XML, and invoked `virsh create` asynchronously.

The run then failed with:

```text
primary.create_generated.listeners result=fail reason=timeout mirror_port=9003 compare_port=9004
block_conversion.primary_create result=fail reason=listener_wait_failed
```

libvirt/QEMU logs showed:

```text
qemu-kvm: -chardev socket,id=mirror0,host=0.0.0.0,port=9003,server=on,wait=on:
info: QEMU waiting for connection on: disconnected:tcp:0.0.0.0:9003,server=on
```

Cloud saw the failure as `Stream closed` because the qemu command path timed out while waiting for the generated primary.

## Root Cause

The cloud-managed cold conversion path starts the generated primary before the generated secondary:

1. create generated primary runtime;
2. wait for primary-side COLO listener sockets;
3. create generated secondary runtime;
4. run QMP COLO handshake and migration setup.

The generated primary XML used `wait=on` for peer-facing chardev listeners. With `wait=on`, QEMU blocks during startup until the secondary connects. Because the secondary is intentionally not created until after the primary listener check, this creates a startup deadlock.

## Design Principles

- FT remains a COLO replica model, not HA-style standby boot.
- Cloud-managed VM and volume lifecycle remains owned by Cloud.
- qemu FTCTL owns generated XML, listener startup, and QMP handshaking.
- The primary-first startup contract must let QEMU start and expose listener sockets before the secondary exists.
- Guest execution remains paused until the QMP/migration sequence explicitly progresses.

## Primary Listener Contract

For cloud-managed primary-first X-COLO startup:

- primary generated XML keeps `-S`;
- `mirror0` uses `server=on,wait=off`;
- `compare1` uses `server=on,wait=on`;
- loopback compare sockets remain `wait=off`;
- secondary generated XML still connects to the primary listener endpoints;
- qemu FTCTL verifies listener presence passively with local socket inventory.

The `-S` flag is the guard that prevents guest execution before the secondary is attached. Chardev `wait=on` must not be used for every peer-facing listener in a primary-first startup model. `compare1` remains `wait=on` to match QEMU COLO's documented compare-channel contract, while `mirror0 wait=off` provides the early listener that lets qemu FTCTL safely start the secondary.

## Async Create Handling

With `mirror0 wait=off`, `virsh create` can expose the mirror listener before the compare channel is attached. With `compare1 wait=on`, `virsh create` may remain blocked until the secondary connects. Therefore qemu FTCTL must not treat an in-progress `virsh create` as failure while the mirror listener is visible.

Listener waiting rules:

- if `virsh create` exits nonzero before listeners are visible, fail immediately;
- if `virsh create` exits zero before listeners are visible, continue polling until listeners appear or the listener timeout expires;
- when the required primary listener contract is visible, continue to secondary startup;
- after secondary startup, verify both peer-facing channels are `ESTAB` before QMP handshake.

## Configuration

- `FTCTL_XCOLO_MIRROR_WAIT` defaults to `off`.
- `FTCTL_XCOLO_COMPARE_WAIT` defaults to `on`.
- invalid mirror values fall back to `off`; invalid compare values fall back to `on`.

These knobs exist for diagnostics only. The supported cloud-managed primary-first default is `mirror0=off`, `compare1=on`.

## Validation

Selftest must assert generated primary XML:

- contains `mirror0 ... wait=off`;
- contains `compare1 ... wait=on`;
- does not contain `mirror0 ... wait=on`;
- does not contain `compare1 ... wait=off` by default.

Runtime validation must still fail if the later QMP/migration convergence does not prove both sides are actually in COLO state.
