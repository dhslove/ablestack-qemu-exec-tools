# FTCTL DR Completed Failback Reverse Evidence Retention Design

## 1. Problem

After Failback completes, forward protection resumes and publishes a new Run to
the plan status. The previous implementation selected that current forward Run
as the source of reverse evidence. Since it does not own the Failback tracker,
writer, checkpoint, or guest-compatibility fields, `dr-status` could report
`reverse_evidence_state=INCONSISTENT` despite a successful Failback.

## 2. Durable Owner

The completed Failback Run remains the durable owner of reverse evidence.
FTCTL records its UUID as `reverse_evidence_run_uuid` when the reverse
checkpoint is written and when the post-Failback resume checkpoint completes.
The active Failback sidecar overlays the same Run UUID after later forward
status publication.

Status emission resolves the evidence Run in this order:

1. explicit `reverse_evidence_run_uuid`;
2. Run UUID from `failback_session_id=<plan>:<run>`;
3. current Run and command fallback identifiers.

Only a candidate with an existing Run state file is accepted. The selected Run
must still satisfy the existing plan, Run, baseline, tracker, writer, target
write, verification, and guest compatibility checks.

## 3. Compatibility

No command-line, JSON field, profile, VDDK, RBD, CBT, or service-unit contract
changes. Older status files without the explicit field recover through the
persisted Failback session ID. New files preserve the explicit owner.

## 4. Test Contract

The Failback terminal selftest writes complete reverse evidence to the Failback
Run, publishes a newer forward Run, and verifies:

- the plan status retains the Failback evidence Run UUID;
- `dr-status.reverse_evidence_state` remains `COMPLETE`;
- `reverse_evidence_missing_fields` is empty;
- the Run UUID remains the completed Failback Run.

## 5. AS-IS / TO-BE

| Area | AS-IS | TO-BE |
|---|---|---|
| Evidence owner | New forward scheduler Run wins | Completed Failback Run wins |
| Status overlay | Lifecycle authority only | Lifecycle authority plus evidence owner |
| Legacy recovery | Missing explicit owner becomes inconsistent | Failback session ID restores the owner |
| Validation | False `INCONSISTENT` after successful Failback | Existing durability checks report `COMPLETE` |
