# 365. FT X-COLO Block Node And Backend Naming Design

Date: 2026-06-05

## Trigger

Run 87 verified that the native RBD startup backend fixed the previous
`/dev/rbd/rbd/<image-id>` startup visibility failure. QEMU then failed earlier
in block graph parsing with:

```text
Device name 'ftctl-primary-parent-sda' conflicts with an existing node name
```

A minimal QEMU test on `10.10.32.3` confirmed that:

- `-drive id=ftctltest,node-name=ftctltest,...` fails with the same conflict;
- `-drive id=ftctltest-backend,node-name=ftctltest-node,...` starts normally
  until the test timeout stops it.

## Principle

QEMU `id=` and `node-name=` are different identities and must not be generated
with the same value in the X-COLO startup graph.

- `node-name=` identifies the block node used by QMP graph operations such as
  `x-blockdev-change`, `nbd-server-add`, and `query-named-block-nodes`.
- `id=` identifies the BlockBackend used by guest devices.
- `-device scsi-hd,drive=...` must reference the BlockBackend id, not the
  block node name.

## Naming Contract

For disk suffix `sda`:

```text
primary parent node      = ftctl-primary-parent-sda
primary parent backend   = ftctl-primary-parent-sda-bb
primary active node      = ftctl-primary-active-sda
primary active backend   = ftctl-primary-active-sda-bb
colo node                = ftctl-colo-sda
colo backend             = ftctl-colo-sda-bb
guest disk device id     = ftctl-colo-sda-dev
```

Secondary uses the same split:

```text
secondary parent node    = ftctl-parent-sda
secondary parent backend = ftctl-parent-sda-bb
secondary childs node    = ftctl-childs-sda
secondary childs backend = ftctl-childs-sda-bb
colo node                = ftctl-colo-sda
colo backend             = ftctl-colo-sda-bb
guest disk device id     = ftctl-colo-sda-dev
```

## Reference Rules

- `backing=...`, `children.0=...`, `file.backing.backing=...`, and
  `x-blockdev-change parent=...` reference block node names.
- `-device scsi-hd,drive=...` references the BlockBackend id.
- QMP runtime operations continue to use node names. Runtime guest-visible
  disk hotplug remains forbidden.

## Fail-Fast Validation

After generating qemu commandline disk graph arguments, FTCTL validates:

- no `-drive` option has identical `id=` and `node-name=`;
- every protected `scsi-hd` guest device uses a backend id ending with `-bb`;
- generated qemu args still do not contain `/dev/rbd/`.

The relevant fail-fast errors are:

- `xcolo_startup_block_backend_node_conflict`
- `xcolo_startup_guest_drive_backend_invalid`
- `xcolo_startup_krbd_path_leaked`

## Expected Retest Boundary

The next run must not repeat:

```text
Device name ... conflicts with an existing node name
```

If the next run fails, it should be at a later boundary such as secondary
incoming startup, channel attach, QMP NBD export, `x-blockdev-change`, or
primary migrate.
