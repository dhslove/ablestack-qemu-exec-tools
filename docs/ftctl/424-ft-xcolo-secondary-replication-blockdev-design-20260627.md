# FT XCOLO Secondary Replication Blockdev Completion Design - 2026-06-27

## Background

The previous KRBD host-device blockdev change fixed primary-side materialization:
FT primary generated QEMU now opens protected KRBD disks through explicit
`-blockdev driver=host_device` nodes and wraps them with raw/qcow2/quorum nodes.
The next retest confirmed that this fixed the earlier
`xcolo_primary_krbd_open_fd_missing` path.

The retest then failed earlier than COLO network attach on the secondary host.
The secondary QEMU process exited while parsing its startup block graph:

```text
qemu-kvm: -blockdev driver=replication,...file.driver=qcow2,...file.file.filename=...:
Parameter 'file.file.driver' is missing
```

This is not a KRBD backend failure. It is a secondary replication graph schema
failure: the qcow2 active and hidden overlay file children were given filenames
without explicit `driver=file` nodes.

## Design Principles

- Keep the KRBD policy unchanged. Do not switch the protected RBD path to
  native librbd for this fix.
- Do not restore hot-plug or runtime disk mutation for protected disks.
  Primary and secondary disk graphs remain startup command-line graphs.
- Keep primary-side `host_device -> raw -> qcow2 active -> quorum` behavior
  unchanged.
- Complete the secondary replication block graph so QEMU can parse it before
  COLO network handshake and migrate are attempted.
- Add startup contract validation so this specific omission fails locally before
  a host retest reaches QEMU process startup.

## As-Is

Secondary generated command-line creates parent nodes correctly, but the
replication child inlines qcow2 overlays like this:

```text
-blockdev driver=replication,
  node-name=ftctl-childs-sda,
  mode=secondary,
  file.driver=qcow2,
  file.node-name=ftctl-active-sda,
  file.file.filename=/var/lib/.../secondary-active-sda.qcow2,
  file.backing.driver=qcow2,
  file.backing.node-name=ftctl-hidden-sda,
  file.backing.file.filename=/var/lib/.../secondary-hidden-sda.qcow2,
  file.backing.backing=ftctl-parent-sda,
  top-id=ftctl-colo-sda
```

QEMU requires the nested block driver under each qcow2 `file` object. A filename
alone is not enough for this dotted `-blockdev` form.

## To-Be

Secondary replication options must explicitly provide file children for both the
active qcow2 and hidden qcow2 nodes:

```text
-blockdev driver=replication,
  node-name=ftctl-childs-sda,
  mode=secondary,
  file.driver=qcow2,
  file.node-name=ftctl-active-sda,
  file.file.driver=file,
  file.file.filename=/var/lib/.../secondary-active-sda.qcow2,
  file.backing.driver=qcow2,
  file.backing.node-name=ftctl-hidden-sda,
  file.backing.file.driver=file,
  file.backing.file.filename=/var/lib/.../secondary-hidden-sda.qcow2,
  file.backing.backing=ftctl-parent-sda,
  top-id=ftctl-colo-sda
```

This keeps the secondary backing chain:

```text
standby parent image -> hidden qcow2 -> active qcow2 -> replication -> quorum -> scsi-hd
```

For RBD-to-qcow2 experimental tests, the primary parent remains KRBD
`host_device`, while the secondary parent remains file/qcow2 on local storage.
This design does not claim storage-layout equivalence; it only makes the
secondary graph syntactically and structurally valid so the test can progress to
COLO channel attach and migrate validation.

## Code-Level Changes

| File | Function | Change |
| --- | --- | --- |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_build_startup_disk_args` Python generator | Build secondary replication options as a list and add `file.file.driver=file` and `file.backing.file.driver=file`. |
| `lib/ftctl/xcolo.sh` | `ftctl_xcolo_validate_startup_disk_args` | Require the two nested file-driver tokens for secondary startup args. |
| `bin/ablestack_vm_ftctl_selftest.sh` | startup disk graph selftests | Assert that default KRBD and explicit KRBD secondary args include active and hidden qcow2 file drivers. |

## Verification

Required local checks:

```bash
bash -n lib/ftctl/xcolo.sh
bash -n bin/ablestack_vm_ftctl_selftest.sh
bin/ablestack_vm_ftctl_selftest.sh selftest_case_xcolo_startup_disk_graph_uses_krbd_backend_by_default
bin/ablestack_vm_ftctl_selftest.sh selftest_case_xcolo_startup_disk_graph_allows_explicit_krbd_backend
bin/ablestack_vm_ftctl_selftest.sh selftest_case_xcolo_startup_disk_graph_allows_explicit_librbd_backend
```

Required deployment checks:

- RPM-installed `xcolo.sh` contains `file.file.driver=file`.
- RPM-installed `xcolo.sh` contains `file.backing.file.driver=file`.
- 10.10.32.1/2/3 `ablestack-vm-ftctl.timer` and `ablestack-vm-hangctl.timer`
  are active after deployment.

## Expected Retest Result

The next `r97-link-02` FT protection attempt should no longer fail with:

```text
Parameter 'file.file.driver' is missing
xcolo_block_secondary_create_failed
```

If the test fails again, the expected next failure point should be later than
secondary QEMU startup, most likely COLO channel attach, migration, or guest
health validation. That would be a new stage and must be analyzed separately.
