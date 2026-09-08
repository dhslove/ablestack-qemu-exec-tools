# FT XCOLO Stable RBD Contract And Listener Bootstrap Design - 2026-06-05

## Problem

Run 80 repeated a COLO setup failure after the topology and firewall checks had
already passed:

- primary `mirror0=present_closed`
- primary `compare1=present_open`
- secondary `red0=present_open`
- secondary `red1=present_closed`
- secondary QEMU logged that `red1` could not connect to the primary compare
  listener.

The same run also showed RBD lifecycle noise during the conversion stop/start
window. ABLESTACK qemu hooks intentionally unmap RBD paths when a VM is released
or shut down, so FTCTL must not assume that a stable RBD path remains mapped
across the whole cold-conversion sequence.

## Hard Principles

1. FT cloud-managed RBD XML must use the ABLESTACK stable path:
   `/dev/rbd/<pool>/<image>`.
2. FTCTL must never rewrite generated primary or secondary XML to `/dev/rbdN`.
3. A resolved `/dev/rbdN` device may be recorded only as diagnostics.
4. If FTCTL maps a Cloud-created RBD image for runtime, it must verify that the
   stable path exists as a block device before starting QEMU.
5. Cloud remains responsible for VM, volume, and image lifecycle. qemu FTCTL may
   only prepare runtime mappings and run COLO actions.

## Runtime RBD Contract

FTCTL must re-establish and verify stable RBD paths at every conversion boundary
where qemu hooks or rollback may have changed the device map:

1. after primary shutdown/release
2. before generated primary create
3. before generated secondary create
4. before migrate

For each disk in `xcolo_disk_plan`:

- primary KRBD source is mapped locally through the stable path if needed
- secondary KRBD destination is mapped on the secondary host if needed
- the generated XML remains unchanged and continues to reference the stable path
- state records both the stable path and the resolved device:

```text
xcolo_secondary_runtime_rbd_<target>=<stable-path>|<resolved-device>|<mapped-by-ftctl>
xcolo_secondary_runtime_rbd_stable_<target>=<stable-path>
xcolo_secondary_runtime_rbd_resolved_<target>=<resolved-device>
```

Failure classification:

```text
last_error=xcolo_rbd_stable_path_unmapped
xcolo_protocol_failure_phase=rbd_stable_path_contract
xcolo_<phase>_rbd_contract_ready=no
xcolo_<phase>_rbd_contract_reason=<primary-or-secondary-disk-reason>
```

## Listener Bootstrap

The QEMU COLO sample requires both the mirror path and compare path, but the
ordering matters when listeners use `wait=on`.

Run 80 showed that primary `mirror0` can block early enough that the primary
`compare1` listener is not reliably available before the secondary tries to
connect `red1`. To avoid that startup race:

1. generated primary commandline emits `compare1` before `mirror0`
2. primary listener wait treats `compare1` as the bootstrap listener when both
   compare and mirror wait are enabled
3. secondary can connect `red1` first
4. primary can then continue to `mirror0`, where secondary `red0` completes the
   mirror path
5. migrate is still executed only after the documented frontend/channel checks
   pass

This keeps the QEMU document topology active from startup while avoiding the
previous mirror-first bootstrap race.

## Block Graph Busy Classification

If a QMP command returns a message such as:

```text
Node '<node>' is busy
```

FTCTL records it separately from COLO protocol-invalid-message failures:

```text
last_error=xcolo_block_graph_busy
xcolo_protocol_failure_phase=block_graph_busy
xcolo_block_graph_busy=yes
xcolo_block_graph_busy_event=<qmp-event>
xcolo_block_graph_busy_desc=<qmp-error-desc>
```

This prevents the validation loop from repeatedly misclassifying block graph
lifetime problems as network/chardev protocol problems.

## Test Progress Control

When a future run again reports:

```text
Primary QEMU: Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```

the report must include:

1. whether the stable RBD contract passed at all four phases
2. whether primary `compare1` was the bootstrap listener
3. whether `mirror0/red0` and `compare1/red1` were open before migrate
4. whether the failure was a block graph busy event or a real COLO protocol
   frame failure

If the same classification repeats twice with the same phase and state, stop
changing adjacent startup guesses and report the repeated loop explicitly.
