# FT XCOLO Bootstrap State Machine Restore Design

Date: 2026-06-26

## Problem

The `r97-link-02` RBD to qcow2 FT experiment reproduced a failure that had already appeared in older XCOLO attempts:

- the primary generated QEMU process starts;
- `compare1` is declared before `mirror0` and uses `server=on,wait=on`;
- QEMU blocks at `compare1` until the secondary connects;
- the newer hard gate waits for both `compare1` and `mirror0` to be in `LISTEN`;
- `mirror0` can never be created because QEMU is still blocked at `compare1`;
- secondary is never started, primary remains paused, and rollback is interrupted by an unbound `create_error` variable.

The successful `r97-link-01` RBD to RBD state proves the intended bootstrap order. It accepted `compare_bootstrap` as the first primary readiness gate, started the secondary, then let the secondary connect to `compare1` so primary QEMU could continue and expose `mirror0`.

The success path must be restored without reverting the current stable KRBD contract.

## Principles

- Keep the stable KRBD path contract. Primary generated QEMU must continue to use `/dev/rbd/rbd/<image>` for RBD disks, not `rbd:<pool>/<image>`.
- Reuse the `r97-link-01` success model only for COLO channel bootstrap ordering.
- Do not require `mirror0` to exist before the secondary is started when `compare1` appears first with `wait=on`.
- Do require both remote channels to be established before migration.
- Treat `virsh create` timeout, empty stderr, and QEMU listener timeout as first-class classified failures.
- Rollback must not leave a generated primary paused or a cloud-managed standby runtime running.

## Code-Level Design

| Area | AS-IS | TO-BE |
|---|---|---|
| Primary listener bootstrap | When `compare1` and `mirror0` both use `wait=on`, the listener gate requires both ports to be `LISTEN`. | Accept `compare_bootstrap` when `compare1` is `LISTEN`. Treat `listener_pair` as a fast path, not a mandatory gate. |
| Secondary start ordering | Secondary creation waits for the impossible `listener_pair` state. | Start secondary immediately after `compare_bootstrap`, so secondary `red1` can unblock primary QEMU and allow `mirror0` creation. |
| Channel attach gate | Channel attach only checks both ports established and reports generic timeout. | Track compare and mirror channel state separately. Require both established before migrate, but record which channel failed. |
| Timeout default | Primary generated `virsh create` defaults to 45 seconds. | Raise default to 180 seconds because COLO `wait=on` create intentionally spans secondary startup and channel attach. |
| Create error handling | Some paths reference `create_error` after a failed classifier assignment. | Initialize `create_error` before every classifier call and provide a timeout-specific fallback. |
| Failure evidence | Listener timeout and channel timeout can look similar. | Store `xcolo_bootstrap_phase`, listener reason, port state, socket snapshots, and QEMU log tails. |
| Rollback | A generated primary can remain paused if error handling aborts early. | Abort generated primary on listener/channel failure and run cloud-managed secondary cleanup without recreating standby. |

## Bootstrap State Machine

```text
primary original running
  -> shutdown for FT conversion
  -> create primary generated QEMU
  -> wait compare1 LISTEN
  -> start secondary generated QEMU
  -> wait compare channel ESTABLISHED
  -> wait mirror0 LISTEN
  -> wait mirror channel ESTABLISHED
  -> pre-migrate QMP/socket/topology gates
  -> migrate
  -> colo_running
```

`compare1 LISTEN` is a valid primary bootstrap point because it is the first blocking external COLO channel in the generated primary command line. `mirror0 LISTEN` is expected only after the secondary connects to `compare1`.

## Expected Result

The next `r97-link-02` run must no longer stop at primary listener wait while only `9104` is open. It should proceed to secondary creation after `compare_bootstrap`, then either:

- reach `channels_attached` and continue to migrate; or
- fail with explicit evidence that compare or mirror channel attach did not complete.

In either failure case, generated primary and standby runtime cleanup must leave Cloud DB and libvirt in a recoverable state for the next test.
