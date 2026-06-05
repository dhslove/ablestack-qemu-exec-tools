# 363. FT X-COLO Startup Disk Graph And No Hot Plug Design

Date: 2026-06-05

## Trigger

Run 85 advanced beyond the previous migration return-path conflict, but the
secondary QEMU process crashed with:

```text
memory_region_add_subregion_common: Assertion '!subregion->container' failed
```

Runtime evidence showed that the secondary had already been started as an
incoming COLO domain. qemu FTCTL then built a COLO block graph through QMP and
replaced the guest-visible SCSI disk device with `device_del` / `device_add`.

That is not acceptable for a fault-tolerance feature. A protected VM must not
have its guest-visible disk devices dynamically replaced after the FT runtime is
started.

## Principle

For FT/X-COLO, qemu FTCTL must never hot plug, hot remove, or hot replace the
guest-visible disk devices of either the primary or secondary protected VM.

Cloud still owns VM and disk lifecycle. qemu FTCTL may create a transient
runtime XML from Cloud's libvirt XML, but any COLO-specific disk graph must be
present before the transient QEMU process starts.

## QEMU COLO Alignment

The QEMU COLO procedure starts primary and secondary QEMU with their COLO disk
graphs already present:

- primary starts with the guest disk device backed by a quorum node;
- secondary starts with parent, replication child, active/hidden images, and
  quorum node;
- after secondary QMP setup, primary adds the remote NBD child and runs
  `x-blockdev-change`;
- migration starts only after the disk and network contracts are ready.

The corrected ABLESTACK flow follows that model:

1. Backup Cloud-created primary and standby XML.
2. Seed the secondary baseline disks.
3. Prepare primary active overlay and secondary hidden/active overlays.
4. Rewrite generated transient XML before start:
   - remove only the protected disk entries from the generated XML;
   - preserve Cloud-created controllers, NICs, serial/console, metadata, and
     non-protected devices;
   - add qemu commandline disk graph arguments for the protected disks;
   - add qemu commandline COLO network filter arguments.
5. Start primary and secondary from the generated transient XML.
6. Verify the secondary startup block graph exists.
7. Run QMP capability/NBD/export setup.
8. On primary, add the remote NBD child and run `x-blockdev-change`.
9. Run primary `migrate`.

## RBD Path Rule

The generated XML and qemu commandline must use the stable Cloud RBD path:

```text
/dev/rbd/rbd/<image-id>
```

`/dev/rbdN` may be recorded only as diagnostic evidence. It must not become the
long-lived generated XML source path.

## Runtime Guard

`device_del` / `device_add` disk replacement is forbidden by default. If a stale
code path still attempts it, qemu FTCTL must fail fast with:

```text
xcolo_runtime_guest_disk_hotplug_forbidden
```

It must not try the operation and wait for QEMU to crash.

## Validation Contract

The next retest must confirm:

- generated primary/secondary XML contains startup COLO disk graph commandline
  arguments;
- generated XML no longer contains duplicate protected `<disk>` entries;
- no event contains `device_del_existing_root`;
- no event contains `device_add_colo_root`;
- secondary `query-named-block-nodes` shows `ftctl-parent-*`,
  `ftctl-childs-*`, `ftctl-hidden-*`, `ftctl-active-*`, and `ftctl-colo-*`
  nodes before primary migrate;
- primary adds only the NBD child at runtime and then calls
  `x-blockdev-change` against the pre-existing quorum node.
