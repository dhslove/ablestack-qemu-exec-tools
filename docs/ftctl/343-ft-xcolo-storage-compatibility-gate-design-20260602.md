# FT XCOLO Storage Compatibility Gate Design - 2026-06-02

## Background

Run 63 proved that the FT XCOLO external network path is available:

- firewall service/ports were present on both primary and secondary hosts
- 9003/9004 data sockets were established
- 9001/9005 loopback compare sockets were present
- 10809 NBD was connected
- 9998 migration endpoint was listening on the secondary

Despite that, the same QEMU protocol failure repeated:

- primary: `Received invalid message 0x0000 length 0x0000`
- secondary: `Can't receive COLO message: Input/output error`

The remaining high-value difference is storage layout:

- primary disks: `block/raw`
- secondary disks: `file/qcow2`

For FT, the secondary is not a loose backup target. It must act as a runtime
clone with equivalent device semantics. Therefore the default FT XCOLO path must
require storage backend/format compatibility.

## Principle

FT XCOLO protection must select target storage that is compatible with the
primary disk backend and format.

Default allowed examples:

- `block/raw -> block/raw`
- `file/qcow2 -> file/qcow2`

Default blocked examples:

- `block/raw -> file/qcow2`
- `file/qcow2 -> block/raw`
- mixed multi-disk layouts where any disk differs

This is stricter than DR or HA block copy. DR/HA can tolerate backend conversion
because they primarily copy blocks and manage lifecycle transitions. FT XCOLO
depends on QEMU runtime replication and checkpoint protocol behavior, so the
runtime disk graph must be treated as a compatibility contract.

## Behavior

During FT cloud-managed protection:

1. Cloud may create the standby VM and pass an explicit disk map.
2. qemu FTCTL collects the primary disk plan.
3. qemu FTCTL records:
   - `xcolo_storage_primary_layouts`
   - `xcolo_storage_secondary_layouts`
   - `xcolo_storage_symmetry`
   - `xcolo_storage_symmetry_reason`
4. If `xcolo_storage_symmetry=warning`, qemu FTCTL stops before primary shutdown.
5. The state records:
   - `xcolo_storage_compatibility=blocked`
   - `xcolo_storage_mismatch_override=false`
   - `conversion_stage=storage_compatibility_failed`
   - `conversion_state=error`
   - `last_error=xcolo_storage_backend_mismatch`

## Experimental Override

An explicit override can be used only for investigation:

- `FTCTL_XCOLO_ALLOW_STORAGE_MISMATCH=1`

When enabled:

- qemu FTCTL records `xcolo_storage_compatibility=experimental`
- qemu FTCTL records `xcolo_storage_mismatch_override=true`
- the run is not considered a default FT compatibility pass

## Repeated Invalid Message Classification

Run 63 also showed that failure-time strict chardev state can become `no` after
QEMU has already failed migration. The repeated-message classifier must use
pre-migrate evidence instead.

Classify as `xcolo_repeated_protocol_invalid_message` when:

- primary migrate error contains `Received invalid message 0x0000 length 0x0000`
- `xcolo_premigrate_primary_filter_chardev_ready=yes`
- pre-migrate filter QOM or command-line evidence was ready
- pre-migrate channel evidence was ready
- secondary block graph was ready
- firewall was ready or not explicitly failed
- runtime socket evidence was captured or not required by the current path

This keeps the investigation from cycling through already-cleared filter,
firewall, and socket hypotheses.

## Next Test Expectation

For the current `r97-link-01` setup, selecting local filesystem/qcow2 secondary
storage should fail early with `xcolo_storage_backend_mismatch` before the
primary VM is shut down.

To continue FT XCOLO runtime validation, the next target storage must match the
primary layout, for example `block/raw -> block/raw`.
