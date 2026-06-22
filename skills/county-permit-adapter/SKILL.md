---
name: county-permit-adapter
description: Build a new county's permit-portal harvester for the oracle-node permit-harvest worker, by adapting the Lee Accela adapter or writing a new vendor module, including source throughput checks and bulk-harvest vs runtime-retrieval decisions. Use when onboarding a county's permit portal, adding permit message types, or debugging per-parcel permit harvest for a county.
metadata:
  author: elephant-xyz
---

# County Permit Adapter

The permit-harvest worker (`workflow/lambdas/permit-harvest-worker/`) is a single Lambda
routing SQS messages by `type`. County adapters are modules; Lee's Accela adapter
(`lee-accela.mjs`) is the template. Pattern: copy-and-adapt into `<county>-<vendor>.mjs`
with `<county>-*` message types.

## What an adapter must provide

Study `lee-accela.mjs` + the `lee-property-first-permit-parcel` handler in `index.mjs`:

1. **Parcel search** — given a parcel id, find that parcel's permit records on the portal.
   Include a `normalizeParcelSearchValue` equivalent: appraisal parcel format usually
   differs from the permit portal's format (punctuation, separators, numeric-only).
2. **Permit list extraction** — record numbers, types, statuses, detail links; write a
   permit-list JSON to S3.
3. **Detail capture** — per permit: raw HTML to S3 + extracted JSON (status, dates, work
   location, description, contractors, inspections, fees, related records). Extract
   everything visible; fields without a lexicon home stay in the payload (see
   `validate-county-transform` class-(c) policy).
4. **Stable S3 keys + resume** — deterministic keys (`safeKeyPart()` for parcel ids),
   `skipExisting`/`skipCompleted` checks, per-parcel state JSON under
   `<prefix>/<county>/property-first-state/`. Work must be re-runnable without duplication.
5. **Neon loading** — map extracted permits to `@elephant-xyz/query-db` rows (Lee:
   `mapLeePermitDetail` + CSV staging + `ON CONFLICT DO UPDATE`). Link permits to the
   REQUESTED parcel via explicit target evidence (`propertyFirstTarget`), never via
   whatever parcel the detail page happens to display — Accela detail pages sometimes show
   a different parcel, which corrupted early Lee loads.

## Wiring steps

1. Create `workflow/lambdas/permit-harvest-worker/<county>-<vendor>.mjs` (copy
   `lee-accela.mjs` for Accela counties; for other vendors keep the same exported surface
   but reimplement navigation — Palm Beach uses pbc.gov ePZB guest endpoints which need a
   Playwright/Puppeteer session first, curl is blocked).
2. Register message types in `index.mjs`:
   - `<county>-property-first-permit-parcel` (handler)
   - `<county>-property-first-seed-feeder` (or generalize the existing feeder; it is
     parameterized by message body — source CSV, prefixes, queue URLs, backpressure)
   - add validation in `validatePermitHarvestMessage()`
3. S3 layout: `<prefix>/<county>/{permit-lists,raw/permit-details,extracted/permits,property-first-state}/…`.
4. State machine: `workflow/state-machines/elephant-express.asl.yaml`'s
   `EnqueuePropertyFirstPermit` currently sends `lee-property-first-permit-parcel`; the
   message type must be derived per county (parameterize via the workflow message rather
   than hardcoding a second county branch).
5. Browser bootstrap is shared: reuse `createBrowser`/`createConfiguredPage` from the
   worker (Chromium layer, 4 GB Lambda).

## Testing before deploy

- Use the local runner pattern (`scripts/harvest-lee-permits-by-parcel.mjs`) — clone it
  per county for local Puppeteer runs against a handful of parcels, including:
  a parcel known to have permits, a permit-less parcel (must complete cleanly, not retry),
  and a parcel whose detail page shows extra/related records.
- Add a benchmark mode or short probe run before any full harvest. Measure permit search,
  list extraction, detail capture, session bootstrap, retry/failure rate, and bytes written
  for a representative parcel sample. Estimate countywide elapsed time from eligible parcel
  count, expected permits per parcel, measured latency, safe concurrency, required delays,
  and retry overhead.
- `npm run typecheck` and `npm run test` (worker has vitest suites — add county tests
  mirroring `tests/workflow/lambdas/permit-harvest-worker/lee-accela.test.mjs`).
- Deploy worker code, send ONE SQS message manually, watch logs.

## Throughput rules

- Start `MaximumConcurrency` at 2; raise one step at a time while watching for portal
  timeouts. Lee Accela degraded above ~4; assume new portals are equally fragile.
- Before scaling beyond the pilot, record the portal's safe concurrency and the estimated
  full permit-download time in the county findings doc. If the estimate is more than
  48 hours, stop and ask whether permits should be downloaded anyway, ingested into the
  query DB, or retrieved at runtime. For runtime retrieval, ask which app/service owns it
  and whether lookup should use direct portal/API calls, server-side scraping, cache,
  queued background fetch, or another pattern.
- Per-record page-wait timeouts that fail an entire batch are worse than skipping —
  follow the worker's partial-batch-response pattern, and prefer recording a failure entry
  over throwing.
- DLQ has `maxReceiveCount: 5`; check it after any deploy.

## Persist your work

Adapter + worker changes are committed in `oracle-node` on the county branch. Anything
that lives outside oracle-node's deploy path — local runner scripts, portal exploration
notes, endpoint/session documentation — gets committed and PR'd to
`github.com/elephant-xyz/Counties-trasform-scripts` under `<county>/` (`gh pr create`)
so it isn't lost when this machine moves on.
