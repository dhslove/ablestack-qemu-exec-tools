# FTCTL DR Global Cycle Floor And Terminal Reprojection Contract

## 1. Scope

This document pairs with Cloud design `620-dr-terminal-cycle-lease-collision-
reprojection-design-20260827.md`. FTCTL owns durable engine evidence; Cloud owns
the management run and canonical database projection.

No data-path algorithm changes are introduced here. The already implemented
global authority sequence floor and terminal journal behavior are the package
baseline required for deployment.

## 2. FTCTL Responsibilities

- A scheduler lease must not restart checkpoint numbering below the persisted
  global authority sequence floor.
- Full Seed completion must publish terminal journal evidence before a later
  incremental cycle can replace live worker state.
- `dr-status --run` must retain the completed control request UUID, terminal
  authority, exit code, manifest path, checkpoint path, durable timestamps,
  scheduler session, lease epoch, authority sequence, and cycle token.
- Later scheduler status must not erase the terminal evidence owned by the
  accepted Cloud run.
- A terminal worker must drain owned NBD endpoints before publishing success.

## 3. Cloud Boundary

FTCTL does not update Cloud DB rows. Cloud consumes the evidence above, handles
legacy sequence collisions, and terminalizes the accepted run. A package
deployment is complete only when the running scheduler uses the installed
scripts and emits a sequence at or above the authority floor.

## 4. AS-IS / TO-BE

| Area | AS-IS risk | Required behavior |
|---|---|---|
| Scheduler restart | Sequence can overlap historical Cloud rows | Start above global authority floor |
| Terminal publication | New cycle can obscure the accepted run | Terminal journal is a mandatory barrier |
| Status replay | Current producer UUID dominates | Accepted control-run terminal evidence is retained |
| Deployment | RPM can change while scheduler keeps old code | IDLE rolling reload and script-hash verification |
| Recovery | Operator edits DB | Cloud automatically reprojects strict FTCTL evidence |

## 5. Regression Gate

- Run the requested-cycle terminal journal smoke test.
- Run the global authority sequence floor smoke coverage.
- Extract the built RPM and byte-compare `dr_runtime.sh` and
  `dr_scheduler.sh` with the checked-out source. The workflow must fail on any
  mismatch even when the RPM version string is unchanged.
- Verify release tombstone and baseline action contract tests remain unchanged.
- After package deployment, verify all compute hosts report the same package
  version and `dr_runtime.sh`/`dr_scheduler.sh` hashes.
- For an existing stuck run, verify automatic terminal replay without deleting
  profiles, checkpoints, or DB rows.
