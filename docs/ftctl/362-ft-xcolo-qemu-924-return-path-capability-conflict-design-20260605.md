# FT XCOLO QEMU 9.2.4 Return-Path Capability Conflict Design

## Background

Run 84 proved that the pre-migrate directional chardev contract is no longer the
blocking point. The primary and secondary chardev backends were connected under
the QEMU 9.2 directional contract, the pre-guest traffic gate passed, and the
run reached `primary.migrate`.

The remaining failure was:

- primary `query-migrate`: `failed`
- primary error-desc: `Received invalid message 0x0000 length 0x0000`
- prior FTCTL classification: `xcolo_startup_active_filter_stream_failed`

That previous classification was too broad. It mixed migration return-path
protocol failure and filter stream send failure under one label.

## QEMU 9.2.4 Source Evidence

The string `Received invalid message 0x0000 length 0x0000` is emitted by
`migration/migration.c` in `source_return_path_thread()`. That thread reads a
16-bit migration return-path message type and length, then rejects
`MIG_RP_MSG_INVALID`, whose value is `0`.

COLO checkpoint control does not use that 16-bit `MIG_RP_MSG_*` parser. In
`migration/colo.c`, the COLO primary opens `s->rp_state.from_dst_file` and
waits for 32-bit `COLOMessage` values such as
`COLO_MESSAGE_CHECKPOINT_READY`.

Therefore, when the generic migration return-path thread is enabled during
COLO, it can read from the same return-path stream that the COLO checkpoint loop
expects to consume. In that case, a COLO control stream can be misread by the
generic return-path parser and reported as `Received invalid message 0x0000`.

## Difference From QEMU COLO Documentation

QEMU 9.2.4 `docs/COLO-FT.txt` enables only the `x-colo` migration capability in
the primary and secondary QMP setup examples:

```json
{"capability": "x-colo", "state": true}
```

FTCTL previously enabled both:

```json
{"capability": "return-path", "state": true}
{"capability": "x-colo", "state": true}
```

That extra `return-path=true` was not part of the QEMU COLO sample and is the
strongest code-level explanation for the repeated post-migrate invalid-message
failure.

## Design Decision

For FT XCOLO, FTCTL must not enable the generic migration return-path
capability.

The expected capability contract is:

- `x-colo=yes`
- `return-path=no`

`return-path=unknown` is tolerated for QEMU variants that do not expose the
capability in `query-migrate-capabilities`, but `return-path=yes` is treated as
an invalid COLO runtime contract.

## Implementation Direction

1. Set migration capabilities with `return-path=false` and `x-colo=true` on
   both primary and secondary.
2. Verify `x-colo=yes`.
3. Verify `return-path` is not enabled. Record it as evidence even when the
   value is `unknown`.
4. Reclassify `Received invalid message` failures:
   - if `return-path=yes`, classify as
     `xcolo_migration_return_path_conflict`
   - if QEMU logs contain `filter mirror send failed(...)`, classify as the
     corresponding filter send error
   - otherwise classify as `xcolo_colo_control_message_invalid`
5. Keep the QEMU 9.2 directional chardev contract from document `361`; this
   change does not revert or weaken that already-passing gate.

## Expected Retest Signal

The next run should show:

- `xcolo_primary_capability_x_colo=yes`
- `xcolo_primary_capability_return_path=no`
- `xcolo_secondary_capability_x_colo=yes`
- `xcolo_secondary_capability_return_path=no`

If `Received invalid message 0x0000` still occurs with `return-path=no`, the
remaining fault is no longer the generic migration return-path thread. The next
debug target will then be the COLO control message exchange itself or an actual
filter send failure proven by QEMU log text.
