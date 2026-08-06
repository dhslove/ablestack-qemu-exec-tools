# 452. FTCTL DR Failback Route Envelope And Cloud Lifecycle Boundary Design

- Date: 2026-08-05
- Status: code-level corrective design, live status preflight verified, implementation pending
- Scope: FTCTL reverse profile, runtime status, route evidence, abort/drain, self-tests
- Parent: [451](451-ftctl-dr-worker-identity-live-transfer-and-terminal-reconciliation-design-20260805.md)
- Cloud companion: `ablestack-cloud/docs/ftctl/595-cross-hypervisor-dr-failback-route-contract-and-terminal-convergence-design-20260805.md`

## 1. Objective

Publish an unambiguous Failback route envelope while preserving the ownership
boundary: FTCTL transfers data and publishes durable engine evidence; Cloud
validates policy, controls VM power and authority, and terminalizes the Cloud
Run.

The current transfer succeeded, but Cloud rejected it because FTCTL's legacy
`reverse_direction` value represents a provider pair while Cloud also uses the
word direction for a hypervisor topology.

## 2. Verified Current Behavior

For Run `18d0b555-9cdf-41c1-9650-f9620b0ccc36`:

- reverse profile `direction` was derived as `KVM_TO_VMWARE`;
- source/target providers were `ABLESTACK` and `VMWARE`;
- runtime stored `reverse_direction=ABLESTACK_TO_VMWARE`;
- `provider_pair` was written during checkpoint publication but was not
  consistently emitted by the final status JSON;
- FTCTL published authoritative `FAILBACK_DATA_READY`, exit `0`, sequence `14`,
  approximately 96.9 MB payload, and drained endpoints;
- no FTCTL mover defect or authority transition defect was observed.

The design therefore changes the status contract, not the successful transfer
algorithm.

## 3. Canonical Route Envelope

The reverse profile and Run state carry three distinct fields:

```text
replication_direction=KVM_TO_VMWARE
provider_pair=ABLESTACK_TO_VMWARE
operation_intent=FAILBACK_FINAL
```

`reverse_direction` remains a deprecated compatibility alias whose historical
value is `ABLESTACK_TO_VMWARE`. It must never be the only route field once
`route_contract_version=2` is published.

Status JSON:

```json
{
  "route_contract_version": 2,
  "replication_direction": "KVM_TO_VMWARE",
  "provider_pair": "ABLESTACK_TO_VMWARE",
  "reverse_direction": "ABLESTACK_TO_VMWARE",
  "operation_intent": "FAILBACK_FINAL"
}
```

## 4. Code-Level Changes

### 4.1 Reverse profile generation

In `lib/ftctl/dr_runtime.sh`, keep
`reverse["direction"] = reverse_direction(profile["direction"])` as the
hypervisor topology. Also set explicit profile metadata:

```python
reverse["replicationDirection"] = reverse["direction"]
reverse["providerPair"] = provider_pair(reverse["source"], reverse["target"])
reverse["routeContractVersion"] = 2
```

Provider names do not overwrite the profile direction.

### 4.2 Reverse checkpoint publication

In `ftctl_dr_runtime_reverse_checkpoint()` compute two variables:

```bash
replication_direction="$(ftctl_dr_runtime_profile_value "$profile_file" direction)"
provider_pair="${source_provider}_TO_${target_provider}"
```

Publish both to `run_path`, `status_path`, checkpoint metadata, operation
session, and terminal snapshot. Keep legacy `reverse_direction` equal to the
provider pair only for old Cloud versions.

### 4.3 Status emission

`ftctl_dr_runtime_emit_state_json()` reads and emits:

```bash
route_contract_version
replication_direction
provider_pair
reverse_direction
operation_intent
```

The state merger must not drop them when terminal journal data is merged with
Run state. Blank terminal-journal fields never erase the Run route.

### 4.4 Operation session

`ftctl_dr_runtime_write_operation_session()` records the route envelope and
Run UUID in both per-Run and active-session files. Cloud status by operation
scope and Plan scope must return the same tuple.

### 4.5 Abort and drain

Existing `FAILBACK_ABORT prepare/commit` remains the Cloud-invoked recovery
primitive. For a Cloud gate failure after `FAILBACK_DATA_READY`, abort must:

1. validate Plan, Run, and session ownership;
2. stop only Run-owned transient workers/endpoints;
3. preserve the durable reverse baseline and completed checkpoint;
4. publish an idempotent terminal/abort acknowledgement;
5. prove `runtime_endpoints_drained=true`;
6. never power either VM or change authority.

Repeated abort for the same Run returns the same terminal acknowledgement.

## 5. Ownership Boundary

| Decision | Owner |
|---|---|
| source extents, writer, bytes, baseline, checkpoint | FTCTL |
| route evidence publication | FTCTL |
| route validity for the Plan | Cloud |
| KVM target stop, VMware source start | Cloud |
| authority commit and protection resume | Cloud |
| UI state and action eligibility | Cloud |

FTCTL must not infer Cloud Plan success or start/stop Cloud-managed VMs after
publishing `FAILBACK_DATA_READY`.

## 6. Compatibility

| FTCTL payload | Cloud behavior |
|---|---|
| v2 explicit fields | use explicit topology and provider pair |
| legacy provider-style `reverse_direction` | normalize at Cloud boundary |
| legacy topology-style `reverse_direction` | infer provider pair from Plan/site types |
| conflicting explicit fields | reject as route evidence conflict |

The compatibility window ends only after all Agents and management nodes run a
v2-capable build.

## 7. Self-Test And Preflight Design

Add shell self-tests for:

1. `VMWARE_TO_KVM` profile reverses to topology `KVM_TO_VMWARE`;
2. source/target providers produce `ABLESTACK_TO_VMWARE`;
3. v2 and legacy fields survive Run/status/terminal merges;
4. operation and Plan status scopes emit the same route tuple;
5. data-ready terminal retains sequence, bytes, baseline, writer, write proof,
   guest compatibility, and endpoint drain;
6. repeated abort is idempotent and preserves durable checkpoint/baseline;
7. no password, secret, API key, or token is emitted in status/events/logs.

Live read-only preflight after deployment must verify the installed host script
contains v2 route emission, then query one synthetic profile through status
without starting a mover or changing VM power.

## 8. Recommended Implementation Priority

1. P0: explicit v2 route fields in reverse profile and Run state.
2. P0: status and operation-session emission with merge tests.
3. P0: Cloud-compatible abort/drain acknowledgement tests.
4. P1: legacy alias compatibility and contract capability marker.
5. P1: secret-redaction regression tests.
6. P1: GitHub Actions package, paired deployment, and host preflight.

## 9. AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| Profile | topology is available only internally | final status loses it | explicit `replication_direction` |
| Provider path | provider names reuse direction key | semantic collision | explicit `provider_pair` |
| Status | final JSON omits a complete tuple | Agent/Cloud infer values | route contract v2 envelope |
| Compatibility | one legacy key has two domains | valid data can be rejected | boundary normalization with conflict detection |
| Abort | lifecycle failure can leave Cloud Run active | stale 70 percent operation | idempotent drain acknowledgement for Cloud convergence |
| Authority | engine owns only data plane | safe today but implicit | boundary documented and tested |

## 10. Completion And Operator Handoff

FTCTL completion requires a v2 status tuple, preserved transfer evidence,
idempotent abort/drain, and no secret leakage. No operator action is required
during design or implementation. After Cloud and FTCTL are deployed together
and cleanup preflight passes, the operator executes one normal Failback.

## 11. Implementation And Live Verification - 2026-08-05

The FTCTL route envelope was implemented and packaged from commit
`517f81779595bf7721bcfdda2f4c5d85b4d4b9c4` by GitHub Actions run
`31017698792`. Package `ablestack_vm_ftctl-0.9.1-1.noarch` was deployed to
hosts `10.10.32.1`, `10.10.32.2`, and `10.10.32.3` together with the matching
Agent relay classes.

Verification completed as follows:

- reverse-profile self-tests passed for VMware-to-KVM and KVM-to-VMware role
  reversal;
- installed scripts emit `route_contract_version=2`,
  `replication_direction`, and `provider_pair`;
- all three `mold-agent` services are active;
- the stale Failback was aborted through FTCTL prepare/commit, leaving
  `FAILED_OVER`, `active_side=TARGET`, target `POWERED_ON`, source
  `POWERED_OFF`, and `rollback_state=COMPLETED`;
- no Run-owned `qemu-img`, `nbdkit`, or Failback mover process remained;
- `dr-transition-preflight-v2` returned `ready=true` for TARGET authority
  generation 10.

The durable reverse checkpoint and baseline were retained. The abort removed
only active operation ownership, so the next normal Failback can select the
validated reverse-final path without a forced cleanup or full reseed caused by
this failed attempt.

## 2026-08-06 Durable Evidence Publication Addendum

The next live Run completed reverse-final checkpoint sequence 15 and persisted
the complete durability tuple in the Run state and checkpoint. Plan-authority
`dr-status` nevertheless omitted `baseline_generation`, `tracker_state`,
`writer_state`, `target_written`, `write_verified`, and
`reverse_guest_compatibility_state`. Cloud therefore rejected the lifecycle
gate even though the reverse writer succeeded.

`ftctl_dr_runtime_emit_state_json()` must resolve one coherent reverse evidence
tuple from the operation Run and its referenced checkpoint and publish typed
values for both operation and Plan-authority scopes. It must also advertise a
reverse evidence contract version and completeness state. The preflight command
must verify that the installed engine supports this publication contract.

Cloud document
`596-cross-hypervisor-dr-failback-durable-evidence-publication-contract-design-20260806.md`
is normative for the cross-layer contract, asynchronous publication grace, and
retest acceptance criteria. Retained checkpoint 15 remains reusable and must
not be removed by this correction.

## 2026-08-06 Durable Evidence Publication Implementation

The engine now resolves the reverse durability tuple from the operation Run
state first and its referenced checkpoint second. `dr-status` publishes typed
`reverse_evidence_contract_version`, `reverse_evidence_state`,
`reverse_evidence_run_uuid`, baseline/tracker/writer states, target-write
booleans, guest compatibility, and the missing-field list. Conflicting Plan,
Run, or generation identity is reported as `INCONSISTENT`; incomplete and
explicitly non-durable tuples remain distinct.

`dr-reverse-preflight` advertises evidence contract version 1 and publication
readiness, and capabilities include `dr-reverse-evidence-publication-v1`.
Targeted WSL ext4 self-tests passed for reverse evidence projection, reverse
preflight contract emission, and read-only reverse RBD snapshot attachment.
The repository-wide self-test still stops earlier in an existing
`shared-blockcopy` fixture that requires a Cloud-managed disk map; that
unrelated fixture failure is not counted as validation of this change.

GitHub Actions run `31062183699` built commit `33d1651` and produced
`ablestack_vm_ftctl-0.9.1-1.noarch` with SHA256
`ba4077ed953cacfb72e0c46a97beba1d358e397dc8ed171ff8929e050fe2bd7b`.
The package was installed on `10.10.32.1`, `.2`, and `.3`. Installed-script
marker checks, timers, and `mold-agent` service checks passed on all hosts.
Live `dr-status` published a complete generation-15 tuple and live reverse
preflight returned Ready with the evidence publication contract enabled.
