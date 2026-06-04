# FT XCOLO Filter-Mirror EPERM Diagnostics Design - 2026-06-04

## Background

Run 75 reached farther than the previous topology checks:

- the premigrate-active primary filter topology was installed
- the combined topology audit returned `xcolo_topology_audit=ok`
- primary and secondary QEMU command lines were captured
- the 9003/9004/9998 TCP paths were observable

The run still failed in the post-migrate startup-active filter validation phase:

```text
Primary QEMU:   filter mirror send failed(Operation not permitted)
Primary QEMU:   Received invalid message 0x0000 length 0x0000
Secondary QEMU: Can't receive COLO message: Input/output error
```

This is a different diagnostic focus from design 351. The topology can be
syntactically correct while QEMU still fails when the primary `filter-mirror`
tries to write guest TX packets to the mirror chardev.

## Current Evidence

The SELinux hypothesis was checked and is not the primary explanation for Run
75:

- SELinux was enabled but running in `Permissive` mode on the involved hosts.
- No matching AVC denial was found for the failure window.
- The COLO paths under test are TCP chardevs, not Unix socket files.

Firewall state must still remain part of the evidence because Linux socket send
can surface policy problems as `EPERM`. However, the observed host firewall
rules allowed the FT ports and packet counters existed for the relevant ports.

## Principle

Do not collapse `filter mirror send failed(Operation not permitted)` into the
generic invalid-message bucket. It is an earlier and more specific failure in
the QEMU network mirror write path:

```text
primary guest TX -> filter-mirror m0 -> mirror0 -> secondary red0
```

The next code must preserve the exact failure before returning from the
post-migrate startup-active validation path. If this signature repeats, the
system must report it as a repeated `filter-mirror` write-path failure, not as a
new timing or generic COLO protocol issue.

## Design

### Dedicated EPERM Classification

When post-migrate validation observes an invalid COLO message, inspect the
primary QEMU log tail immediately. If the latest relevant QEMU log contains
`filter mirror send failed(Operation not permitted)`, persist:

- `last_error=xcolo_filter_mirror_send_eperm`
- `xcolo_filter_mirror_send_failed=yes`
- `xcolo_filter_mirror_send_errno=eperm`
- `xcolo_filter_mirror_send_path=primary:m0->mirror0->secondary:red0`
- `xcolo_protocol_invalid_message_reason=filter_mirror_send_eperm`
- `xcolo_protocol_failure_phase=post_migrate_startup_active_filter`

If the mirror send failure is present with another errno, persist the errno as
`xcolo_filter_mirror_send_errno=<normalized-errno>` and use:

- `last_error=xcolo_filter_mirror_send_failed`
- `xcolo_protocol_invalid_message_reason=filter_mirror_send_failed`

### Failure-Time Evidence

Before returning failure from the startup-active validation path, collect:

- primary and secondary QEMU log tails
- primary and secondary QEMU command lines
- primary and secondary QMP snapshots
- primary and secondary `query-chardev` snapshots
- primary and secondary socket snapshots for the failure phase
- SELinux/firewall/audit counters as a diagnostic snapshot

The debug files remain under:

```text
${FTCTL_RUN_DIR}/debug/xcolo/<vm-key>
```

New or strengthened files:

- `primary-query-chardev-post-migrate-failure.json`
- `secondary-query-chardev-post-migrate-failure.json`
- `primary-policy-post-migrate-failure.txt`
- `secondary-policy-post-migrate-failure.txt`

### Chardev Readiness Fields

Persist coarse readiness state for the chardev path that failed:

- `xcolo_failure_primary_chardev_mirror0=<present|missing|unknown>`
- `xcolo_failure_primary_chardev_compare1=<present|missing|unknown>`
- `xcolo_failure_secondary_chardev_red0=<present|missing|unknown>`
- `xcolo_failure_secondary_chardev_red1=<present|missing|unknown>`

This does not replace packet-level tracing. It prevents another run from losing
whether QEMU saw the expected chardevs at the failure point.

### Repetition Gate

The progress document must record this as the repeated signature:

```text
filter mirror send failed(Operation not permitted)
Received invalid message 0x0000 length 0x0000
Can't receive COLO message: Input/output error
```

If the next run produces the same signature with topology audit `ok`, the next
change must target one of:

- QEMU chardev peer lifecycle around `mirror0`/`red0`
- host firewall or kernel socket policy at send time
- secondary receive state around incoming migration and redirection filters

It must not return to checkpoint-delay, storage type, or post-migrate dormant
filter activation timing unless new evidence contradicts the Run 75 record.

## Expected Retest Result

The next retest is useful if it produces one of these outcomes:

- FT reaches steady state.
- The attempt fails with `xcolo_filter_mirror_send_eperm` and full chardev,
  socket, policy, and QEMU log evidence.
- The attempt fails earlier with a concrete chardev/socket readiness reason such
  as `xcolo_colo_chardev_peer_not_ready`.

Generic `xcolo_startup_active_filter_stream_failed` without the EPERM
subclassification is no longer acceptable for this failure class.
