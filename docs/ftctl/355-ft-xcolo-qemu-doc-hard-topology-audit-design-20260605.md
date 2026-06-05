# FT XCOLO QEMU Doc Hard Topology Audit Design - 2026-06-05

## Background

Run 78 failed before primary migrate with:

- `last_error=xcolo_colo_chardev_contract_not_ready_before_guest_traffic`
- `xcolo_pre_guest_traffic_contract_primary_status=paused`
- `xcolo_pre_guest_traffic_contract_secondary_status=inmigrate`
- `xcolo_chardev_contract_reason=mirror_path_primary_mirror0=present_closed,compare_path_secondary_red1=present_closed`

The latest pre-guest gate improved failure containment because the run no
longer reached the repeated downstream `Received invalid message 0x0000 length
0x0000` signature before the gate. However, the gate still did not tell us
whether the generated command line itself deviated from the QEMU COLO sample or
whether QEMU started with the documented topology and then kept a runtime
frontend closed.

The next change must be based on the QEMU COLO document rather than another
activation timing experiment.

## QEMU Document Baseline

The QEMU COLO test procedure starts the primary with:

- `-S`
- `mirror0` socket listener on port `9003`, `server=on`, `wait=off`
- `compare1` socket listener on port `9004`, `server=on`, `wait=on`
- loopback sockets `compare0` / `compare0-0` on port `9001`
- loopback sockets `compare_out` / `compare_out0` on port `9005`
- active startup `filter-mirror id=m0`
- active startup `filter-redirector id=redire0`
- active startup `filter-redirector id=redire1`
- active startup `colo-compare id=comp0`

The secondary starts with:

- `red0` toward primary port `9003`, `reconnect-ms=1000`
- `red1` toward primary port `9004`, `reconnect-ms=1000`
- active startup `filter-redirector id=f1`
- active startup `filter-redirector id=f2`
- active startup `filter-rewriter id=rew0`
- `-incoming <migration-uri>`

Then the documented sequence prepares secondary QMP/NBD first, prepares the
primary NBD child, enables `x-colo` and `return-path`, and only then issues
primary `migrate`.

## Previous Code Difference

The runtime code already matched the core document topology better than the
older staged-activation experiments:

- primary and secondary filters are generated in startup `qemu:commandline`
- `status=off` is not used in the normal path
- `primary.migrate` is issued after secondary incoming/NBD preparation

The intentional extensions are:

- `insert=behind,position=tail` on the primary filters, to make the libvirt
  netfilter insertion point explicit
- `vnet_hdr_support=on` when the detected virtio/vnet-header environment needs
  it
- real libvirt netdev ids and site addresses instead of the document's `hn0`
  and example loopback peer addresses
- after Run 79, FTCTL's cloud-managed/libvirt path uses `mirror0 wait=on` as a
  peer-before-send orchestration extension; see
  [356. FT XCOLO Premigrate Frontend Open Before Migrate Design](356-ft-xcolo-premigrate-frontend-open-before-migrate-design-20260605.md)

The real gaps were:

- the internal doc-alignment text still said primary filters were attached by
  QMP after block graph readiness, which conflicts with the current
  startup-active design
- the command-line audit did not strictly check the document's socket wait
  modes, loopback socket pairs, or secondary reconnect options
- when the document-shaped topology was present but `mirror0` or `red1` stayed
  closed, the error was classified as a generic chardev contract failure

## Design

Do not return to staged filter activation. Runs 71 through 73 already showed
that enabling `redire1` after the stream starts breaks the COLO channel. The
normal path remains startup-active.

Instead, add a QEMU-document hard topology audit:

1. Primary command line must contain the documented socket contract, with the
   FTCTL mirror wait extension:
   - `mirror0` port `9003`, `server=on`, `wait=<configured, default on>`
   - `compare1` port `9004`, `server=on`, `wait=on`
   - loopback `compare0` / `compare0-0` on port `9001`
   - loopback `compare_out` / `compare_out0` on port `9005`
2. Primary command line must contain active startup `m0`, `redire0`, `redire1`,
   and `comp0`, and must not contain `status=off`.
3. Secondary command line must contain `red0` and `red1` with
   `reconnect-ms=1000`, `f1`, `f2`, `rew0`, and `-incoming`.
4. Primary QOM must confirm that the startup-created filter objects are live and
   bound to the expected netdev/chardevs.
5. If this audit fails, stop with:
   - `xcolo_qemu_doc_topology=failed`
   - `last_error=xcolo_qemu_doc_topology_mismatch`
6. If this audit passes but the pre-guest chardev contract fails with closed
   frontends, stop with:
   - `xcolo_qemu_doc_topology=ok`
   - `last_error=xcolo_qemu_doc_runtime_frontend_closed`
   - `xcolo_qemu_doc_runtime_frontend_reason=<closed edge list>`

## Expected Retest Value

The next test must produce one of these clear outcomes:

- QEMU document topology mismatch: fix the generated command line directly.
- QEMU document topology OK, frontend closed: investigate why QEMU keeps
  `mirror0` or `red1` closed even with the documented startup topology.
- QEMU document topology OK, frontend open, migrate progresses: continue with
  post-migrate COLO convergence validation.

This prevents another loop of changing activation timing without first proving
that the generated command line differs from the QEMU COLO sample.
