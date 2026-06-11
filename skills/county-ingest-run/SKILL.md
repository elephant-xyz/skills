---
name: county-ingest-run
description: Deploy and run the end-to-end property-first ingestion for an onboarded county - pilot batch first, then the full backpressure-aware seed-feeder run with concurrency ramp-up. Use when starting, scaling, resuming, or wrapping up a county ingestion run on AWS.
metadata:
  author: elephant-xyz
---

# County Ingest Run

Prerequisites: `bootstrap-oracle-infra` checks pass; appraisal onboarding, transform
validation, and the permit adapter are done for the county.

## Run shape

Property-first: each parcel flows appraisal-prepare → transform (Structured Archive) →
eligibility branch → permit harvest → Neon, individually. Input is ONLY the seed CSV
(never re-derive work from Neon), drip-fed by a self-requeuing seed-feeder SQS message
with backpressure — never dump the whole county into SQS at once (516k messages exceeds
retention and removes flow control).

## 1. Pilot (always first)

1. Pick 10-50 parcels from the seed covering usage-type variability (include commercial so
   the permit path is exercised, and residential to verify the skip path).
2. Use the one-shot enqueue script pattern (`scripts/enqueue-lee-appraisal-property-first-from-seed.mjs`,
   cloned/parameterized for the county) with `--limit`, a distinct `--job-id`
   (`<county>-property-first-pilot-<date>`), and `--dry-run` first.
3. Verify per parcel, in order: prepare zip → transform artifact → eligibility manifest →
   (eligible only) permit-list + extracted permit JSONs in S3 → rows in Neon
   (`properties`, permit tables) → completion-state object written.
4. Verify a permit-less parcel completes cleanly and a residential parcel stops after
   archive with a skip marker.

## 2. Full run

Send the seed-feeder message (type `<county>-property-first-seed-feeder`) to the
permit-harvest queue. Key message fields (see `validatePermitHarvestMessage()` for the
contract):

- `jobId` — `<county>-property-first-seed-all-<date>`; all S3 state is keyed by it
- `sourceCsvS3Uri` — `s3://counties-seeds/<county>.csv`
- `batchSize` (~100), `requeueDelaySeconds` (900), `sendDelayMs`
- `skipExistingNeon: true` — dedupe against already-loaded parcels
- `backpressureQueues` — caps per queue; starting point: workflow ≤250, prepare ≤5000,
  transform ≤100, property-first-permit ≤200
- output prefixes: seeds under `seed-inputs/<jobId>/`, workflow outputs under
  `outputs/<jobId>/`, permit artifacts under `permit-harvest/<jobId>/`

The feeder checkpoints at `permit-harvest/<jobId>/feeder-state.json` (row offset) and
self-requeues until `sourceExhausted`. Resume = send the same message again; the
checkpoint prevents re-queuing.

## 3. Ramp-up

1. Watch with `monitoring-county-ingestion` after each change; let each setting burn in
   10+ minutes before the next.
2. Raise prepare/transform event-source `MaximumConcurrency` stepwise (Lee: 6 → 50/50,
   ~8.5k prepare/hour). Keep SQS max concurrency ≤ Lambda reserved concurrency.
3. Keep permit worker concurrency low (2-4); county permit portals are the fragile link.
4. Check after every step: Lambda `Errors`/`Throttles` = 0, DLQ depth = 0, Neon insert
   rate moving, app-level prepare failure rate not climbing.

## 4. Failure handling

- DLQ messages: inspect, fix root cause, redrive (`scripts/auto-fix-queue.sh`,
  `scripts/resolve-error.sh`; error records in DynamoDB clear via `ElephantErrorResolved`).
- If ingest silently stalls, FIRST check event source mappings are still `Enabled` — a
  budget alarm once disabled them mid-run (`EmergencyStopEnabled` must stay `false`).
- AccessDenied from the feeder → seeds-bucket permission missing on the worker role
  (`SourceSeedBucketName` parameter).
- Geo-block/outage: prepare failures spike — pause (disable mapping), restore network/VPN
  or proxies, re-enable; SQS redelivery resumes work.

## 5. Wrap-up

- Feeder reports `sourceExhausted`; queues drain to 0; reconcile counts: seed rows vs
  archived artifacts vs Neon properties vs permit-eligible vs permits loaded. Record final
  numbers in `oracle-node/docs/<county>-county-findings.md`.
- Commit code/docs (never data) to a `<county>-property-first-ingest` branch.
