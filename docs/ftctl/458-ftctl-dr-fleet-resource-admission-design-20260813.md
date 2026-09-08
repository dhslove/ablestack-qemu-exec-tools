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

## Reserved NBD capacity and retry identity addendum (2026-08-14)

VMware to ABLESTACK replication exclusively owns `/dev/nbd16` through
`/dev/nbd31`. The RPM installs `/etc/modprobe.d/ablestack-ftctl-nbd.conf` with
`nbds_max=32 max_part=16`; package installation reloads an undersized module
only when no NBD PID is active. It never falls back to `/dev/nbd0` through
`/dev/nbd15`, which remain available to v2k and other host tools.

`ftctl_vmware_mover_nbd_capacity_json` publishes the configured range, actual
module capacity, present/free/quarantined counts, and an explicit error code.
`dr-plan-apply --dry-run` rejects a permanently undersized host, while each
changed-data patch rechecks that the reserved range is both configured and has
free capacity before opening VDDK/NBD endpoints.

Return code 97 is a retryable wait, not a new replication cycle. The scheduler
persists `pending_resource_sequence`, cycle type, owner run, and retry attempt,
then reuses the same sequence with exponential backoff from 15 to 300 seconds.
The pending identity is cleared only after success or a non-retryable terminal
failure.

| Area | AS-IS | TO-BE |
|---|---|---|
| Kernel NBD capacity | Runtime `modprobe` cannot enlarge an already loaded 16-device module | RPM owns a permanent 32-device module contract and verifies the actual range |
| Device selection | Reserved range exists in configuration but may be absent | Only nbd16-31 are eligible; missing devices fail preflight |
| Resource retry | Every rc=97 retry can advance the cycle sequence | One waiting operation retains one cycle sequence and run identity |
| Retry cadence | Fixed 15-second retries amplify fleet contention | Bounded exponential backoff, 15-300 seconds |
| Existing success path | VMware mover writes RBD through librbd | Unchanged; target VM execution continues through Cloud-managed krbd |

## Shared capacity projection addendum (2026-08-14)

NBD capacity is implemented in `dr_nbd.sh`, which is loaded by both the
standalone VMware mover and the main `ablestack_vm_ftctl` command. This keeps
data-path admission and `dr-status` projection on the same implementation and
prevents Cloud group preflight from treating a healthy host as
`DR_NBD_CAPACITY_STATUS_UNAVAILABLE`.

The fleet smoke test loads the shared module independently and validates its
structured invalid-capacity response. A deployed `dr-status --json` must
publish `nbd_capacity.configured`, `ready`, reserved range, and device counts
without shell warnings before protection-group actions are enabled.

| Area | AS-IS | TO-BE |
|---|---|---|
| Capacity implementation | Mover-private function unavailable to `dr-status` | Shared `dr_nbd.sh` contract loaded by both paths |
| Cloud preflight | Healthy host can appear as status unavailable | Live capacity JSON is returned and evaluated consistently |
| Regression coverage | Mover execution validates capacity only | Shared module and status projection are build and deployment gates |
