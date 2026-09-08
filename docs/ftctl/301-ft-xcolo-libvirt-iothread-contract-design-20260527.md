# FT X-COLO Libvirt Iothread Contract Design

## Background

During FT validation for `r97-link-01`, Cloud-managed registration failed before the COLO QMP handshake. The primary generated domain failed at `primary.create_generated` and Cloud reported a generic `Stream closed` error.

Observed host evidence showed libvirt rejected the generated primary runtime:

- `primary.create_generated` returned `rc=143`.
- libvirt logged `got wrong number of IOThread pids from QEMU monitor. got 1, wanted 0`.
- The generated primary XML injected `-object iothread,id=iothread1` through `qemu:commandline`.
- The native libvirt domain XML did not declare any `<iothreads>` or `<iothreadids>`.

This failure occurred before migration, block graph attach, or runtime convergence validation. It is not the same failure class as the COLO startup ordering and runtime convergence guard described in [300. FT Cloud-Managed X-COLO Runtime Convergence Guard Design](300-ft-cloud-managed-xcolo-runtime-convergence-design-20260527.md).

## FT Goal Constraint

FT mode must preserve the service identity of the primary VM. The secondary is not a newly booted HA standby; it is a COLO replica that must be able to take over the same guest identity, including memory checkpoint state, disks, MAC/IP identity, and service role.

Therefore, implementation fixes must move the pair toward a valid COLO replica state and must not redefine FT success as simple standby VM creation.

## Design Principles

1. Cloud continues to own Cloud-managed VM and volume lifecycle.
2. qemu FTCTL owns generated runtime XML, QMP graph changes, COLO handshake, and runtime validation.
3. qemu commandline extensions must not create opaque QEMU resources that libvirt also needs to account for.
4. Failed cold conversion must restore the primary runtime and stop the partial secondary runtime where possible, without deleting Cloud-owned VM or volume records.
5. FT registration must fail before primary shutdown when generated XML violates the libvirt/QEMU contract.

## Iothread Contract

The primary COLO compare object still uses `iothread=iothread1`, but FTCTL must not create that iothread with raw `qemu:commandline`.
After the deferred primary filter attach change, the compare object is attached through QMP rather than being present in the generated primary XML command line. The native libvirt iothread contract still applies because QMP `object-add` references `iothread1`.

Instead:

1. The generated primary XML declares native libvirt iothread state:
   - `<iothreads>1</iothreads>`
   - `<iothreadids><iothread id="1"/></iothreadids>`
2. The qemu commandline omits `-object iothread,id=iothread1`.
3. The generated primary qemu commandline does not include `colo-compare`; qemu FTCTL attaches `colo-compare ... iothread=iothread1` later through QMP after channel and block graph readiness.
4. Generated XML validation rejects:
   - any `qemu:arg` that creates `iothread,id=iothread...`
   - any generated XML `colo-compare` reference to `iothread=iothread1` without native libvirt iothread id `1`

This keeps libvirt's expected IOThread count aligned with QEMU monitor state.

## Failure Cleanup Model

For block-backed cold conversion, the observed failure happens after:

1. primary shutdown,
2. secondary runtime activation,
3. primary generated runtime creation attempt.

If primary generated runtime creation fails:

1. qemu FTCTL best-effort destroys only the secondary runtime domain.
2. qemu FTCTL best-effort starts or creates the primary from the backed-up Cloud XML.
3. qemu FTCTL marks state as:
   - `protection_state=error`
   - `transport_state=failed`
   - `active_side=primary`
   - `last_error=xcolo_block_primary_create_failed`
4. Cloud remains responsible for removing the Cloud-managed standby VM and volumes during explicit cleanup.

This avoids leaving the primary down while still respecting Cloud-managed resource ownership.

## Test Coverage

Selftest coverage must assert:

- generated primary XML contains native iothread id `1`;
- generated primary XML does not contain raw `iothread,id=iothread1`;
- generated primary XML does not contain primary filter objects;
- QMP object-add attaches `colo-compare` with `iothread1` after block graph readiness;
- explicit validation rejects opaque qemu commandline iothread creation.
