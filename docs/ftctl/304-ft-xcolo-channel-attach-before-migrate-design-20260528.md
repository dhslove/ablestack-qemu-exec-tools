# FT X-COLO Channel Attach Before Migrate Design

## Background

During FT validation for `r97-link-01`, cloud-managed cold conversion progressed beyond listener startup and secondary creation, but runtime validation failed:

```text
last_error=xcolo_runtime_validation_failed:primary_migrate_failed
primary query-migrate: failed, Received invalid message 0x0000 length 0x0000
secondary log: Can't receive COLO message: Input/output error
primary log: filter mirror send failed(Operation not permitted)
```

The failure is now in the COLO channel attach contract before primary migration convergence, not in Cloud VM or volume lifecycle.

## QEMU COLO Contract

The QEMU COLO procedure uses:

- primary `mirror0`: `server=on,wait=off`
- primary `compare1`: `server=on,wait=on`
- secondary `red0`: connects to primary `mirror0`
- secondary `red1`: connects to primary `compare1`
- primary `migrate` starts after the secondary QMP/NBD side is prepared.

The previous primary-first fix changed both primary peer-facing chardevs to `wait=off`. That avoided the startup deadlock, but allowed qemu FTCTL to continue toward QMP migration without using QEMU's documented compare-channel attachment guard.

## Revised Startup Model

For cloud-managed primary-first cold conversion:

1. Generated primary XML keeps `-S`.
2. Primary `mirror0` defaults to `wait=off`.
3. Primary `compare1` defaults to `wait=on`.
4. qemu FTCTL starts primary asynchronously.
5. qemu FTCTL waits for the primary mirror listener. When `compare1=wait=on`, it does not require primary create to finish before secondary startup.
6. qemu FTCTL starts the generated secondary.
7. qemu FTCTL verifies both primary peer-facing ports are `ESTAB` before QMP migration:
   - mirror port, default `9003`
   - compare port, default `9004`
8. qemu FTCTL waits for primary create to finish successfully.
9. qemu FTCTL runs the QMP COLO/NBD handshake and primary `migrate`.

## Configuration

- `FTCTL_XCOLO_MIRROR_WAIT` defaults to `off`.
- `FTCTL_XCOLO_COMPARE_WAIT` defaults to `on`.
- Invalid mirror values fall back to `off`.
- Invalid compare values fall back to `on`.
- `FTCTL_XCOLO_CHANNEL_CONNECT_TIMEOUT_SEC` controls post-secondary channel attach wait. If unset, the domain create timeout is used.

## Failure Behavior

If the peer channels do not become established after secondary startup:

- set `last_error=xcolo_channel_attach_timeout`;
- leave `protection_state=error`;
- leave `transport_state=failed`;
- emit `primary.create_generated.channel_attach result=fail`;
- return failure to Cloud so cleanup is required before retest.

Runtime validation still owns terminal migration failures such as:

```text
xcolo_runtime_validation_failed:primary_migrate_failed
```

If channel attach succeeds but the primary network filter emits before qemu FTCTL completes QMP graph setup, apply [305. FT X-COLO Deferred Primary Filter Attach Design](305-ft-xcolo-deferred-primary-filter-attach-design-20260528.md).

## Test Coverage

Selftest coverage must assert:

- primary generated XML uses `mirror0 ... wait=off`;
- primary generated XML uses `compare1 ... wait=on`;
- primary generated XML no longer defaults `compare1` to `wait=off`;
- channel attach is verified before primary QMP migration starts.
