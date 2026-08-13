# FTCTL DR Fleet Resource Admission Design

The Cloud orchestration design is maintained in `ablestack-cloud/docs/ftctl/609-dr-fleet-admission-and-protection-group-design-20260813.md`. This companion document fixes the FTCTL engine boundary.

## Runtime contract

- `full-seed` and `incremental` use separate host-local slot pools.
- A missing slot or NBD device returns exit code `97`, error `DR_RESOURCE_BUSY`, `retryable=true`, and leaves the scheduler alive.
- The scheduler publishes `WAITING_RESOURCE` and retries after the configured delay.
- `policy.bandwidthLimitMbps` is passed unchanged to the provider mover and enforced by the common extent patcher.
- Schedule jitter is deterministic by plan and cycle sequence. Its default is zero, so existing single-plan profiles are unchanged.
- Provider drivers continue to receive the established source/target locators. VMware to RBD continues to write with librbd; Cloud-managed VM execution continues to use the existing krbd storage path.

## Driver extension

Future VMDK to qcow2 and qcow2 to qcow2 drivers shall implement the same return and progress contract. They must not create a second admission implementation.

## Regression gates

1. Shell syntax and scheduler resource-slot smoke.
2. Extent patch bandwidth smoke.
3. Existing VMware mover and DR scheduler smoke suites.
4. Deployed VMware to ABLESTACK RBD full seed and incremental cycle.
5. Synthetic 10, 30, and 100 request admission tests prove bounded concurrency,
   retry, and eventual admission for both slot classes.
6. Real 10, 30, and 100 VM end-to-end qualification remains a separate release
   gate and must not be reported as passed without matching VM inventory and
   full seed, incremental, failure, and restart evidence.
