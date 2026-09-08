# 368. FT X-COLO Pre-Migrate Contract Gate Design

Date: 2026-06-07

## Trigger

Run 104 reached `primary.migrate`, then the secondary QEMU process crashed with:

```text
qemu-kvm: ../system/memory.c:2666: memory_region_add_subregion_common:
Assertion '!subregion->container' failed.
```

The Run 103 fix correctly classified the crash and recovered the primary VM, but
Run 104 proved that post-failure classification alone is not enough. The next
gate must stop before `primary.migrate` when the runtime pair does not satisfy
the migration contract.

## Principle

Do not compare the whole primary and secondary QEMU command line as a single
blob. COLO roles are intentionally different.

The pre-migrate contract is split into three parts:

1. Guest ABI contract
   - Primary and secondary guest-visible `-device` topology must match.
   - This includes disk controller/device placement that QEMU migration will
     load into the incoming secondary.
2. COLO role contract
   - Primary must contain the QEMU COLO primary role objects and chardevs:
     `filter-mirror`, `filter-redirector`, `colo-compare`, and the
     `mirror0`/`compare*`/`compare_out*` channels.
   - Secondary must contain the QEMU COLO secondary role objects and chardevs:
     `filter-redirector`, `filter-rewriter`, `red0`, `red1`, plus incoming
     migration mode.
   - Primary-only objects must not appear on secondary, and secondary-only
     objects must not appear on primary.
3. Block replication contract
   - Secondary NBD exports must be active.
   - Primary NBD children must already be attached to the COLO block graph.
   - This is checked after disk graph attachment and before network filter
     activation/migration.

## Implementation

`ftctl_xcolo_validate_pre_migrate_contract()` captures the live primary and
secondary QEMU argv pair and writes:

```text
migration-abi-contract-pre_migrate_contract.txt
```

It also records the primary and secondary block graph state collected from QMP.
The gate fails before `primary.migrate` with a specific error:

```text
xcolo_guest_abi_contract_mismatch
xcolo_colo_role_contract_mismatch
xcolo_primary_block_replication_contract_incomplete
xcolo_secondary_block_replication_contract_incomplete
```

The disk-plan handshake path invokes this gate immediately after all primary
NBD children are attached and before the primary network filter validation and
`primary.migrate`.

## Expected Test Effect

If Run 104's post-migrate QEMU assertion was caused by a still-hidden ABI or
block graph mismatch, the next run should fail earlier at
`pre_migrate_contract` with deterministic evidence instead of crashing the
secondary after migration.

If the contract passes and the same assertion still appears, the repeated issue
must be reported as a deeper QEMU migration-load compatibility problem using the
new contract evidence. Do not loop back to baseline seed, firewall, or stale
post-failure classification hypotheses unless new evidence points there.
