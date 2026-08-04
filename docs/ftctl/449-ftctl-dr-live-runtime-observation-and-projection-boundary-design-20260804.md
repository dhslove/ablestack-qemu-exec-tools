# 449. FTCTL DR Live Runtime Observation And Projection Boundary Design

- Date: 2026-08-04
- Status: code-level corrective design; implementation pending
- Scope: transition preflight, reverse preflight, runtime projection, Agent contract
- Parent design: [448-ftctl-dr-initial-reverse-seed-baseline-absence-and-terminal-evidence-design-20260804.md](448-ftctl-dr-initial-reverse-seed-baseline-absence-and-terminal-evidence-design-20260804.md)
- Cloud companion: `ablestack-cloud/docs/ftctl/592-cross-hypervisor-dr-failback-live-runtime-preflight-and-ux-convergence-design-20260804.md`

## 1. Objective

FTCTL must distinguish durable workflow projection from current hypervisor
observation. A runtime file that contains `target_power_state=POWERED_ON` proves
what the last committed DR action recorded; it does not prove that libvirt
still has a running domain after a host reboot.

Cloud/Mold Agent owns live KVM VM power observation. vCenter owns live VMware
power observation. FTCTL owns transition state, authority generation, reverse
baseline selection, source-disk probing, VDDK writer probing, and transfer
durability.

## 2. Verified drift

Plan `7889e625-371a-48f9-b553-54e311481170` had:

```text
FTCTL runtime:
  active_side=TARGET
  target_power_state=POWERED_ON
  cloud_authority_generation=10

FTCTL dr-transition-preflight:
  ready=true

Actual target host:
  virsh domstate i-2-266-VM
  -> Domain not found

Cloud/Mold Agent:
  CheckVirtualMachineCommand
  -> domain missing
```

The target host restarted before the observation. The projection survived; the
transient libvirt domain did not. This is not an FTCTL transition-state error.
It is a runtime-observation drift that Cloud must block before invoking the
engine transition.

## 3. Ownership matrix

| Fact | Authority | FTCTL treatment |
|---|---|---|
| KVM domain exists/runs now | Mold Agent/libvirt | external live observation |
| VMware VM power now | vCenter | external live observation |
| committed active side | Cloud cutover session + FTCTL ack | durable contract |
| authority generation | Cloud + FTCTL runtime | strict equality |
| transition lock/scheduler state | FTCTL | engine-owned live state |
| source RBD/QCOW2 exists | FTCTL preflight | engine-owned live probe |
| reverse baseline lineage | FTCTL | engine-owned durable state |
| VDDK writer capability | FTCTL/VDDK | engine-owned live probe |

## 4. Runtime schema semantics

Keep legacy power fields for compatibility but add explicit provenance:

```json
{
  "projection_target_power_state": "POWERED_ON",
  "projection_source_power_state": "POWERED_OFF",
  "power_evidence_authority": "PROJECTION_ONLY",
  "power_evidence_observed_at": "2026-08-04T16:34:23+09:00"
}
```

During compatibility, `target_power_state` and `source_power_state` mirror the
projection fields. New consumers must use the provenance field and must not
label them as Agent observations.

`power_evidence_observed_at` is the last FTCTL runtime update, not a libvirt or
vCenter check time.

## 5. `dr-transition-preflight` contract

### 5.1 Scope

The command validates only FTCTL-owned transition facts:

1. runtime/profile exists and contract version is supported;
2. active side matches expected authority;
3. authority generation matches Cloud expectation;
4. scheduler and replication worker are quiesced as required;
5. no incompatible operation or lock owns the Plan;
6. previous terminal transition is converged.

It does not validate actual KVM or VMware power.

### 5.2 JSON v3

Add `dr-transition-preflight-v3` while accepting v2 during rolling upgrade:

```json
{
  "command": "dr-transition-preflight",
  "contract_version": "dr-transition-preflight-v3",
  "status_scope": "TRANSITION_PREFLIGHT",
  "ready": true,
  "plan_uuid": "<uuid>",
  "operation": "failback",
  "expected_authority": "TARGET",
  "active_side": "TARGET",
  "expected_generation": 10,
  "authority_generation": 10,
  "projection_target_power_state": "POWERED_ON",
  "projection_source_power_state": "POWERED_OFF",
  "power_evidence_authority": "PROJECTION_ONLY",
  "live_power_validation_required": true,
  "scheduler_state": "STOPPED",
  "active_operation": "",
  "error_code": "",
  "exit_code": 0
}
```

`ready=true` means the FTCTL transition contract is internally ready. It never
means the serving VM is currently running.

### 5.3 CLI and library changes

Update:

- `lib/ftctl/dr_runtime.sh`
- `lib/ftctl/dr.sh`
- `lib/ftctl/ftctl.sh`
- transition preflight self-tests

Add helpers:

```bash
ftctl_dr_projection_power_evidence_json()
ftctl_dr_transition_preflight_contract_version()
```

Do not invoke `virsh` from `dr-transition-preflight`; the coordinator may not
be the serving VM host. Cloud already routes `CheckVirtualMachineCommand` to
the assigned target host.

## 6. `dr-reverse-preflight` live source contract

Reverse data preflight is different from transition preflight. It must verify
that the KVM authority data source can produce a consistent checkpoint.

Required order:

```text
profile and direction
  -> source domain identity
  -> source domain live/quiesce capability
  -> source disk map and images
  -> reverse baseline selector
  -> VMware destination power
  -> VDDK writer capability
```

If the active KVM domain is absent, return:

```json
{
  "ready": false,
  "error_code": "DR_REVERSE_SOURCE_DOMAIN_NOT_FOUND",
  "source_domain_probe_state": "NOT_FOUND",
  "source_disk_probe_state": "NOT_RUN",
  "target_writer_probe_state": "NOT_RUN",
  "exit_code": 85
}
```

RBD images remaining after a host reboot do not make Failback safe. Without a
live serving VM, FTCTL cannot perform the final quiesce/checkpoint contract.

Additional failures:

| Exit | Code | Meaning |
|---|---|---|
| 85 | `DR_REVERSE_SOURCE_DOMAIN_NOT_FOUND` | active KVM source domain absent |
| 86 | `DR_REVERSE_SOURCE_DOMAIN_NOT_RUNNING` | domain exists but is not running |
| 87 | `DR_REVERSE_SOURCE_QUIESCE_UNAVAILABLE` | required consistency gate unavailable |

Existing baseline and writer error codes remain unchanged.

## 7. Action-time revalidation

The read-only UI preflight result is advisory. `dr-failback` repeats under the
Plan transition lock:

1. transition contract selector;
2. source-domain live probe;
3. source-disk and baseline probe;
4. destination VMware power and writer probe.

If state changed after UI preflight, the action exits before creating snapshots
or writing VMware. It publishes one typed terminal error.

FTCTL does not start or define the missing KVM VM. Cloud VM lifecycle must
recover it first.

## 8. Agent mapping

Cloud Agent calls are ordered:

```text
target host: CheckVirtualMachineCommand(i-2-266-VM)
coordinator: FtctlDrStatusCommand(TRANSITION_PREFLIGHT)
coordinator: FtctlDrReversePreflightCommand(profile, FAILBACK_FINAL, AUTO)
```

If the first call is not `PowerOn`, the other two are `NOT_RUN` and no FTCTL
command is sent. This avoids engine logs that look like a second failure.

The Agent wrapper preserves:

```text
sourceDomainProbeState
sourceDiskProbeState
sourceDiskCount
requestedMode
effectiveMode
modeDecisionCode
baselineFileState
targetWriterProbeState
estimatedVirtualBytes
errorCode
exitCode
```

## 9. State and event output

`dr-status` exposes both projection and data-probe fields:

```text
projection_target_power_state
projection_source_power_state
power_evidence_authority
source_domain_probe_state
source_disk_probe_state
target_writer_probe_state
```

Events use stage-specific names:

```text
dr.transition.preflight.ready
dr.reverse.preflight.source-domain-blocked
dr.reverse.preflight.ready
```

No event claims a live target VM state unless the evidence came from an
explicit host-local domain probe performed for the reverse source.

## 10. Self-tests

Add deterministic tests:

1. stale projection `POWERED_ON` still reports
   `power_evidence_authority=PROJECTION_ONLY`;
2. transition preflight readiness is independent of live VM power;
3. missing source domain returns exit 86 and skips disk/writer probes;
4. stopped source domain returns exit 87;
5. two RBD images plus missing domain remains blocked;
6. live domain plus missing reverse baseline and AUTO selects
   `FULL_REVERSE_SEED`;
7. live domain plus durable baseline and AUTO selects `REVERSE_FINAL`;
8. action repeats the source-domain probe under the lock;
9. all JSON paths emit exactly one object and no stderr;
10. v2 consumers continue to receive legacy projection fields during rollout.

## 11. Implementation priority

1. P0: projection-only power provenance in status/transition JSON.
2. P0: source-domain probe before reverse disk/writer probes.
3. P0: typed exits 86-87 and exact JSON tests.
4. P0: action-time source-domain revalidation under transition lock.
5. P1: Agent DTO/wrapper field preservation and v2/v3 compatibility.
6. P1: package through GitHub Actions and deploy the same RPM to all workers.
7. P2: Cloud/Agent/FTCTL paired live acceptance.

## 12. AS-IS / TO-BE

| Area | Error cause | AS-IS | TO-BE |
|---|---|---|---|
| Power evidence | projection looks live | stale `POWERED_ON` can survive host reboot | provenance says `PROJECTION_ONLY` |
| Transition preflight | scope is ambiguous | `ready=true` appears to prove VM power | readiness covers only FTCTL-owned state |
| Reverse preflight | disks can outlive domain | RBD presence may look sufficient | live source domain and quiesce are mandatory |
| Missing domain | no dedicated reverse error | later failure or generic message | exit 86 with `DR_REVERSE_SOURCE_DOMAIN_NOT_FOUND` |
| Probe ordering | engine may run after Cloud target failure | duplicate/confusing failure surfaces | target Agent failure short-circuits FTCTL calls |
| Recovery | engine could appear responsible for VM repair | ownership unclear | Cloud lifecycle recovers VM; FTCTL remains read-only |
| Compatibility | field rename may break old Agent | one-step contract change | v3 plus legacy projection aliases during rollout |

## 13. Retest gate

FTCTL package verification alone does not make the affected Plan ready. Live
acceptance requires:

```text
Cloud/Mold Agent target domain = POWERED_ON
vCenter VMware source          = poweredOff
FTCTL transition preflight     = READY (projection scope)
FTCTL reverse source domain    = READY
source disks and VDDK writer   = READY
```

Until Cloud recovers `i-2-266-VM` through its VM lifecycle, Failback remains
blocked by design.
