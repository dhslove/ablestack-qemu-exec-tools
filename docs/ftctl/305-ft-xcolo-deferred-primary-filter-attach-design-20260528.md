# FT X-COLO Deferred Primary Filter Attach Design

## Background

After the channel attach fix, `r97-link-01` progressed farther:

```text
primary.create_generated.channel_attach result=ok
mirror_port=9003 compare_port=9004 attempts=1
```

Both primary peer-facing sockets were established before QMP migration:

```text
10.10.32.1 -> 10.10.32.3:9003 ESTAB
10.10.32.1 -> 10.10.32.3:9004 ESTAB
```

Runtime still failed later:

```text
primary query-migrate: failed, Received invalid message 0x0000 length 0x0000
primary log: filter mirror send failed(Operation not permitted)
secondary log: Can't receive COLO message: Input/output error
```

The important timing is that `filter mirror send failed` occurred before qemu FTCTL completed the QMP block graph and migration setup. This means the primary network filters were active too early because they were injected through the generated primary XML command line.

## Design Principle

The generated primary domain must be allowed to start and attach chardev channels without activating the COLO packet filter pipeline. qemu FTCTL should attach primary network filters only after:

1. generated primary is created and paused;
2. generated secondary is created;
3. primary peer sockets are established;
4. primary and secondary disk graphs are prepared;
5. secondary NBD export is ready;
6. primary NBD replacement is ready.

Only then should qemu FTCTL attach:

- `filter-redirector redire0`
- `filter-redirector redire1`
- `colo-compare comp0`
- `filter-mirror m0`

`filter-mirror` is attached last so primary packet mirroring cannot emit before the compare/redirector path exists.

## Primary Generated XML Contract

Primary generated XML keeps:

- `-S`
- `mirror0`
- `compare1`
- `compare0`
- `compare0-0`
- `compare_out`
- `compare_out0`
- native libvirt iothread id `1`

Primary generated XML must not include:

- `filter-mirror`
- `filter-redirector`
- `colo-compare`

These objects are QMP-owned runtime objects in the cloud-managed cold conversion path.

## QMP Attach Sequence

After primary `x-blockdev-change`, before primary `migrate-set-capabilities`, qemu FTCTL runs:

```text
primary.object_add_redirector_in
primary.object_add_redirector_out
primary.object_add_colo_compare
primary.object_add_filter_mirror
```

Then it proceeds with:

```text
primary.migrate_set_capabilities
primary.migrate
primary.migrate_set_parameters
```

## Validation

Runtime XML validation changes accordingly:

- primary XML validation checks for x-colo chardev commandline markers;
- primary XML validation no longer requires filter object markers because they are QMP runtime objects;
- qemu FTCTL records `xcolo_primary_net_filters_attached=true` after all primary filter `object-add` calls succeed.

## Expected Improvement

This removes the early packet-filter activation window observed in the failed run. If migration still fails after this change, it will be after:

- channels attached;
- disk graphs attached;
- primary filters attached by QMP in the correct order.

That gives a much narrower remaining failure domain: migration stream capability/COLO block graph semantics rather than startup channel ordering.

