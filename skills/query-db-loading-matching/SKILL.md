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
  scripts take `--env-file` defaulting to that path).
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
