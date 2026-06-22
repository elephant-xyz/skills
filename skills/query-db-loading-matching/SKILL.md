---
name: query-db-loading-matching
description: Load county artifacts (appraisal, permits, Sunbiz, BBB) into the Neon Postgres query DB and cross-match records by parcel id and normalized address hash. Use when loading transformed data into Neon, reconciling row counts, linking permits or companies to parcels, or debugging missing query-db data.
metadata:
  author: elephant-xyz
---

# Query DB Loading & Matching

The query DB is the `elephant-query-db` package (sibling repo): Drizzle schema on Vercel
Neon, lexicon-aligned logical tables, full source data preserved in `source_payload`
columns. Design docs: `../elephant-query-db/docs/{schema-design.md,
data-load-and-matching-plan.md, lexicon-alignment.md, open-lexicon-gaps.md}`.

Consumers (Vercel apps, dashboards) use the `use-elephant-query-db` skill; this skill is
for the LOADING side.

## Connection

- Local scripts: `DATABASE_URL` from `../elephant-query-db/.env.local` (most oracle-node
  scripts take `--env-file` defaulting to that path). Get it via
  `vercel env pull --environment=development --scope elephant-xyz` on the `catalog`
  project and use the **plain `DATABASE_URL`** (`ep-mute-leaf` Neon), NOT
  `NEO_OPENDATA_DATABASE_URL` (`ep-snowy-union`, the deprecated NEO anti-pattern DB).
  Prefer the **`_UNPOOLED`** endpoint for bulk `COPY`.
- **AWS creds:** the loader scripts use the AWS SDK default credential chain and do NOT
  accept `--profile`. Export `AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1`
  before running, e.g. `AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 npm run
  load:bulk -- --tracks sunbiz`. Without this you get
  `Could not load credentials from any providers`.
- Lambdas: Secrets Manager ARN via `QUERY_DB_DATABASE_URL_SECRET_ARN`.

## Loading principles (non-negotiable)

1. **Idempotent merges only** — CSV/batch staging + `ON CONFLICT DO UPDATE` (see
   `elephant-query-db/src/loader/bulk.ts`, `permits.ts`). Any load must be safely
   re-runnable.
2. **Deterministic keys** — normalized parcel id for properties; permit number + source
   for permits; document number for Sunbiz.
3. **Keep `source_payload`** — never drop unmapped fields; lexicon gaps are logged in
   `open-lexicon-gaps.md`, not discarded.

## Load paths

- **Permits**: loaded inline by the permit-harvest worker per parcel (`loadToNeon`). For
  bulk/backfill loads use the loader scripts in `elephant-query-db`.
- **Appraisal**: from Structured Archive transform artifacts, per
  `data-load-and-matching-plan.md`. (A `query-db-loader-worker` Lambda is scaffolded in
  oracle-node but not implemented — bulk loads are currently script-driven.)
- **Sunbiz / BBB**: staged JSONL → loader scripts in `elephant-query-db`.

## Lee source prefixes & gotchas (verified 2026-06-22)

The loader CLI defaults are stale for Lee full-county. Always pass explicit prefixes:

- **Appraisal** — full-county run jobId = `lee-fullcounty-20260619`. Transformed artifacts
  live at `outputs/lee-property-first-seed/lee-fullcounty-20260619/row-<N>-folio-<folio>-parcel-<id>/<uuid>/transformed_output.zip`
  — i.e. **two** child levels (`row-N/` then `<uuid>/`) below the jobId, not one.
  `listAppraisalArtifacts` in `run-bulk-data-load.ts` was **fixed (2026-06-22, branch
  `fix/appraisal-two-level-nesting` in elephant-query-db)** to perform a SINGLE flat
  recursive S3 listing (filter keys ending in `transformed_output.zip`) instead of
  per-row Delimiter listings. The per-row approach produced ~6.6 artifacts/s (~21 h for
  501k); flat listing produces ~100/s (~80x faster).
  NEVER use bare `--appraisal-prefix outputs/` — it is the shared multi-county namespace
  (~11.1M folders) and the loader refuses it.
  NEVER use `--scope-manifest` for full-county — it narrows to a subset.
- **Sunbiz** — `--sunbiz-prefix permit-harvest/sunbiz-lee-corporate-quarterly-2026q2-expanded/lexicon-transform/business-registration-v1/classes/`
  (this default is correct; 379,467 `business_registration` records).
- **BBB** — the CLI default `permit-harvest/bbb/category-data/browser-harvest-v1/profiles/`
  is **EMPTY**. Real Lee BBB profiles (2,619, harvest complete) are at
  `--bbb-prefix permit-harvest/bbb/category-data/lee-county-permit-seeded/profiles/`.
- **Coverage snapshot of `lee-fullcounty-20260619` (2026-06-22):** 516,848 row folders,
  501,496 with `output.zip` (prepare), **431,339 with `transformed_output.zip`** — i.e.
  ~85.5k parcels still need a transform redrive (~70k transform-only, ~15k re-prepare).
  Do the redrive through `county-ingest-run` before declaring appraisal complete.

## Appraisal bulk loader — disk-bounded batch mode (2026-06-22)

The full `lee-fullcounty-20260619` run (431k artifacts) staged everything into one
local CSV that hit **106 GB and killed the disk** (`ENOSPC`). Fixed with a
`--batch-size N` flag (default **20000**, `0` = legacy single-CSV).

In batch mode the appraisal track processes N artifacts at a time:
stage → COPY → merge all tables → drop stage table → **delete CSV** → next batch.
Peak local disk = one batch CSV (~1-2 GB), never 106 GB.

Checkpoint file `appraisal-batch-checkpoint-n<N>.json` in the stage dir tracks
completed batch indices so re-runs resume from the first incomplete batch.
File is named by batch-size to prevent collisions between verify runs and production.

**Full Lee county appraisal load command:**
```bash
cd /path/to/elephant-query-db
nohup env AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 \
  pnpm run load:bulk -- \
  --tracks appraisal \
  --appraisal-prefix "outputs/lee-property-first-seed/lee-fullcounty-20260619/" \
  --batch-size 20000 \
  --concurrency 32 \
  >> .loader-runs/appraisal-batch-load.log 2>&1 &
```

**Monitor:**
```bash
grep -a '"event".*batch' .loader-runs/appraisal-batch-load.log | tail -20
ls -lh .loader-runs/bulk-staging/   # should have at most 1 CSV at a time
df -h .                              # disk must NOT drop toward 0
```

**Resume after interruption:** re-run the same command — the checkpoint file skips
already-committed batches automatically. Merges are idempotent (ON CONFLICT DO UPDATE).

Branch: `feat/appraisal-disk-bounded-batch-loader` (elephant-query-db)

## Bulk loader robustness — EPIPE fix (2026-06-22)

The original monolithic `BEGIN → COPY 6.5 GB → merge-all → COMMIT` failed with
`write EPIPE` after ~26 minutes: Neon's proxy drops TCP connections idle for >5 min,
and the connection went quiet in the gap between COPY completion and the first merge.

**What was changed in `elephant-query-db/scripts/run-bulk-data-load.ts`:**

1. **TCP keepalive** — every `pg.Client` now has `keepAlive: true`,
   `keepAliveInitialDelayMillis: 10_000`. `connectionTimeoutMillis` and
   `idleTimeoutMillis` on `Pool` do NOT prevent Neon's proxy teardown.

2. **Permanent stage table** — instead of `CREATE TEMP TABLE … ON COMMIT PRESERVE ROWS`,
   the loader creates `public.elephant_bulk_stage_<timestamp>` (a real table). TEMP tables
   are session-scoped and are gone if the connection drops; the permanent table survives.

3. **Per-table commits** — each logical table (e.g. `addresses`, `companies`,
   `business_registrations`) is merged in its own `BEGIN/COMMIT` on a fresh keepalive
   `Client`. No single transaction spans more than one table's merge.

4. **Checkpoint file** — after each table commits, the table name is written to
   `<stageDir>/<stageTableName>-checkpoint.json`. A re-run automatically skips
   already-committed tables (safe idempotent resume).

5. **`--stage-table` flag** — pass an existing permanent stage table name to skip the
   COPY entirely and resume only the merge phase. Useful when COPY succeeded but a merge
   failed later.

**Re-run after partial failure:**
```bash
# Point at the existing stage file (re-runs COPY + merge with checkpointing):
AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 npm run load:bulk -- \
  --tracks sunbiz \
  --phase load \
  --stage-file .loader-runs/bulk-staging/<existing>.csv

# OR reuse the already-COPY'd permanent stage table (skips COPY, merges only):
AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 npm run load:bulk -- \
  --tracks sunbiz \
  --phase load \
  --stage-file .loader-runs/bulk-staging/<existing>.csv \
  --stage-table elephant_bulk_stage_<timestamp>
```

## Neon compute — merge bottleneck at scale

The Neon endpoint used for loading (query-db default endpoint, `ep-mute-leaf`) was
fixed at **1 CU** by default. At 1 CU the `ON CONFLICT DO UPDATE` merge for 400k+
rows is the primary bottleneck. Raise autoscaling to **2–8 CU** in the Neon console
before a big merge run, then scale back after. The proper long-term fix is running the
loader in AWS (Lambda or EC2 in the same region as Neon), not on a laptop where
network latency compounds the merge time.

## Cross-source matching

Order of confidence (from `data-load-and-matching-plan.md`):

1. **Parcel id** — normalize both sides (strip punctuation/spacing; counties differ in
   appraiser vs permit-portal formats). This is the primary join.
2. **Normalized address hash** — fallback when parcel ids are absent (Sunbiz, BBB).
   Heuristic: only write FK links at high confidence; otherwise leave candidates
   unlinked for review.
3. **Permit→parcel linking caution**: link permits using the harvest request's target
   parcel evidence (`propertyFirstTarget`), not the parcel displayed on the permit page —
   permit portals sometimes display related/different parcels (caused a Lee repair job).

## Verification queries

After any load, reconcile:

```sql
-- per county/run
SELECT count(*) FROM properties WHERE county = '<county>';
SELECT count(*) FROM permits p JOIN properties pr ON p.property_id = pr.id WHERE pr.county = '<county>';
-- recent insert rate (monitoring)
SELECT count(*) FROM permits WHERE created_at > now() - interval '10 minutes';
```

Compare against S3 artifact counts and the seed row count; investigate any gap before
declaring a run complete. Check actual table/column names in
`elephant-query-db/src/schema/` — the schema evolves with the lexicon.
