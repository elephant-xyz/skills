---
name: onboard-county
description: Orchestrate end-to-end onboarding of a new US county into the elephant oracle-node ingestion pipeline, sequencing discovery, seed data, appraisal, transform validation, permit adapter, run, and enrichment stages. Use when asked to onboard, ingest, or "do the same as Lee County" for a new county, or when unsure which county skill applies.
metadata:
  author: elephant-xyz
---

# Onboard County

End-to-end recipe for replicating the Lee County, FL ingestion for any county. Each stage
has a dedicated skill — read the stage skill before executing that stage. Work happens in
a checkout of `oracle-node` with sibling repos `elephant-query-db`,
`Counties-trasform-scripts`, and `lexicon`.

## Target outcome

Every parcel in the county: appraisal data scraped and transformed to lexicon (Structured
Archive in S3), commercial/industrial parcels enriched with per-parcel permit history, all
loaded into the Neon query DB, joinable with Sunbiz (FL) and BBB enrichment — running
24/7 on AWS without harming the county's websites.

## Stage checklist

Track progress in `oracle-node/docs/<county>-county-findings.md`.

1. **Infra** — `bootstrap-oracle-infra`: verify stacks, buckets, secrets, Neon. Bootstrap
   anything missing before county work starts.
2. **Discovery** — `county-discovery`: appraiser portal, permit vendor, parcel id formats,
   usage-type vocabulary, bulk sources, anti-bot posture. Output: findings doc + sample
   captures.
3. **Seed** — `county-seed-data`: parcel roll → `s3://counties-seeds/<county>.csv`.
4. **Appraisal** — `county-appraisal-onboarding`: browser flow, per-county prepare queue,
   transform scripts (reuse from Counties-trasform-scripts when present), eligibility
   usage-type mapping. Single-parcel smoke test through the state machine.
5. **Transform validation** — `validate-county-transform`: 10-20 diverse parcels; prove
   100% field coverage vs raw captures; log lexicon gaps. Gate: do not scale before this
   passes. (Authoring new handlers: `transform-v2-builder`.)
6. **Permit adapter** — `county-permit-adapter`: `<county>-<vendor>.mjs` module, message
   types, local-runner tests, deploy, single-message smoke test.
7. **Pilot run** — `county-ingest-run` §1: 10-50 parcels end-to-end, verify every
   artifact class plus Neon rows, including residential-skip and permit-less paths.
8. **Full run** — `county-ingest-run` §2-4: seed-feeder message with backpressure,
   concurrency ramp-up, failure handling. Monitor continuously with
   `monitoring-county-ingestion`.
9. **Enrichment** — `sunbiz-corporate-ingest` (FL counties; only the ZIP list is new) and
   `bbb-harvest` (national; refresh as needed).
10. **Reconcile & wrap-up** — `query-db-loading-matching` verification queries; record
    final counts; commit code/docs (never data) on a `<county>-property-first-ingest`
    branch.

## Ground rules (learned from the Lee run)

- Extract as much data as possible — raw HTML always captured; unmapped fields preserved
  in `source_payload`; lexicon gaps logged, never dropped.
- Input of record is the seed CSV; never re-derive work from the query DB.
- Everything idempotent: stable S3 keys, skip-existing checks, feeder checkpoint,
  `ON CONFLICT` merges. Resume = re-send the same message.
- Be gentle with county portals: low permit concurrency (2-4), stepwise ramp-up with
  burn-in, back off on timeouts.
- Never dump a whole county into SQS; use the backpressure-aware seed feeder.
- If ingestion stalls silently, check event-source mappings first (budget-handler
  incident); `EmergencyStopEnabled` stays `false`.
- Prioritize commercial properties when asked: sort the seed CSV; the eligibility branch
  already limits permit harvest to commercial/industrial usage types.
