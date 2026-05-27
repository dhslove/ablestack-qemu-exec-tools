# FT Cloud-Managed X-COLO Runtime Convergence Guard Design

## Background

During FT validation for `r97-link-01`, Cloud-managed registration created the standby VM and qemu FTCTL executed the block-backed cold conversion flow, but runtime convergence failed after QMP handshake.

Observed evidence:

- Primary VM: `i-2-54-VM` on `ablecube32-3`
- Secondary VM: `i-2-64-VM` on `ablecube32-1`
- Protection row: `protection_state=error`, `transport_state=failed`
- qemu state: `conversion_stage=runtime_validation_failed`
- Runtime validation: `secondary_not_running`, then primary migration moved to `failed`
- Primary qemu log: `filter mirror send failed(Operation not permitted)` and `Received invalid message 0x0000 length 0x0000`
- Secondary qemu log: initial COLO channel connection refused, then `Can't receive COLO message`

This confirms the Cloud lifecycle guard is working: the system no longer reports `colo_running/mirroring` when COLO did not converge. The remaining fault is in qemu FTCTL's COLO channel convergence and post-handshake validation window.

Later validation found an earlier generated-primary failure class where libvirt rejected a raw `qemu:commandline` iothread before the COLO handshake could start. That contract is handled separately by [301. FT X-COLO Libvirt Iothread Contract Design](301-ft-xcolo-libvirt-iothread-contract-design-20260527.md). When a run fails at `primary.create_generated`, apply the 301 contract first; this runtime convergence document applies only after both generated domains are accepted and QMP handshake is attempted.

## Design Principles

1. Do not weaken the Cloud-managed ownership boundary.
   - Cloud creates and owns the primary/secondary VM and volume lifecycle.
   - qemu FTCTL owns COLO runtime conversion, QMP graph changes, and runtime validation.
2. Do not mark FT protection successful until runtime state proves both sides are valid.
3. Prefer deterministic failure reasons over broad `Stream closed` or generic `failed`.
4. Preserve the existing HA/DR behavior. This change is scoped to FT x-colo.
5. Cleanup must remain explicit after a failed cold conversion because both primary and secondary runtime domains may be partially active.

## Runtime Convergence Model

After QMP handshake returns success, qemu FTCTL must treat COLO as a converging state, not an immediate success or immediate failure.

Validation loop:

1. Poll primary and secondary QMP status.
2. Poll primary and secondary `query-migrate`.
3. Confirm primary and secondary runtime XML contain expected COLO commandline markers.
4. Succeed only when:
   - primary `query-status.running=true`
   - secondary `query-status.running=true`
   - primary runtime XML has `colo-compare`, `filter-mirror`, and `filter-redirector`
   - secondary runtime XML has `filter-redirector`, `filter-rewriter`, and `-incoming`
   - secondary `query-migrate.status=colo`
5. Fail immediately on terminal migration failure:
   - primary `query-migrate.status=failed` -> `primary_migrate_failed`
   - secondary `query-migrate.status=failed` -> `secondary_migrate_failed`
6. Otherwise continue polling up to `FTCTL_XCOLO_RUNTIME_VALIDATE_TIMEOUT_SEC`, default 45 seconds.

## COLO Channel Startup Guard

For Cloud-managed cold conversion, the secondary VM is started first and reconnects to primary-side COLO sockets. The primary generated XML must not allow guest packets to reach `filter-mirror` before the secondary redirector has connected.

Therefore the primary generated qemu commandline uses:

- `mirror0 ... server=on,wait=on` by default
- `compare1 ... server=on,wait=on`
- loopback compare sockets unchanged

The wait behavior is configurable with `FTCTL_XCOLO_MIRROR_WAIT`, but invalid values fall back to `on`.

## Expected Behavior

Successful registration:

- qemu FTCTL waits until the pair converges.
- `protection_state=colo_running`
- `transport_state=mirroring`
- `xcolo.runtime_validate` event result is `ok`

Failed registration:

- qemu FTCTL leaves `protection_state=error`
- qemu FTCTL leaves `transport_state=failed`
- `last_error=xcolo_runtime_validation_failed:<reason>`
- Cloud persists the failure and releases the Cloud-managed lifecycle guard.
- Operator cleanup can safely remove the partial standby VM, FTCTL state files, and blockcopy runtime directory before retest.

## Test Coverage

New selftest coverage:

- Runtime validation blocks false-positive success when the primary is not running.
- Runtime validation reports terminal primary migration failure as `primary_migrate_failed`.
- Generated primary XML defaults `mirror0` to `wait=on`.
