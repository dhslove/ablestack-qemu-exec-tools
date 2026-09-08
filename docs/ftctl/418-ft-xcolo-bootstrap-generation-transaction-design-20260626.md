# FT XCOLO Bootstrap Generation Transaction Design - 2026-06-26

## Problem

The `r97-link-02` FT experiment advanced past the previous
`compare_bootstrap` deadlock, but failed at the channel attach phase:

- primary generated QEMU reached `compare1` listener bootstrap;
- secondary generated QEMU was created and attempted `red1 -> compare1`;
- the first primary create later failed because a stable KRBD path was not
  visible to QEMU;
- FTCTL remapped KRBD and retried only the primary generated create;
- the secondary process still belonged to the previous bootstrap generation and
  kept stale `red0/red1` socket state;
- channel attach timed out with `mirror0` never established;
- rollback then failed to restore a libvirt runtime, leaving Cloud DB as
  `Running` while libvirt had no corresponding transient domain.

The current design treats primary generated create retry as a local primary
operation. For XCOLO startup this is not safe: primary listeners and secondary
redirection clients form one bootstrap generation.

## Principle

XCOLO startup must be handled as a generation-scoped transaction.

One generation includes:

1. KRBD path preparation for the primary generated XML.
2. Primary generated `virsh create`.
3. Primary listener bootstrap.
4. Secondary generated `virsh create`.
5. Primary/secondary socket channel attach.

If any step after primary listener bootstrap invalidates primary QEMU startup,
the whole generation must be torn down and recreated. Reusing a secondary from
an older generation is not allowed.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Primary create retry | KRBD `ENOENT` can trigger a primary-only retry. | Retry is generation-scoped: stale secondary is destroyed before retrying primary. |
| Listener bootstrap | `compare_bootstrap` is treated as enough to create secondary. | `compare_bootstrap` is recorded as partial bootstrap only; success still requires full channel attach. |
| Secondary lifecycle | Secondary may survive a primary retry and keep stale redirection sockets. | Secondary belongs to a specific generation and is destroyed on retry/failure before a new generation starts. |
| Channel attach timeout | Timeout records channel state but rollback may leave Cloud/libvirt mismatch. | Timeout captures channel state, tears down both generated domains, and restores primary runtime from original XML. |
| Rollback primary destroy | `virsh destroy` rc can stop restore even when the domain is already gone. | `domain not found` / `not running` in stdout or stderr is non-fatal; restore continues. |
| Runtime consistency | Cloud DB may show `Running` while libvirt has no transient VM. | Rollback verifies restored primary `domstate`; mismatch is recorded as a hard restore failure. |

## Implementation Plan

### 1. Generation teardown helper

Add `ftctl_xcolo_teardown_bootstrap_generation(vm, handle, secondary_vm, reason)`.

It must:

- abort the in-flight primary generated create handle;
- destroy the primary generated domain if it exists;
- destroy/deactivate the secondary generated domain;
- unmap secondary runtime RBD if present;
- record generation teardown evidence in state and `events.log`.

The helper must not restore the original primary XML. It only tears down the
current generated generation so the caller can retry or enter final rollback.

### 2. Generation retry wrapper

Add a small bounded retry around:

- `ftctl_xcolo_start_primary_generated_async`;
- `ftctl_xcolo_wait_primary_generated_listeners`;
- `ftctl_standby_activate`;
- `ftctl_xcolo_wait_primary_peer_connections`.

Default retry count should be conservative: `2` attempts total. This handles
the observed KRBD visibility race without hiding persistent protocol problems.

On retry:

- increment `xcolo_bootstrap_generation`;
- call generation teardown;
- re-run KRBD stable path preparation through primary generated create;
- create a fresh secondary after the new primary listener bootstrap.

### 3. Channel failure classification

Enhance `ftctl_xcolo_wait_primary_peer_connections` to store:

- `xcolo_channel_attach_failure_reason`;
- `xcolo_channel_mirror_established`;
- `xcolo_channel_compare_established`;
- `xcolo_channel_mirror_listen`;
- `xcolo_channel_compare_listen`;
- primary create rc and compact stderr if the primary create process exited.

The reason should distinguish at least:

- `primary_create_exited_before_channel_attach`;
- `mirror_channel_not_established`;
- `compare_channel_not_established`;
- `channel_attach_timeout`.

### 4. Rollback restore hardening

Modify `ftctl_xcolo_force_primary_restore_from_backup`:

- normalize `out + err` when deciding whether `virsh destroy` failure means
  "already gone";
- do not stop restore when the generated primary domain is already absent;
- after `ftctl_primary_activate_from_backup`, verify `domstate`;
- set `cloud_runtime_restore=primary_running` only when libvirt confirms a
  running/paused/pmsuspended state.

## Success Criteria

For the next failed retest, if protocol attach still fails:

- primary original runtime is restored in libvirt;
- secondary generated runtime is destroyed;
- Cloud/libvirt mismatch is not left behind silently;
- state clearly says why channel attach failed.

For a passing retest:

- `xcolo_bootstrap_generation` reaches a stable generation;
- `channels_attached` is reached only after `mirror0` and `compare1` are both
  established;
- migration can start from a fresh primary/secondary generation pair.
