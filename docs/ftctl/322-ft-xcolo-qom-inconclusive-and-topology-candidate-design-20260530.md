# 322. FT X-COLO QOM Inconclusive And Topology Candidate Design

Date: 2026-05-30

## Context

The retest after design 321 reached a stronger runtime state than earlier
runs:

- the standby VM was created and entered the paused/incoming side,
- primary migration was `active`,
- secondary migration was `colo`,
- 9000-series COLO channels were established,
- the primary QEMU process command line contained the expected COLO filter
  objects.

The run still failed with:

```text
xcolo_runtime_validation_failed:primary_colo_filter_qom_incomplete
```

The failure came from the new QOM property checker. In this environment,
`qom-get` for the filter object properties returned empty values even though
the QEMU process command line clearly contained the expected filter topology.
That makes QOM property reads a useful diagnostic signal, but not a reliable
hard gate for runtime destruction.

## Principle

FT runtime validation must separate these signals:

1. **Topology proof**: primary runtime XML and/or the live QEMU command line
   contains the expected `filter-mirror`, `filter-redirector`, and
   `colo-compare` objects.
2. **Transport proof**: primary/secondary migration and 9000-series channels
   are alive.
3. **QOM property diagnostics**: `qom-get` property values can confirm the
   topology when available, but empty or unavailable values are
   `inconclusive`, not a hard failure.

Only contradictory QOM values, missing topology proof, failed migration, or
missing channels after the pending window should be treated as hard failures.

## Design

### QOM State

Change the QOM collector from `yes|no` to `yes|no|unknown` semantics:

- `yes`: all expected QOM values are readable and match.
- `no`: QOM returns a concrete non-empty value that contradicts the expected
  topology.
- `unknown`: QOM values are missing, empty where a non-empty value is expected,
  or otherwise not readable.

`unknown` must never by itself cause runtime recovery.

### Live QEMU Command Line Topology Check

Add a primary QEMU command line collector that stores:

```text
xcolo_primary_filter_cmdline_ready=yes|no|unknown
xcolo_primary_filter_cmdline_reason=<comma-separated detail>
```

The collector checks for these tokens in the live QEMU process:

```text
filter-mirror,id=m0
filter-redirector,id=redire0
filter-redirector,id=redire1
colo-compare,id=comp0
netdev=hostnet0
outdev=mirror0
indev=compare_out
outdev=compare0
primary_in=compare0-0
secondary_in=compare1
outdev=compare_out0
```

This signal is closer to what QEMU actually received than `qom-get` property
reads on versions that do not expose those properties consistently.

### Candidate Preservation

If the following are true, validation returns pending with:

```text
colo_established_candidate
```

- primary XML markers are present,
- secondary XML markers are present,
- primary migration is `active`,
- secondary migration is `colo`,
- all required 9000-series channels are established,
- primary filter topology is proven by live command line or QOM.

This remains true after the pending window. Runtime recovery must not destroy
the candidate solely because QOM is `unknown` or `query-chardev` reports
closed frontends.

## Expected Result

The next retest should preserve the runtime when the live QEMU command line and
channels prove that COLO is established enough for observation. If it fails
again, the error should point to a concrete hard failure such as missing
command-line topology, missing channels, or migration failure.
