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
2. **Deterministic keys** — **folio (`request_identifier`) for parcels/properties** (the
   true 1:1 key; do NOT key on the digits-only normalized parcel id — it collapses
   STRAPs with letters, see the parcel-id warning above); permit number + source for
   permits; document number for Sunbiz.
3. **Keep `source_payload`** — never drop unmapped fields; lexicon gaps are logged in
   `open-lexicon-gaps.md`, not discarded.

## ⚠️ Parcel-id normalization collapses distinct parcels — key on the folio (2026-06-23)

**BUG.** The loader's `parcels` conflict key used the **digits-only normalized**
`parcel_identifier`. `normalizeParcelIdentifier` strips **all non-digit characters**, and
the conflict key was `(jurisdiction_key, parcel_identifier)`. This **silently collapses
distinct parcels whose STRAP contains letters**:

- Lee condo units `…0001A` / `…0001B` / `…0001C` (different owners) all normalize to
  `…0001` → one row.
- Mid-string letters `…9A0` / `…9B0` / `…9C0` all normalize to `…90` → one row.

Lee impact: **516,841 distinct STRAPs → only 485,599 digits-only keys → ~31,242 distinct
parcels silently lost.** True count ≈ **512,353**, not the **481,111** that loaded. It
also produced **20,926 orphaned `properties` (parcel_id NULL)**.

**FIX (branch `fix/parcel-id-folio-key`, elephant-query-db).** Key `parcels` on the
**folio (`request_identifier`)** — the true 1:1 unique key — plus a unique index. Child
tables already resolve their parent FK by the folio-based `source_record_key`, so this
aligns parents and children on the same key.

**RULE — validate by folio, never by normalized parcel id.** Always validate the
distinct-parcel count vs source **BY FOLIO (`request_identifier`)**. Do **not** compare on
the normalized `parcel_identifier`, and do **not** raw-string-compare the parcel id — a
raw string compare gives false mismatches. After applying the key fix, a **clean re-load
is required**: a plain re-run keeps colliding on the old key (merges are idempotent, so
they update the already-collapsed rows instead of un-collapsing them).

## ⚠️ Clean re-load: FK-safe clear — NEVER `TRUNCATE … CASCADE` the shared tables (2026-06-24)

A clean re-load needs the appraisal slate emptied first. **Do NOT `TRUNCATE … CASCADE`.**
`addresses`, `companies`, `people` are **shared** across all tracks: Sunbiz/BBB FK into them,
and the permit child tables (`permit_links`/`events`/`fees`/`contacts`/`custom_fields`,
`inspections`) FK into `property_improvements`. A `TRUNCATE CASCADE` on the shared/parent
tables wiped **Sunbiz (379,449) + BBB (2,619) + all permit children** — recovered only via a
Neon point-in-time restore. (The naive "truncate the 20 appraisal tables" list is itself
unsafe: it includes `property_improvements`, which permits depend on.)

**RULE — clear by source, in reverse FK order, batched:**
- `DELETE … WHERE source_system='lee_appraiser'` per appraisal table, in the **reverse** of
  `APPRAISAL_TABLE_ORDER`, **skipping `addresses`/`companies`/`people` entirely** (leave the
  shared rows; the idempotent merge re-handles them; orphaned shared rows are harmless —
  every child FK into them is `ON DELETE SET NULL`).
- Deleting `property_improvements WHERE source_system='lee_appraiser'` is safe — it does NOT
  touch the `lee_accela` rows the permit children cascade off. Never delete it by parcel/property.
- **Batch the deletes** (chunk via `ctid LIMIT 50000` in a loop): the appraisal child tables
  are huge (`property_valuations` ~14.8M, `layouts` ~5.5M, `files` ~3.3M) — a single statement
  locks tens of millions of rows. Batched = bounded + resumable.
- Ready-made: `elephant-query-db/scripts/clear-appraisal-source.ts`.
- **Perf gotcha:** deleting `property_improvements` is the slow step — each row delete does an
  FK-cascade check against the 6 permit child tables (`permit_links`/`events`/`fees`/`contacts`/
  `custom_fields`, `inspections`), and without an index on their `property_improvement_id` FK
  column that's a scan per delete (observed ~50k rows / ~6 min on prod). Add those FK-column
  indexes (or VACUUM/analyze) before a large clear to avoid a multi-hour `property_improvements`
  delete.

## Running the re-load durably — serial Fargate, not the laptop, not EC2 (2026-06-24)

The full re-load is multi-hour. Don't run it on a laptop (sleep/network = lost run).

- **EC2 is blocked** on the oracle-node account: on-demand **and** Spot vCPU are both capped at
  **1**; every other family **0**. A quota case may be open but ungranted — don't wait on it.
- **Fargate has a separate quota (6 vCPU, available)** and no 15-min limit (the clear + serial
  merge move tens of millions of rows — too heavy for Lambda).
- **The load MUST stay serial.** The appraisal loader interleaves stage+merge per batch and
  writes the shared parents (`addresses`/`companies`/`people`/`parcels`). **Running it in
  parallel deadlocks on those parents** — that is the cause of the earlier ~30,851-parcel loss.
  So: ONE Fargate task, the existing loader unchanged, `--batch-size 20000`.
- **Pattern shipped:** `elephant-query-db/infra/appraisal-reload/` — pure-CloudFormation SAM
  app (ECS Fargate + Step Functions), `Dockerfile.reload`, entrypoint
  (`scripts/reload-appraisal-entrypoint.sh`: migrate → clear → load → validate, with a `STEP`
  env for read-only smoke tests). DB URL via Secrets Manager; use the **direct/unpooled**
  `ep-mute-leaf` endpoint (COPY + the permanent stage table need session semantics).
- **Gotchas:** the IAM user lacks the SAM serverless-transform macro → use **pure CloudFormation**
  (no `Transform:`). `package-lock.json` is out of sync (missing esbuild) → the Dockerfile uses
  `npm install`, not `npm ci`. Fargate `command` overrides become *args* to an `ENTRYPOINT`
  (they don't replace it) → drive single steps via the `STEP` env, not a command override.
- **The Fargate wrapper was Lee-hardcoded even after the loader (#9) became county-generic
  (fixed 2026-07-01).** Two landmines: (a) the entrypoint's `build_load_args` didn't pass
  `--jurisdiction-key`, so the loader fell back to its `lee_appraiser` default and **wrote a new
  county's parcels under Lee's namespace** (collision on `(jurisdiction_key, request_identifier)`);
  (b) `clear-appraisal-source.ts` deleted a hardcoded `source_system='lee_appraiser'`, so a new-county
  run's clear step **would wipe Lee**. Now county-generic + multi-track:
  - `JURISDICTION_KEY` scopes the clear (`CLEAR_SOURCE_SYSTEM` overrides it), the loaded rows
    (`--jurisdiction-key`), and the folio validation (`validate-appraisal-folio.ts` now counts
    `parcels WHERE source_system = JURISDICTION_KEY`, not a global count). Default `lee_appraiser`.
  - `TRACKS` (default `appraisal`) → `--tracks`; optional `SUNBIZ_PREFIX`/`BBB_PREFIX` →
    `--sunbiz-prefix`/`--bbb-prefix`, so ONE task can load appraisal+sunbiz+bbb for a county.
  - `EXPECT_LETTER_STRAPS` (default `true`, Lee) gates the letter-STRAP regression guard; set `0`
    for numeric-folio counties (e.g. Palm Beach) or validate false-fails on `letter_straps == 0`.
  - `template.yaml` params `JurisdictionKey`/`Tracks`/`SunbizPrefix`/`BbbPrefix`/`SkipClear`/
    `ExpectLetterStraps` wire straight into the container env. **All defaults preserve Lee byte-for-byte.**
- **For a NEW county you MUST:** set `JURISDICTION_KEY=<county>_appraiser`, use `SKIP_CLEAR=1`
  (a fresh county has nothing to clear and the loader upsert is idempotent — never clear with
  Lee's key), and override `APPRAISAL_PREFIX` + `EXPECTED_PARCELS`. e.g. Palm Beach:
  `JURISDICTION_KEY=palm_beach_appraiser SKIP_CLEAR=1 EXPECT_LETTER_STRAPS=0`
  `APPRAISAL_PREFIX=outputs/palm-beach-property-first-seed/palm-beach-property-first-seed-all-20260630/`
  `EXPECTED_PARCELS=654530`; add sunbiz+bbb with `TRACKS=appraisal,sunbiz,bbb` + their prefixes.
  This is a PR to **elephant-xyz/skills** (authoring repo) — sync the change into the oracle-node
  `.agents/skills/` mirror too.

## Load paths

- **Permits**: loaded inline by the permit-harvest worker per parcel (`loadToNeon`). For
  bulk/backfill loads use the loader scripts in `elephant-query-db`.
- **Appraisal**: from Structured Archive transform artifacts, per
  `data-load-and-matching-plan.md`. (A `query-db-loader-worker` Lambda is scaffolded in
  oracle-node but not implemented — bulk loads are currently script-driven.)
- **Sunbiz / BBB**: staged JSONL → loader scripts in `elephant-query-db`.

## County parameterization (multi-county)

- **Pass `--jurisdiction-key <county>_appraiser` to BOTH `run-data-load.ts` and
  `run-bulk-data-load.ts`** (default is `lee_appraiser`). The `parcels` conflict key is
  `(jurisdiction_key, request_identifier)`, so the wrong key cross-contaminates counties.
- **Property-first 2-level outputs** (`row-N/<uuid>/`) load via `load:bulk` (recursive),
  NOT `load:data`.
- **Filebase upload checkpoint is per-bucket** — it was a single shared file → cross-county
  contamination; scope the checkpoint by bucket.
- **Geometry caveat:** confirm the transform's geometry output (`geometry_*.json`) actually
  maps into the `geometries` table at load — a Palm Beach pilot load wrote `geometries: 0`.
  If empty, fix the loader mapping, else NEO has no maps.

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

## Appraisal batch merge — index and planner hints (2026-06-23)

**Problem:** Each 20k-parcel batch was taking 20–30 min. The FK-resolution JOIN in
`buildBulkMergeSql` probes parent tables on `source_record_key` alone, but the existing
unique indexes are composite `(source_system, source_record_key)`. `source_record_key`
is the trailing column, so it cannot serve as an index-seek probe — the planner falls back
to parallel Hash Joins with full table scans. With default `work_mem=4MB` and
`random_page_cost=4`, the addresses hash (979k rows) spilled across 16 disk batches:
18,178 ms just for that one join. Total join CTE: **20,874 ms per batch**.

**Fix — three parts, all required:**

1. **Single-column indexes** on every parent/reference table (`addresses`, `parcels`,
   `properties`, `property_improvements`, `companies`, `people`, `deeds`). Use
   `CREATE INDEX CONCURRENTLY` — safe on a live running load:
   ```sql
   CREATE INDEX CONCURRENTLY IF NOT EXISTS addresses_source_key_only_idx
     ON public.addresses (source_record_key);
   -- repeat pattern for parcels, properties, property_improvements, companies, people, deeds
   ```
   See `elephant-query-db/migrations/0004_bulk_merge_perf_indexes.sql` for all 7 indexes.

2. **Session planner hints** in `mergeOneTable()` — set BOTH before each merge, not just one:
   ```ts
   await client.query("SET work_mem TO '128MB'");     // eliminates disk spill
   await client.query("SET random_page_cost TO 1.1"); // Neon = NVMe SSD; default 4 forces Hash
   ```
   The indexes alone are not enough: with `random_page_cost=4` the planner still chooses
   Hash joins. Both settings together make it pick Nested Loop + index seeks.

3. **VACUUM ANALYZE** on parent tables after mass inserts — clears dirty visibility maps,
   reducing heap fetches from ~46k to near zero for index-only scans.

**Result:** join CTE 20,874 ms → **270 ms (~77× speedup)**.

**Remaining floor:** `INSERT … ON CONFLICT` into `taxes` / `property_valuations` (5M rows,
8–10 GB each, ~675k rows/batch) is IO-bound unique-index maintenance. This is a Neon CU
throughput issue, not a query-plan issue — more CU helps; planner hints don't.

Branch: `feat/appraisal-disk-bounded-batch-loader`, commit `7ccf61a` (elephant-query-db).

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

**Always validate distinct parcels BY FOLIO** (`request_identifier`) vs the source seed
count — never by the normalized `parcel_identifier` (collapses STRAPs with letters) and
never by raw parcel-id string compare (false mismatches). E.g. for Lee: expect ~512,353
distinct folios, not 481,111.

```sql
-- distinct parcels by the TRUE key (folio), compare to source seed count
SELECT count(DISTINCT request_identifier) FROM parcels WHERE jurisdiction_key = '<county>';
-- orphan check (the normalization bug produced 20,926 of these for Lee)
SELECT count(*) FROM properties WHERE parcel_id IS NULL;

-- per county/run
SELECT count(*) FROM properties WHERE county = '<county>';
SELECT count(*) FROM permits p JOIN properties pr ON p.property_id = pr.id WHERE pr.county = '<county>';
-- recent insert rate (monitoring)
SELECT count(*) FROM permits WHERE created_at > now() - interval '10 minutes';
```

Compare against S3 artifact counts and the seed row count; investigate any gap before
declaring a run complete. Check actual table/column names in
`elephant-query-db/src/schema/` — the schema evolves with the lexicon.

Once counts validate by folio, the next step is `county-open-data-publish` (export to
IPFS + IPNS for MCP/NEO consumption).
