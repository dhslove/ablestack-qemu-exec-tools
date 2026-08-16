# V2K Cloud service-offering CPU speed handling

## Problem

The V2K Wizard used `1000` MHz as an implicit CPU-speed default and always
sent it as `details[0].cpuSpeed` to `deployVirtualMachineForVolume`.  A Cloud
service offering with a predefined CPU speed rejects that override even when
the migrated volume and every other deployment input are valid.

## Design contract

1. The selected Cloud service offering is authoritative for a positive
   `cpuspeed` returned by `listServiceOfferings`.
2. V2K omits `details[0].cpuSpeed` when the offering already defines the
   value.  It never rewrites the offering value.
3. V2K has no implicit CPU-speed default.  When the offering does not expose a
   positive value, V2K sends the operator's explicit `--cloud-cpu-speed` value
   only when one was supplied; otherwise the optional property is omitted.
4. Offering discovery is advisory.  A discovery failure must not block an
   otherwise valid migration because CPU speed is not a migration-integrity
   property.
5. If Cloud still reports that CPU speed is not customizable, V2K retries the
   synchronous deploy submission once without only
   `details[0].cpuSpeed`.  No async job id exists at this validation failure,
   so the retry cannot duplicate a submitted VM deployment.
6. Other Cloud API failures are not retried or weakened.

CPU count, memory, disk controller, disk size, firmware, and I/O policy retain
their existing behavior.  The change is deliberately limited to the optional
CPU-frequency override.

## Verification

The smoke contract covers predefined offering speed, explicit customizable
speed, omitted optional speed, the one-time compatibility retry, and the
no-retry path for unrelated API errors.  The release workflow runs the smoke
contract before building each Rocky V2K RPM.
