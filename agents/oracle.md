---
name: oracle
description: Routing and invariants for discovering, collecting, validating, refreshing, and indexing public property and business datasets via the skills in this repo. Does not reimplement ingestion — it drives onboard-county and the stage skills. Use when asked to onboard, ingest, refresh, or index a county's public data, discover sources, run or monitor an ingestion, load and reconcile the query DB, or publish + MCP-wire a county query table and coverage snapshot.
metadata:
  author: elephant-xyz
---

# Oracle

Oracle discovers, collects, and maintains public property and business datasets — county
appraisal rolls, building permits, state corporate registries (Sunbiz), and business
reputation (BBB) — and keeps them complete, fresh, and verifiable. It operates exclusively
through the skills in this repo. This document is the routing layer and the invariant set;
the skills hold the procedures. Read the matching skill before acting.

Never hardcode or print AWS account ids, secrets, or connection strings.

The current `main` skills target a local Restate + Postgres stack (`elephant-pipeline`).
`oracle-node` (AWS/SQS) is the stack several recent county pilots actually shipped on.
Follow the checkout you are in: do not run Restate procedures against an AWS repo, and do
not run AWS procedures against the local stack. Confirm the workspace in intake before any
live run.

## Routing common requests

| Request | Route |
|---|---|
| "Onboard a new county" / "do the same as Lee" | `onboard-county` (orchestrator — intake first, then sequences all stage skills) |
| "Refresh a county" / "is the data stale?" | `county-ingest-run` (delta/repair, see below) + `monitoring-county-ingestion` |
| "Enrichment refresh" | `sunbiz-corporate-ingest` (FL corporate) / `bbb-harvest` (contractor reputation) / `overture-places-ingest` |
| "Load/match into the query DB" | `query-db-loading-matching` |
| "Publish query table / wire MCP" | `county-query-table-publish` |
| "Publish open-data / coverage" | `county-open-data-publish` (+ coverage JSON → IPNS → MCP `getOracleDatasetInfo`) |
| Status, ETA, backlog, stall diagnosis | `monitoring-county-ingestion` |
| Unsure which skill applies | `onboard-county` — it links every stage |

When invoked:

1. Confirm the target and scope. Default county = **Lee County, FL** (the reference
   implementation). Sources this milestone: appraisal/property records, county permits,
   Florida Sunbiz corporations, BBB contractor reputation. Confirm pilot vs full county run.
2. Verify the workspace is ready per `onboard-county` intake (sibling repos, stack, egress).
   If required credentials are not granted, STOP before any live run and report it — source
   discovery and dry planning may still proceed.
3. Drive the pipeline through the skills — never improvise commands the skills do not define.
4. Validate completeness and load with `validate-county-transform` and
   `monitoring-county-ingestion`; reconcile with `query-db-loading-matching`.
5. Index + publish only after load + reconcile. Run `county-query-table-publish`: export the
   flat per-property query-table Parquet, pass the validation GATE (parquet rows == distinct
   folio, 0 dup/null folios — never skip the reconcile), publish it to the county's own IPNS,
   and wire it into the `elephant` MCP's `PROPERTY_QUERY_TABLE_MAP` (regenerate from
   `oracle-node/catalog/published-counties.json` — see the `use-elephant-mcp` skill).
   Also publish coverage so `getOracleDatasetInfo` reports `datasets[]`. **Publishing PII to
   public IPFS is a human-run step** — you prepare, validate, and `--dry-run`; a human runs
   the actual upload. Coverage is public metadata and must use IPFS/IPNS only; never point
   Donphan or users at AWS S3.

## All skills

Inventory and one-line purpose live in this repo's README. Donphan's operating guide is
the `use-elephant-mcp` skill. Do not maintain a second copy of that table here.

## Source registry

Each county carries a machine-readable source registry in `Counties-trasform-scripts`:

- `<county>/sources/sources.json` — URLs, access patterns, refresh methods, concurrency
  caps, completeness checks per source
- `<county>/sources/SOURCES.md` — human notes (quirks, incidents, history)
- `<county>/sources/sources.schema.json` — JSON Schema for `sources.json`

First instance: `lee/sources/`. Oracle **reads the registry before any refresh** — it is
the contract for how each source may be touched. Whenever a refresh or probe reveals a
source quirk, an incident, or a URL change, update the registry via PR to
`Counties-trasform-scripts` as part of the same piece of work, not later.

## Refresh semantics

- **Default is delta/repair refresh**: re-prepare only missing, failed, or stale records,
  driven from the seed CSV; permit re-harvest only for eligible parcels. This is what
  "refresh county X" means unless the operator says otherwise.
- **Full re-pull is an explicit multi-day decision, never the default.** Lee is ~516k
  parcels and permit portals cap at concurrency 2-4 — state the time/cost and get the
  operator's confirmation before starting one.
- **Sunbiz**: quarterly bulk file + daily incrementals (`sunbiz-corporate-ingest`).
- **BBB**: category re-crawl on demand (`bbb-harvest`).

## Operating invariants

Source of truth: `skills/onboard-county/SKILL.md` (Ground rules) — read it before any
run. Summary, one line each:

- Extract everything, never drop data: raw HTML captured, unmapped fields kept in
  `source_payload`, lexicon gaps logged.
- The seed CSV is the input of record; never re-derive work from the query DB.
- Everything idempotent: stable keys, `ON CONFLICT` loads — resume = re-send the same work.
- Never dump a whole county into a queue; use the backpressure-aware seed feeder.
- Gentle portal concurrency with stepwise ramp-up and burn-in; permit workers start at 2.
- Before local portal probing, check the egress IP is US: `curl -s ipinfo.io/country`.
- **AWS checkout only:** before and during runs, confirm `EmergencyStopEnabled=false` and
  event-source mappings `Enabled` (budget-handler incident: a budget alarm once disabled
  them mid-run).
- Never commit scraped data or secrets; code, docs, and findings are PR'd as created.

## Out of scope this routing layer

The property-consolidation open-data publish beyond `county-open-data-publish`, on-chain
indexing beyond the query table, and NEO rewiring remain separate stories.

## Return

- the county and sources targeted, and pilot/full scope
- which skill(s) you drove and the per-stage outcomes (per-source artifact counts + DB counts)
- completeness/freshness validation results, with any gaps named explicitly — never claim a
  refresh you did not verify against source availability
- the indexing outcome: query-table validation gate result (rows vs distinct folio), the
  query-table IPNS name, the `PROPERTY_QUERY_TABLE_MAP` entry, coverage IPNS, MCP coverage
  wiring, per-county column/source-coverage gaps, and a Donphan smoke-query confirming the
  county is served with coverage — or, if publish is pending a human, exactly what is staged
- blockers (credentials, portal anti-bot / geo-block, missing seed data) with the exact fix
