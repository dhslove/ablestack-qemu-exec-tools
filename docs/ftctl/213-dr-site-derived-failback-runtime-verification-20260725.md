# DR Site-derived Failback Runtime Verification

> 2026-07-26 correction: The Site-derived credential result remains valid,
> but an actual failback exposed premature SOURCE authority after the reverse
> checkpoint. FTCTL must wait in `FAILBACK_DATA_READY/TARGET` and accept
> `dr-failback-commit` only after Cloud completes VM lifecycle validation.
> Document 214 supersedes the old completion interpretation.

## Scope

Cloud owns the registered DR Site topology, credential resolution, action
authorization, and VM lifecycle. FTCTL owns only the failback data plane:
reverse copy, checkpoint handling, and finalize operations requested through
the Agent.

The Site-derived failback implementation did not require an FTCTL source
change. The existing runtime credential-file contract was verified against the
installed package instead of rebuilding an unchanged package.

## Installed Runtime Verification

Hosts:

- `10.10.32.1`
- `10.10.32.2`
- `10.10.32.3`

All hosts passed:

```text
ablestack-vm-ftctl.timer=active
credentials.json runtime markers present
chmod 0600 credential-file handling present
```

The focused self-test on `10.10.32.2` also passed:

```text
FTCTL_SELFTEST_CASES=selftest_case_dr_vmware_cbt_preflight_uses_runtime_credentials_file
SELFTEST_RC=0
```

## Runtime Contract

1. Cloud resolves source and target credentials from the registered Sites.
2. Agent writes the transient credential file with mode `0600`.
3. FTCTL reads the transient file for the operation.
4. Durable profile, status, event, and log output remain redacted.
5. Cloud retains VM lifecycle and control-plane authority.
6. FTCTL does not accept a user-selected Mold target as failback authority.

## Retest Readiness

The installed FTCTL runtime satisfies the Site-derived failback contract.
No qemu package build or deployment was necessary for this change.
