# FT XCOLO secondary baseline format contract design - 2026-06-25

## Problem

The `r97-link-02` FT/XCOLO retest advanced past Cloud registration, automatic
port allocation, standby VM creation, and baseline seed copy. It then failed
before migrate with:

```text
xcolo_primary_block_replication_contract_incomplete
```

Runtime evidence showed that the secondary baseline files were created as
`qcow2` images:

```text
file format: qcow2
virtual size: 50 GiB
```

However, the generated secondary block graph opened those baseline files as
`raw`. QEMU therefore interpreted the qcow2 file length, for example about
`159 MiB`, as the full guest disk size. When the COLO block graph later tried
to service the 50 GiB guest disk path, QEMU hit:

```text
qemu-kvm: ../block/io.c:1993: bdrv_co_write_req_prepare:
Assertion `offset + bytes <= bs->total_sectors * BDRV_SECTOR_SIZE ||
child->perm & BLK_PERM_RESIZE' failed.
```

This is not a recurrence of the earlier q35/i440fx, PCI topology, or XCOLO
socket protocol loops. The new failure is a secondary baseline file format
contract violation.

## Principles

- Do not change the stable ABLESTACK RBD path principle. Primary RBD paths stay
  in the `/dev/rbd/<pool>/<image>` form and are not converted to volatile
  `/dev/rbdN` paths.
- The secondary block graph must be generated from the actual baseline file
  format created by the baseline seed step.
- A format or virtual-size mismatch must fail before QEMU migrate or guest I/O
  can corrupt the runtime.
- The failure reason must identify the disk and the expected/detected format.

## AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Baseline seed result | `qemu-img convert` creates the target file and logs a compact `qemu-img info` line. | The seed step records detected `format`, graph driver format, `virtual-size`, and `actual-size` into xcolo state. |
| Secondary graph input | `disk_runtime` carries only primary format. | `disk_runtime` carries `secondary_baseline_graph_format` as an eighth field. |
| Secondary parent node | Uses the primary format for the secondary baseline parent. | Uses the detected secondary baseline graph format. |
| Validation | Size mismatch can be detected, but format mismatch can slip into QEMU startup. | Missing/mismatched seed format fails before startup graph creation. |
| Error | Later generic replication contract failure. | Early specific failure such as `xcolo_secondary_baseline_format_mismatch:<disk>`. |

## Implementation

1. After each successful `baseline_seed.copy`, parse the final
   `qemu-img info` compact line:

   ```text
   format=<format> virtual=<bytes> actual=<bytes>
   ```

2. Normalize the format for graph use:

   - `qcow2` target requires detected `qcow2` and graph driver `qcow2`.
   - `raw` target accepts `raw`, `host_device`, or `file`, and graph driver
     remains `raw`.

3. Persist per-disk state:

   ```text
   xcolo_disk_<target>_secondary_baseline_format
   xcolo_disk_<target>_secondary_baseline_graph_format
   xcolo_disk_<target>_secondary_baseline_virtual_size
   xcolo_disk_<target>_secondary_baseline_actual_size
   xcolo_disk_<target>_secondary_baseline_target_format
   ```

4. Build `disk_runtime` with an eighth field:

   ```text
   target|primary_source|primary_format|primary_overlay|secondary_dest|
   secondary_hidden|secondary_active|secondary_baseline_graph_format
   ```

5. Keep backward compatibility in the parser by accepting the old seven-field
   form, defaulting the secondary format to the primary format only for older
   callers.

6. Before startup graph generation, fail if the per-disk secondary baseline
   graph format is missing.

## Smoke Criteria

- `bash -n` passes for all shell scripts touched by this change.
- The FTCTL selftest path still runs without syntax errors.
- Generated secondary startup disk args for a file-backed qcow2 baseline use
  `driver=qcow2` for the secondary parent node.
- A rerun no longer produces a secondary graph where a qcow2 baseline file is
  opened as `raw`.
- If the seed result is missing or mismatched, FTCTL fails before QEMU startup
  with a specific baseline format or virtual-size error.
