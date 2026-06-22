---
name: county-ingest-run
description: Deploy and run the end-to-end property-first ingestion for an onboarded county - pilot batch first, then the full backpressure-aware seed-feeder run with concurrency ramp-up. Use when starting, scaling, resuming, or wrapping up a county ingestion run on AWS.
metadata:
  author: elephant-xyz
---

# County Ingest Run

Prerequisites: `bootstrap-oracle-infra` checks pass; appraisal onboarding, transform
validation, and the permit adapter are done for the county.

Run parameters (AWS profile/region, job-id, pilot vs full scope, seed CSV) come from the
`onboard-county` intake — don't re-ask what's already established. If entered directly
without that context, ask for the missing parameters once before starting: a run sends
sustained traffic to county websites and should never start on guessed inputs.

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

## 3. Full-coverage permit redrive

Use when a run was first gated to commercial/permit-priority appraiser usage types
and the product decision changes to all-parcel permit coverage.

1. Widen eligibility deliberately. For Lee, set
   `PROPERTY_FIRST_PERMIT_ELIGIBLE_USAGE_TYPES=__ALL__` on both the transform worker
   and the permit-harvest worker after deploying code that treats `__ALL__` as full
   coverage. Empty/unset is NOT full coverage; it falls back to the default
   commercial/permit-priority list.
2. Do not replay the whole seed through appraisal if transformed outputs already
   exist. Redrive from the existing
   `outputs/<jobId>/**/property_first_permit_eligibility.json` manifests where
   `shouldEnqueue=false`.
3. Use the checkpointed helper (`scripts/redrive-lee-full-coverage-permits.mjs` for
   Lee) in dry-run mode first, then a 50-parcel pilot, then the full run. Enqueue mode
   requires `--ack-workers-full-coverage` after verifying both workers are deployed and
   configured with `PROPERTY_FIRST_PERMIT_ELIGIBLE_USAGE_TYPES=__ALL__`. Messages must
   keep `skipExisting=true`, `skipCompleted=true`, `loadToNeon=true`, and
   `loadAppraisalToNeon=true` unless a fresh Neon reconciliation proves appraisal
   loading should be skipped.
4. The helper checkpoint belongs under the permit-harvest job prefix, e.g.
   `permit-harvest/<jobId>/full-coverage-redrive-state.json`. Resume by rerunning the
   same command; do not reset the checkpoint unless intentionally starting over. The
   helper advances past malformed manifests and records them in checkpoint failure
   metadata so one poison-pill object cannot block the county-scale run.
5. Proxy capacity is required for a ~14-day Lee-scale run. Load real proxy credentials
   before increasing permit concurrency beyond the direct-egress baseline. The
   permit worker supports `PERMIT_HARVEST_PROXY_URL=<user:pass@host:port>` or
   `PERMIT_HARVEST_PROXY_URLS` as a comma/newline-delimited list; without these env
   vars, permit harvest uses direct Lambda egress even if the shared proxy table has
   entries.
6. Keep the redrive bounded by queue backpressure. Do not enqueue hundreds of
   thousands of SQS messages at once; feed in batches and let the permit worker drain.

## 3b. Transform-only redrive

Use when a job has `output.zip` (prepare complete) for a large number of parcels
but the transform stage failed or was never reached — producing no
`<uuid>/transformed_output.zip`. This avoids re-scraping the appraisal site.

The verified mechanism is **direct Lambda invocation** of the TransformWorkerFunction
with `directInvocation: true` (same path used by the error-resolver). No SQS task
token, no permit harvest, no SF execution needed.

Script: `scripts/redrive-lee-transform-only.mjs` (Lee / `lee-fullcounty-20260619`).
Adapt `--job-id`, `--bucket`, `--transform-fn` for other counties.

### Workflow

1. **Dry-run first** — enumerates every row folder that has `output.zip` but no
   `<uuid>/transformed_output.zip`. Reports target count and estimated duration.
   Full flat S3 scan (~2 min for 516k rows / 2M keys):
   ```
   AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 \
     node scripts/redrive-lee-transform-only.mjs --dry-run
   ```
2. **Pilot (--limit 20)** — live-invoke a bounded set, verify each wrote
   `transformed_output.zip`:
   ```
   AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 \
     node scripts/redrive-lee-transform-only.mjs --limit 20
   ```
3. **Full run detached** — nohup into `.redrive-logs/`; survives shell exit:
   ```
   mkdir -p oracle-node/.redrive-logs
   nohup env AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 \
     node scripts/redrive-lee-transform-only.mjs \
     > oracle-node/.redrive-logs/transform-redrive.log 2>&1 &
   echo "PID: $!"
   ```

### Key parameters
- `--concurrency <n>` — parallel Lambda invocations. **Use ≤20 for direct invocations.**
  At concurrency 100, requests get signed then queue-delayed past the 5-minute SigV4
  window → `Signature expired` failures for every queued request. The Lambda fn has no
  reserved-concurrency cap but the SigV4 clock is the real ceiling.
- `--limit <n>` — stop after N parcels (0 = unlimited).
- `--checkpoint-every <n>` — write S3 checkpoint every N completed parcels (default 50).
- `--reset-checkpoint` — restart from row 0, ignoring existing checkpoint.

### Checkpoint
Written to `s3://<bucket>/permit-harvest/<jobId>/transform-redrive-state.json`.
Resume a partial run by re-running the same command (checkpoint skips already-done rows
automatically). Full run at concurrency ≤20 takes ~5.8 h for ~70k missing parcels.

### Verified pilot (2026-06-22)
20/20 parcels succeeded at rows 200000-200019. Each wrote
`<row>/<executionId>/transformed_output.zip` + `property_first_permit_eligibility.json`.
Per-parcel duration 24-39 s (avg ~30 s). `directInvocation=true` confirmed transform-only
— no permit harvest triggered.

### Monitoring
```bash
# Watch the log (detached run)
tail -f oracle-node/.redrive-logs/transform-redrive.log

# Check checkpoint state
aws s3 cp s3://<bucket>/permit-harvest/<jobId>/transform-redrive-state.json - \
  | python3 -m json.tool

# Resume after interruption — just re-run the same full-run command
```

### After the transform redrive completes
Load results to Neon via the `query-db-loading-matching` skill.

### Heavy-parcel transform tail
Record-heavy pages can exceed the 900 s Lambda max even at 10 GB memory. These are
genuinely unrecoverable via Lambda. Document them as dead/slow folios (see the
re-prepare redrive residual section below). Final county count = source count −
documented dead folios.

## 3c. Re-prepare redrive (missing output.zip)

Use when a job has row folders where prepare NEVER succeeded — no `output.zip`
at all (only `county_prep/input.zip` + `seed_output.zip`). These need the full
prepare→transform path re-run against the county site (LeePA), not a transform-only
redrive. Common causes: prepare-stage timeouts (LeePA detail pages > 90s),
geo-blocks, or retired/non-existent folios.

Do NOT re-run the whole seed — that re-scrapes the ~500k already done. Enqueue
ONLY the missing rows, preserving each parcel's ORIGINAL source row number so the
re-prepared `output.zip` + `<uuid>/transformed_output.zip` land in the SAME
existing `row-<N>-folio-..-parcel-..` folder (the folder name is keyed by row
number; a new row number would create an orphan folder).

### Workflow

1. **Identify missing rows** — flat S3 scan of the job prefix; a row folder is a
   target when it has NO `output.zip`. Map folder → row number via
   `^row-(\d+)-`. Helper: `scripts/identify-lee-missing-prepare.mjs` (writes
   `/tmp/lee-missing-prepare-rows.txt` and an audit seed CSV).
   ```
   AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 \
     node scripts/identify-lee-missing-prepare.mjs
   ```
2. **Enqueue only those rows** through the SAME workflow path as the original run,
   reading the FULL seed (so `sourceRowNumber` matches the existing folders) and
   filtering with `--only-rows-file`. Use the existing `--job-id` so outputs land
   in the same prefix:
   ```
   AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 \
     node scripts/enqueue-lee-appraisal-property-first-from-seed.mjs \
       --source-csv-s3-uri s3://counties-seeds/lee.csv \
       --job-id lee-fullcounty-20260619 \
       --only-rows-file /tmp/lee-missing-prepare-rows.txt \
       --include-existing-neon --limit 0 \
       --concurrency 4 --send-delay-ms 100
   ```
   `--only-rows-file` is the scope fence — there is no per-row re-scrape of the
   already-done ~500k. Use `--include-existing-neon` to avoid hitting the live
   Neon DB during a concurrent LOAD; the only-rows list is already the exact scope.
3. **Pilot first** — slice the first ~30 row numbers into a pilot file, `--dry-run`
   to confirm `enqueued`/`skippedNotInOnlyRows` counts and that the generated seed
   key equals the existing folder name, then live-enqueue and verify `output.zip`
   + `<uuid>/transformed_output.zip` appear in those folders.
4. **Full run** — re-run with the full `--only-rows-file`. This rides the live
   prepare→transform Lambdas (event-source mappings stay enabled); throughput is
   gated by `WorkflowStarterFunction` concurrency and prepare-queue concurrency,
   NOT by this script. Throttle the enqueue (concurrency 4, send-delay) so SQS
   isn't flooded; the queue + backpressure do the rest. ~15k missing at the
   ~8.5k-prepare/hour rate ≈ 2-3 h, not days (days = the permit/Accela scrape).
5. **Residual = dead folios.** Re-run the identify scan after the run; rows that
   still lack `output.zip` are genuinely retired/non-existent folios that will
   never scrape. Document them; do not chase forever. Achievable full-county count
   = source − documented dead folios.

## 4. Ramp-up

1. Watch with `monitoring-county-ingestion` after each change; let each setting burn in
   10+ minutes before the next.
2. Raise prepare/transform event-source `MaximumConcurrency` stepwise (Lee: 6 → 50/50,
   ~8.5k prepare/hour). Keep SQS max concurrency ≤ Lambda reserved concurrency.
3. Keep permit worker concurrency low (2-4); county permit portals are the fragile link.
4. Check after every step: Lambda `Errors`/`Throttles` = 0, DLQ depth = 0, Neon insert
   rate moving, app-level prepare failure rate not climbing.

## 5. Failure handling

- DLQ messages: inspect, fix root cause, redrive (`scripts/auto-fix-queue.sh`,
  `scripts/resolve-error.sh`; error records in DynamoDB clear via `ElephantErrorResolved`).
- If ingest silently stalls, FIRST check event source mappings are still `Enabled` — a
  budget alarm once disabled them mid-run (`EmergencyStopEnabled` must stay `false`).
- AccessDenied from the feeder → seeds-bucket permission missing on the worker role
  (`SourceSeedBucketName` parameter).
- Geo-block/outage: prepare failures spike — pause (disable mapping), restore network/VPN
  or proxies, re-enable; SQS redelivery resumes work.

## 6. Wrap-up

- Feeder reports `sourceExhausted`; queues drain to 0; reconcile counts: seed rows vs
  archived artifacts vs Neon properties vs permit-eligible vs permits loaded. Record final
  numbers in `oracle-node/docs/<county>-county-findings.md`.
- Commit code/docs (never data) to a `<county>-property-first-ingest` branch.
