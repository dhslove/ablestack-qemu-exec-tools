# HA-WIN-13 standby verify state cleanup design - 2026-05-08

## Background

`HA-WIN-13-FAILBACK-CONSISTENCY` passed functionally after cloud-managed failback, but runtime status still exposed:

```json
"standby_verify_state": "running-network-unknown"
```

The actual post-failback state was:

- `active_side=primary`
- `protection_state=protected`
- `transport_state=mirroring`
- `fencing_state=clear`
- Cloud standby VM stopped
- Peer standby domain not defined, as expected for cloud-managed transient standby
- No split-brain
- No reverse NBD leftover

## Root Cause

`standby_verify_state` is written by standby boot verification during failover:

- `running-network-ok`
- `running-network-unknown`
- `failed`

The cloud-managed failback path updates the main role and transport state, but it does not reset `standby_verify_state`.

Runtime status emits every key in the VM state file, so the old failover-era value remains visible after failback even though standby is no longer supposed to be running.

## Design

For cloud-managed failback reprotect:

1. After failback returns active ownership to the primary, mark the standby verification state as not expected:

   ```text
   standby_state=prepared-transient
   standby_verify_state=not-defined-expected
   standby_domain_state=not-defined-expected
   peer_domain_expected=false
   ```

2. Apply the same cleanup if `failback-reprotect` is called idempotently while the VM is already `protected/mirroring`.

3. Keep the value explicit instead of removing it. Operators can then distinguish between:

   - `running-network-*`: failover-side standby verification result
   - `not-defined-expected`: post-failback cloud-managed transient standby state

## Pass Criteria

- After cloud-managed failback, `ablestack_vm_ftctl status --json` must not expose stale `standby_verify_state=running-*`.
- Expected post-failback value is `standby_verify_state=not-defined-expected`.
- Existing failover-side steady-state behavior remains unchanged.

## Validation

Add selftest coverage for:

- stale `standby_verify_state=running-network-unknown` before `failback-reprotect`
- successful `failback-reprotect`
- resulting `standby_verify_state=not-defined-expected`
- idempotent `failback-reprotect` cleanup when state is already `protected/mirroring`
