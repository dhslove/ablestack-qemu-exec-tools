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

Later validation also found a generated-primary listener startup deadlock: the primary-first cold conversion path emitted `mirror0` and `compare1` with `wait=on`, so `virsh create` waited for a secondary connection before the secondary was started. That contract is handled by [303. FT X-COLO Primary-First Listener Wait Design](303-ft-xcolo-primary-first-listener-wait-design-20260528.md).

Later validation progressed beyond listener startup and failed after secondary startup with primary migration status `failed` and QEMU reporting `Received invalid message 0x0000 length 0x0000`. That contract is handled by [304. FT X-COLO Channel Attach Before Migrate Design](304-ft-xcolo-channel-attach-before-migrate-design-20260528.md). The supported startup model now follows QEMU's documented split: `mirror0 wait=off`, `compare1 wait=on`, and a post-secondary `ESTAB` channel attach check before QMP migration.

Later validation proved both peer-facing channels were established, then failed because primary `filter-mirror` emitted before qemu FTCTL completed the QMP disk graph and migration setup. That contract is handled by [305. FT X-COLO Deferred Primary Filter Attach Design](305-ft-xcolo-deferred-primary-filter-attach-design-20260528.md). In cloud-managed cold conversion, primary network filter objects are now attached with QMP after the block graph is ready, not through generated XML startup.

Later validation progressed through deferred primary filter attach and failed at COLO migration because only the root disk was in the COLO graph while the data disk remained outside replication. That contract is handled by [306. FT X-COLO Multi Writable Disk Graph Design](306-ft-xcolo-multi-writable-disk-graph-design-20260528.md). FT success requires every writable guest disk to be represented in the COLO graph before primary migration starts.

Later validation with `i-2-54-VM` and `i-2-80-VM` progressed past multi-disk graph setup but remained stuck with:

- primary `query-status.status=finish-migrate`, `running=false`
- primary `query-migrate.status=active`
- secondary `query-status.status=inmigrate`, `running=false`
- secondary `query-migrate.status=colo`
- state `protection_state=pairing`, `transport_state=establishing`, `conversion_state=pending`

This state is not a successful FT state. It is a runtime convergence deadlock: the secondary has entered COLO receive mode, but the primary never resumes as the active service.

## Design Principles

1. Do not weaken the Cloud-managed ownership boundary.
   - Cloud creates and owns the primary/secondary VM and volume lifecycle.
   - qemu FTCTL owns COLO runtime conversion, QMP graph changes, and runtime validation.
2. Do not mark FT protection successful until runtime state proves both sides are valid.
3. Prefer deterministic failure reasons over broad `Stream closed` or generic `failed`.
4. Preserve the existing HA/DR behavior. This change is scoped to FT x-colo.
5. A protection attempt must not leave the service VM paused indefinitely. If runtime convergence is stuck, qemu FTCTL must fail the attempt and restore the primary from the saved pre-conversion XML.
6. Cleanup must remain explicit after a failed cold conversion because both primary and secondary runtime domains may be partially active.

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

Pending convergence is allowed only as a bounded asynchronous state. qemu FTCTL records `xcolo_runtime_pending_since` the first time the pair is classified as `runtime_converging`.

If the following state persists longer than `FTCTL_XCOLO_RUNTIME_PENDING_MAX_SEC`, default 180 seconds, qemu FTCTL must mark the attempt failed with `runtime_convergence_timeout`:

- primary runtime XML markers are present
- secondary runtime XML markers are present
- primary `query-status.status=finish-migrate`
- secondary `query-status.status=inmigrate`
- primary `query-migrate.status=active`
- secondary `query-migrate.status=colo`

This exact combination means the generated runtime domains and channels exist, but the active service was not released back to running state. It must not be treated as a stable FT wait condition.

## Runtime Failure Recovery

When runtime validation fails after generated domains have been started, qemu FTCTL must perform bounded recovery:

1. Destroy/deactivate the secondary runtime domain.
2. Destroy the generated primary runtime domain if it is still present.
3. Recreate or start the primary from `primary_xml_backup`.
4. Persist:
   - `conversion_stage=runtime_validation_failed`
   - `conversion_state=error`
   - `protection_state=error`
   - `transport_state=failed`
   - `active_side=primary`
   - `last_error=xcolo_runtime_validation_failed:<reason>`

If primary restoration fails, qemu FTCTL must keep `protection_state=error`, set `conversion_stage=runtime_recover_failed`, and surface `primary_restore_failed` in `last_error`.

## COLO Channel Startup Guard

For Cloud-managed cold conversion, qemu FTCTL starts the generated primary domain first and lets QEMU open the primary-side COLO sockets. qemu FTCTL checks those listener sockets passively with local socket inventory such as `ss -ltn`; it must not use TCP connect probes because a probe can consume a COLO chardev connection.

After the primary listeners are visible, qemu FTCTL starts the generated secondary domain. The secondary then connects its redirector chardevs to the waiting primary sockets and allows the primary `virsh create` call to complete.

This startup path uses a separate domain-create timeout, `FTCTL_XCOLO_DOMAIN_CREATE_TIMEOUT_SEC`, default 45 seconds. `FTCTL_XCOLO_QMP_TIMEOUT_SEC` remains a short QMP command timeout and must not be reused for `virsh create` calls that intentionally block during COLO socket attachment.

The primary generated XML must allow QEMU startup to complete before the secondary exists. The service is still kept paused with `-S`, so guest execution and packet flow are not released before the subsequent QMP/migration sequence.

Therefore the primary generated qemu commandline uses:

- `mirror0 ... server=on,wait=off` by default
- `compare1 ... server=on,wait=on`
- loopback compare sockets unchanged
- no primary `filter-mirror`, `filter-redirector`, or `colo-compare` objects at XML startup

The wait behavior is configurable with `FTCTL_XCOLO_MIRROR_WAIT` and `FTCTL_XCOLO_COMPARE_WAIT`. Invalid mirror values fall back to `off`; invalid compare values fall back to `on`.

Because `compare1 wait=on` can keep the primary create process blocked until the secondary connects, qemu FTCTL must not wait for both peer ports before starting the secondary. It waits for the primary mirror listener, starts the secondary, verifies both peer-facing channels are `ESTAB`, then runs QMP migration.

Before QMP migration, qemu FTCTL attaches the primary network filter objects with QMP `object-add`, with `filter-mirror` last.

Before attaching primary network filters, qemu FTCTL must attach the block graph for all mapped writable disks, not only the first/root disk.

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
- If the failure occurs after generated runtime domains started, qemu FTCTL attempts to restore the original primary service domain from the saved XML.
- Cloud persists the failure and releases the Cloud-managed lifecycle guard.
- Operator cleanup can safely remove the partial standby VM, FTCTL state files, and blockcopy runtime directory before retest.

## Test Coverage

New selftest coverage:

- Runtime validation blocks false-positive success when the primary is not running.
- Runtime validation reports terminal primary migration failure as `primary_migrate_failed`.
- Runtime validation times out a stuck `finish-migrate` / `inmigrate` convergence as `runtime_convergence_timeout`.
- Generated primary XML defaults `mirror0` to `wait=off` and `compare1` to `wait=on`.
- Channel attach is verified before primary QMP migration starts.
- Primary network filter objects are attached by QMP after block graph preparation.
- Every mapped writable disk is attached to a COLO block graph before primary migration.
