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
   The same suite kills a slot holder and verifies that the kernel flock is
   released so a restarted worker continues without manual lock cleanup.
6. Real 10, 30, and 100 VM end-to-end qualification remains a separate release
   gate and must not be reported as passed without matching VM inventory and
   full seed, incremental, failure, and restart evidence.

## Test deployment evidence

- GitHub Actions run: `31710261670`
- Source commit: `5937d9b7e58e5df6903a80c42afa54456e1e6ea5`
- Artifact: `ablestack_vm_ftctl-0.9.5-1.noarch.rpm`
- SHA256: `c3e96eac9cf71992a740679bfb82fd9d5a86d4955cd9f97dcbb4a2c735eb9b85`
- Deployed hosts: `10.10.32.1/2/3`, `10.10.22.1/2/3`
- Post-deployment checks: Mold Agent active, FTCTL timer active, slot limit,
  retryable NBD, and bandwidth markers present; no recent slot owner remained.
