# 361. FT XCOLO QEMU 9.2.4 Directional Chardev Contract Design - 2026-06-05

## Problem

Run 83 failed before primary `migrate` with:

```text
last_error=xcolo_pre_migrate_frontend_not_open
primary mirror0=present_closed
primary compare1=present_open
secondary red0=present_open
secondary red1=present_closed
```

The failure avoided the repeated post-migrate protocol symptom, but QEMU 9.2.4
code-level review showed the gate was too strict. `query-chardev` showed
`mirror0` and `red1` as `frontend-open=false`, but their `filename` values
contained an established TCP peer (`<->`). Both are output chardevs. They must
have a connected socket backend before guest traffic is allowed, but they do
not need to report `frontend-open=true` in the same way as input consumers.

## QEMU 9.2.4 Code Basis

- `net/filter-mirror.c`: `filter_send()` writes guest TX packets to the
  configured `outdev` by calling the chardev frontend write path.
- `net/filter-redirector.c`: redirectors are directional. `indev` is consumed
  from a chardev, while `outdev` writes to a chardev.
- `migration/migration.c`: `Received invalid message 0x0000 length 0x0000` is
  a migration return-path parser failure, not direct proof that an output
  chardev had `frontend-open=false`.
- `migration/colo.c`: `Can't receive COLO message: Input/output error` is a
  COLO control channel failure after migration/control flow starts.

Therefore the pre-migrate gate must not collapse output chardev frontend-open
state, TCP backend connectivity, and migration return-path failures into one
condition.

## Directional Contract

FTCTL must evaluate the two network paths by direction:

```text
primary:m0 -> mirror0 -> secondary:red0 -> f1
secondary:f2 -> red1 -> primary:compare1 -> comp0
```

Required pre-migrate state:

- primary `mirror0`: present and TCP backend connected
- secondary `red0`: present and `frontend-open=true`
- secondary `red1`: present and TCP backend connected
- primary `compare1`: present and `frontend-open=true`

For diagnostics, FTCTL still records strict frontend-open state for all four
chardevs. However, strict `present_open` is no longer the pass/fail criterion
for output chardevs.

## Implementation

1. Change `ftctl_xcolo_capture_colo_chardev_contract()` to parse both
   `frontend-open` and backend filename connectivity from `query-chardev`.
2. Store:

```text
xcolo_chardev_contract_ready=<yes|no|unknown>
xcolo_chardev_contract_directional_ready=<yes|no|unknown>
xcolo_chardev_contract_strict_frontend_ready=<yes|no|unknown>
xcolo_chardev_contract_output_frontend_policy=backend_connected
```

3. Change `ftctl_xcolo_gate_before_guest_traffic()` policy to
   `qemu_9_2_directional_chardev_contract`.
4. Keep QEMU command-line topology, QOM status, socket, firewall, RBD stable
   path, storage symmetry, vhost, and pre-migrate send-failure guards unchanged.
5. If `primary.migrate` later fails with `Received invalid message`, classify
   it as a migration return-path or COLO control-channel issue, not as a repeat
   of the pre-migrate output frontend-open condition unless the directional
   contract also failed.

## Cloud-Managed Runtime Reconcile Correction

Run 83 also left Cloud DB and libvirt runtime inconsistent:

```text
Cloud DB: i-2-139-VM Running
libvirt:  failed to get domain 'i-2-139-VM'
```

For cloud-managed FT cleanup/recovery, standby restore must use
`standby.generated.xml`, not `standby_xml_seed`. The generated XML contains the
secondary VM name and secondary disk mappings. The seed XML can contain the
source VM name/UUID/disk paths and is not a safe runtime restore source.

## Retest Expectations

The next retest should proceed past the previous Run 83 pre-migrate gate when:

- `mirror0` is `present_closed` but connected
- `red1` is `present_closed` but connected
- `red0` and `compare1` are `present_open`

If the run then fails after `primary.migrate`, the report must explicitly state
that the previous hard-gate false positive has been cleared and classify the new
failure by QEMU migration/COLO return-path evidence.
