# FT XCOLO Baseline Seed SSH Retry Design - 2026-06-02

## Background

Run 61 for `r97-link-01` validated that virtio net devices are detected and
`vnet_hdr_support` is required, but the run failed before COLO runtime
activation. The failure happened during cold baseline seeding of the second
disk:

- `sda` baseline seed completed.
- `sdb` NBD export started.
- remote `qemu-img convert` returned `rc=255`.
- the event payload contained `error=""`.
- both source and target hosts logged SSH `MaxStartups throttling` in the same
  time window.

This is a transport robustness problem in the baseline seed phase, not a COLO
filter or migration protocol failure.

## Goal

Make FT XCOLO baseline seed copy resilient to transient SSH transport loss and
make failures diagnosable when the transport still fails.

The change must not alter the COLO runtime topology, filter ordering,
`vnet_hdr_support` behavior, migration sequence, or HA/DR cloud-managed
ownership principles.

## Design Principles

- Keep the change local to baseline seed remote copy and shared remote-exec
  diagnostics.
- Treat SSH `rc=255` as transport failure, not as qemu-img copy failure.
- Retry only bounded transient transport failures.
- Do not hide deterministic copy failures such as missing target, size mismatch,
  or qemu-img format errors.
- Always remove stale file seed temporaries before retrying.
- Never log secrets such as passwords, API keys, or private key contents.
- Preserve clear test progress markers so repeated failures can be detected.

## Failure Classification

The baseline seed path records one of these error classes:

- `xcolo_baseline_seed_ssh_failed:<target>`
  - SSH transport failed after retry exhaustion.
  - Typical rc is `255`.
- `xcolo_baseline_seed_copy_failed:<target>`
  - remote `qemu-img convert` or target file operation failed with a non-SSH
    failure code.
- `xcolo_baseline_seed_size_mismatch:<target>`
  - remote copy completed, but the resulting image virtual size does not match
    the Cloud-provisioned target size.
- `xcolo_baseline_seed_nbd_start_failed:<target>`
  - source NBD export could not start.
- `xcolo_baseline_source_not_ready:<target>`
  - source disk was not readable before export.

## Retry Model

Baseline seed copy uses a dedicated bounded retry loop:

- default attempts: `3`
- default sleep sequence: `5`, `15`, `30` seconds
- retry condition:
  - remote exec rc is `255`, or
  - captured stderr/stdout contains SSH transport markers such as connection
    reset, connection refused, connection timed out, connection closed, broken
    pipe, kex exchange failure, or MaxStartups throttling
- non-retry condition:
  - target missing
  - size mismatch
  - qemu-img conversion error
  - non-SSH rc other than transient transport marker

For file-backed seed destinations, each retry removes
`<dest>.ftctl-seed.*` on the remote host before retrying.

## Diagnostics

`ftctl_blockcopy_remote_exec` preserves the command result as before, but when
SSH fails with `rc=255` and no stderr/stdout was captured, it sets a synthetic
diagnostic:

`ssh_transport_failed_without_stderr host=<host> user=<user> port=<port> timeout=<timeout>`

Baseline seed events add:

- `block_conversion.baseline_seed.copy.attempt`
- `block_conversion.baseline_seed.copy.retry`
- `block_conversion.baseline_seed.copy.ssh_fail`
- `block_conversion.baseline_seed.copy.final_fail`

Successful copy records the final attempt and the remote `qemu-img info`
summary.

## Repetition Control

This is not a repeat of the previous COLO invalid-message failure because Run
61 did not reach generated runtime filter activation or migration.

The next test is considered progress if:

- `sdb` baseline seed passes, or
- retry events and non-empty SSH diagnostics are recorded for the failure.

If retry exhaustion returns the same SSH failure with no additional evidence,
report it as a repeated transport blocker and stop changing COLO runtime logic.
