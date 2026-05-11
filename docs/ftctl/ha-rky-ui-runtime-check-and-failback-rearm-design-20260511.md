# HA-RKY UI Runtime Check And Failback Rearm Design - 2026-05-11

## Background

The HA-RKY UI flow exposed two related problems after the recent FTCTL UI hardening.

1. After manual fence release, the Failback action was available, but the runtime later moved to `rearm_exhausted`.
2. The FTCTL tab showed VM runtime state in both the summary section and the protection detail section, while the Check and Health sections showed stale fallback values such as `not_available`, `unknown`, or `-`.

The intended ownership rule remains unchanged:

- Cloud UI displays Cloud DB state and server-supplied FTCTL runtime information.
- Cloud UI does not call host-side libvirt or the FTCTL engine directly.
- Mold Agent forwards commands or event-read requests to the qemu-side FTCTL runtime.
- qemu-side FTCTL owns actual runtime work and writes transient runtime events to `events.log`.
- Cloud should not duplicate transient qemu events into Cloud DB when it can read the existing qemu event stream.

## Findings

### Failback and Auto Rearm Collision

The valid manual HA failback sequence is:

1. Manual fence release.
2. Cloud-managed failback start, which sends `FAILBACK_SYNC` to qemu FTCTL.
3. Reverse sync progresses.
4. Cloud stops the secondary VM, finalizes failback, starts the primary VM, and reprotects.

After manual fence release, qemu FTCTL can observe:

- `provisioning_backend=cloud-managed`
- `mode=ha`
- `active_side=secondary`
- `protection_state=failed_over`
- `transport_state=failed_over`
- `fencing_state=clear`

That state means "the fenced primary side has been administratively released and Cloud may now start failback." It must not mean "qemu FTCTL should auto-rearm the forward blockcopy path."

When reconcile treats that state as a normal transport issue, it can run the auto-rearm path while the primary VM domain is still absent on the primary host. The observed event stream then becomes:

- `inventory.check` with `primary_domain_state=not-found`
- `inventory.disks` failure on the primary URI
- repeated `rearm.exhausted`

This hides the real workflow state and prevents a clean cloud-managed failback.

### UI Summary Duplication

The FTCTL tab currently shows `Primary VM` and `Secondary VM` in the top summary and again in Protection Details.

The top summary should be a compact protection summary, not a VM runtime inventory panel. VM state should remain in:

- Protection Details: Cloud DB and Cloud-managed VM view.
- Check: qemu FTCTL runtime inventory view.

### Check And Health Missing Data

`getFtctlCheck` and `getFtctlHealth` currently read only Cloud DB details such as:

- `ftctl.check.result`
- `ftctl.check.inventory.result`
- `ftctl.check.primary.rc`
- `ftctl.check.peer.rc`
- `ftctl.health.result`
- `ftctl.health.rc`

Those DB detail keys are not the source of truth for transient qemu runtime checks. qemu FTCTL already writes the current information to `events.log` as JSON events, especially:

- `inventory.check`
- `inventory.disks`
- `health/libvirt.local`
- `health/reconcile.tick`

The Cloud backend must derive Check and Health responses from the latest qemu events when event data is available, and only use DB details as fallback.

## Design

### qemu FTCTL

Add a reconcile guard for cloud-managed HA after manual fence release:

```text
if provisioning_backend == cloud-managed
and mode == ha
and active_side == secondary
and protection_state == failed_over
and transport_state == failed_over
and fencing_state in [clear, cleared]
then:
  do not run inventory-driven auto-rearm
  do not increment rearm_count
  do not change state to rearm_exhausted
  log failback.await-command
  wait for Cloud to send FAILBACK_SYNC
```

Also include the VM name on health events emitted during reconcile so Cloud can read those events through the VM-scoped event API.

### Cloud Backend

Update `getFtctlCheck`:

- Fetch latest qemu FTCTL events through Mold Agent.
- Parse the latest `inventory.check` event.
- Parse the latest `inventory.disks` event.
- Populate:
  - `result`
  - `inventoryresult`
  - `primaryrc`
  - `peerrc`
  - `primarydomainstate`
  - `standbydomainstate`
  - `peerdomainexpected`
- Fall back to existing DB detail values only when events are not available.

Update `getFtctlHealth`:

- Fetch latest qemu FTCTL events through Mold Agent.
- Parse the latest `libvirt.local` health event.
- Populate:
  - `result`
  - `uri`
  - `rc`
- Fall back to existing DB detail values only when events are not available.

Do not persist these transient check/health values into Cloud DB.

### Cloud UI

Change the FTCTL tab as follows:

- Remove `Primary VM` and `Secondary VM` from the top summary section.
- Keep VM state in Protection Details.
- Show runtime execution state in Check using qemu event-derived values:
  - Primary/basic execution state from `primarydomainstate` or `primaryrc`
  - Peer execution state from `standbydomainstate` or `peerrc`
- Keep Health as the host/libvirt health view.
- Continue async refresh without section flicker.

## Acceptance Criteria

- After fence release, qemu FTCTL does not auto-rearm in the cloud-managed HA failback-ready state.
- `rearm_count` does not increase while waiting for `FAILBACK_SYNC`.
- `events.log` includes `failback.await-command`.
- `getFtctlCheck` shows current inventory/runtime state from qemu events.
- `getFtctlHealth` shows current health state from qemu events when available.
- The top UI summary no longer duplicates VM state.
- Protection Details still shows primary and secondary VM state.
- Check still shows runtime execution state without relying on stale Cloud DB detail keys.
