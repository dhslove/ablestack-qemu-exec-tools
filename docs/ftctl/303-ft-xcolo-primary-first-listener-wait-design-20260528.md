# FT X-COLO Primary-First Listener Wait Design

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
- `compare1` uses `server=on,wait=off`;
- loopback compare sockets remain `wait=off`;
- secondary generated XML still connects to the primary listener endpoints;
- qemu FTCTL verifies listener presence passively with local socket inventory.

The `-S` flag is the guard that prevents guest execution before the secondary is attached. Chardev `wait=on` must not be used as the guard in a primary-first startup model.

## Async Create Handling

With `wait=off`, `virsh create` can return successfully before the listener polling loop observes both sockets. Therefore qemu FTCTL must not treat a completed `virsh create` process with `rc=0` as listener failure.

Listener waiting rules:

- if `virsh create` exits nonzero before listeners are visible, fail immediately;
- if `virsh create` exits zero before listeners are visible, continue polling until listeners appear or the listener timeout expires;
- when both listener ports are visible, continue to secondary startup and QMP handshake.

## Configuration

- `FTCTL_XCOLO_MIRROR_WAIT` defaults to `off`.
- `FTCTL_XCOLO_COMPARE_WAIT` defaults to `off`.
- invalid values fall back to `off`.

These knobs exist for diagnostics only. The supported cloud-managed primary-first default is `off/off`.

## Validation

Selftest must assert generated primary XML:

- contains `mirror0 ... wait=off`;
- contains `compare1 ... wait=off`;
- does not contain `mirror0 ... wait=on`;
- does not contain `compare1 ... wait=on`.

Runtime validation must still fail if the later QMP/migration convergence does not prove both sides are actually in COLO state.
