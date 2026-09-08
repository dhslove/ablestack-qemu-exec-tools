# FT XCOLO Virtio VNET Header Support Design - 2026-06-02

## Problem

Run 60 proved that the delayed primary filter activation path is no longer the
active blocker:

- primary and secondary generated runtimes were created
- baseline seed completed for both disks
- primary filter objects started with `status=off`
- QMP activation changed `redire0`, `redire1`, and `m0` to `status=on`
- pre-migrate evidence passed
- primary `migrate` returned ok
- handshake returned ok

The failure moved to the post-handshake COLO message path:

```text
Primary:   Received invalid message 0x0000 length 0x0000
Secondary: Can't receive COLO message: Input/output error
```

The test VM uses a `virtio` network model. QEMU COLO network filters and
`colo-compare` support `vnet_hdr_support`; without it, virtio-net packet
headers may be interpreted differently across the mirror, redirector, rewriter,
and compare path.

## Design Principle

When the selected primary/secondary NIC model is virtio based, all COLO network
filter and compare objects must agree on vnet header handling before migration
starts. Do not continue to tune filter activation timing unless this contract is
met and the same runtime failure remains.

## Required Behavior

1. Detect the primary and secondary NIC model from the resolved XCOLO netdev
   inventory.
2. Treat these models as requiring vnet header support:
   - `virtio`
   - `virtio-net`
   - `virtio-net-pci`
   - any model beginning with `virtio`
3. Record the decision in state:
   - `xcolo_net_vnet_hdr_support=on|off`
   - `xcolo_net_vnet_hdr_support_reason=virtio_net_model|not_required`
4. If either side requires vnet header support, apply it consistently to:
   - primary `filter-mirror` object `m0`
   - primary `filter-redirector` objects `redire0` and `redire1`
   - primary `colo-compare` object `comp0`
   - secondary `filter-redirector` objects `f1` and `f2`
   - secondary `filter-rewriter` object `rew0`
5. Apply the same option in both generated XML commandline and QMP object-add
   fallback/rebuild paths.
6. Before primary `migrate`, verify that the generated commandline includes
   `vnet_hdr_support` when it is required. If missing, stop with:
   `last_error=xcolo_vnet_hdr_support_missing`.
7. Collect QOM state for the primary objects so future evidence can distinguish
   between:
   - vnet header support missing
   - vnet header support unsupported by QEMU
   - COLO protocol failure after a complete vnet-aware topology

## Repetition Control

Run 60 was progress, not a blind repeat. The next valid run must be judged by
these markers:

- `xcolo_net_vnet_hdr_support=on` for the current `virtio` VM
- generated primary and secondary commandlines contain `vnet_hdr_support`
- primary QOM collection records vnet header support on the COLO objects when
  QEMU exposes the property
- pre-migrate evidence passes with the vnet-aware topology

If the same invalid COLO message still occurs with those markers present, the
next blocker is deeper QEMU COLO protocol behavior or device-model support, not
ftctl channel ordering, startup timing, or missing vnet header options.
