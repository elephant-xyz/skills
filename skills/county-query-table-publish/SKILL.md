---
name: county-query-table-publish
description: Build, validate, publish, and MCP-wire a county's columnar "query table" — a one-row-per-property Parquet exported from the Neon query DB, published to public IPFS behind its OWN IPNS pointer, and read by the elephant MCP's embedded DuckDB so the donphan agent can answer arbitrary SQL questions (counts, filters, aggregates by ZIP/owner/material). Use after a county is loaded + reconciled in Neon to make it queryable through the MCP. Reference implementation: Lee County, FL; Palm Beach, FL is the next county.
metadata:
  author: elephant-xyz
---

# County Query-Table Publish (DuckDB-on-IPFS)

Turns a county that is already loaded in the Neon query DB into a **SQL-queryable open
dataset**. Exports a flat, scalar-only **Parquet "query table"** (one row per property,
~37 columns) from Neon, publishes it to **public IPFS via Filebase** behind the county's
**own IPNS pointer**, and wires it into the `elephant` MCP so its embedded DuckDB
range-reads the Parquet straight off an IPFS gateway. The **donphan** agent then answers
arbitrary questions ("how many concrete homes in 33410", "properties owned by X", counts /
filters / aggregates) as plain SQL over the `properties` view.

This is the indexing/publish stage that runs **after** the county is loaded + reconciled
(`query-db-loading-matching`) and after the property consolidation export
(`county-open-data-publish`, which produces the manifest that carries each property's CID).

> **Lee County, FL** is the reference run (~511,695 folios). **Palm Beach, FL** is next.
> Everything here is county-generic — every command takes `--county <county>`; Lee/PB appear
> only as worked examples.

## ⚠️ PII / human-in-the-loop

The query table is per-property PII (owner names, addresses). Pushing it to **public IPFS
is a HUMAN-run step**. The agent prepares and verifies the export, runs the validation
gate, and can do a `--dry-run` of the publish — but **a human runs the actual
`publish:query-table` upload**. Do not auto-upload PII to public IPFS.

## Pipeline overview

```
Neon query DB  (county already loaded + reconciled; consolidation manifest exists)
  │  npm run export:query-table   -- --county <c> --manifest <consolidation manifest.json>
  ▼
.query-table-export/<c>/query-table.parquet     (one flat row per folio, ~37 cols)
  │  npm run validate:query-table -- --county <c> --parquet <path>        ← GATE
  ▼
validated parquet  (rows == distinct folio in Neon, 0 dup/null folios)
  │  npm run publish:query-table  -- --county <c> --env-file <publish-env> ← HUMAN
  ▼
Filebase bucket + IPNS label  oracle-query-table-<c>  (network_key = k51…)
  │  prints  PROPERTY_QUERY_TABLE_MAP={"<c>":"https://ipfs.filebase.io/ipns/<key>"}
  ▼
elephant MCP  (env PROPERTY_QUERY_TABLE_MAP)  → DuckDB view `properties`  → donphan SQL
```

All four commands run in the **`elephant-query-db`** checkout and are county-generic via
`appraisalSourceForCounty(--county)` → `source_system='<county>_appraiser'`.

> **If you run commands through the RTK proxy:** invoke the npm scripts as
> `rtk proxy npm run export:query-table -- --county …` (likewise for `validate:`/`publish:`) so
> the `--` passthrough flags reach the script unmangled. Plain `npm run …` is fine when RTK is
> not in the loop.

## County slug — use ONE lowercase-hyphen slug end-to-end (the #1 thing that breaks a new county)

Choose the county's slug ONCE as **lowercase, hyphen-separated** (`lee`, `palm-beach`) and use
that **exact string** in every command, as the `PROPERTY_QUERY_TABLE_MAP` key, AND as the
`county` donphan passes. Do **not** mix in the underscore form (`palm_beach`). Two *different*
normalizers sit on the two ends of the pipeline, and only the hyphen slug satisfies both:

- **Export / validate / publish side** — `appraisalSourceForCounty(--county)` collapses every run
  of non-alphanumerics to `_` and appends `_appraiser`, so BOTH `--county palm-beach` and
  `--county palm_beach` yield the DB discriminator `source_system='palm_beach_appraiser'`. The DB
  query works either way — which is exactly the trap.
- **MCP side** — `normalizeCountyKey` only lowercases and collapses **whitespace** to hyphens; it
  does **NOT** convert `_`→`-`. So map key `palm_beach` and map key `palm-beach` are two DIFFERENT
  counties to the MCP. donphan naturally sends `"Palm Beach"` / `"palm-beach"` (→ `palm-beach`), so
  a map published under the underscore `palm_beach` resolves to **"county not served"**.

**Palm Beach, end to end:** pass **`--county palm-beach`** to `export:`, `validate:`, and
`publish:`. `appraisalSourceForCounty("palm-beach")` → `palm_beach_appraiser` (the DB
`source_system`); the publish step prints `PROPERTY_QUERY_TABLE_MAP={"palm-beach":"…"}`; donphan
queries `county: "palm-beach"`. Because the export writes to
`.query-table-export/<slug>/query-table.parquet` and validate/publish default their `--parquet`
path from the same `--county`, reusing the identical slug string keeps all three pointed at one
file.

## Prerequisites (all must hold before Stage 1)

1. **County loaded + reconciled in Neon.** The county's rows exist under
   `source_system='<county>_appraiser'` and the distinct-folio count reconciles against the
   source parcel roll — see `query-db-loading-matching` (validate BY FOLIO
   `request_identifier`, never the normalized parcel id).
2. **Consolidation export + manifest exist.** Run `county-open-data-publish` first: its
   `export:property-consolidation` run writes a `manifest.json` mapping `propertyId → cid`.
   The query table left-joins that manifest to populate `property_cid`. Without it every
   `property_cid` is NULL (the export still succeeds — but donphan can't link a row back to
   its consolidated property CID).
3. **The county has its OWN Filebase bucket + IPNS label.** Never reuse another county's
   bucket or label (see the guard note in Stage 3). Default label is
   `oracle-query-table-<county>`.
4. **`DATABASE_URL`** in the export env file points at the catalog plain query DB
   (`ep-mute-leaf`) — the same DB the load and consolidation export used.

## Stage 1 — Export (Neon → Parquet)

In the **`elephant-query-db`** checkout:

```bash
npm run export:query-table -- \
  --county <county> \
  --env-file .env.local \
  --out-dir .query-table-export \
  --manifest <path/to/consolidation manifest.json>
```

Produces `.query-table-export/<county>/query-table.parquet` — one flat row per **folio**
(`request_identifier`), ~37 scalar columns, DuckDB reads it directly. It runs a **single
SQL pass** that pre-dedups every many-to-one relation into one row per property, then folds
to one row per folio via `DISTINCT ON (folio)`. It never reads the heavy consolidated
property JSON, so it can never become a full property re-fetch.

The run logs `query_table_export_finished` with `rowCount` and `rowsWithCid`. If
`rowsWithCid` is 0, you forgot `--manifest` (or pointed it at the wrong manifest) — fix it
before publishing.

### Baked-in gotchas (these are HARD-WON — do not re-hit)

- **Situs vs mailing address.** The property-location (situs) address comes from the
  free-text `unnormalized_addresses.full_address` (joined on `request_identifier`), parsed
  apart — NOT the structured `addresses.street_*/city/postal` columns, which are the
  **owner-mailing** address (a Palm Beach owner's mailing ZIP can be a New York City ZIP,
  not the property's). A `WHERE address_zip = …` that read the mailing columns would answer
  the wrong question. The export resolves situs first, structured columns only as fallback.
- **Folio dedup by `request_identifier`, never `parcel_identifier`.** The folio is the true
  cardinality key. Deduping on the normalized `parcel_identifier` collapses distinct
  properties into one row (multiple folios can share a normalized parcel id). One row per
  folio is the contract the validator enforces.
- **Acreage from sqft.** `lot_size_acre` is preferred, but derived from
  `lot_area_sqft / 43,560` when absent — for `palm_beach_appraiser`, `lot_size_acre` is ~0%
  populated while `lot_area_sqft` is ~92%. A "acres > 2" query would return nothing for PB
  if you only read the direct column.
- **`property_cid` lives in the consolidation manifest, not Neon.** The CID is computed at
  consolidation-export time. This is why Stage 1 needs `--manifest` and why this skill runs
  **after** `county-open-data-publish`.

### ⚠️ `--manifest` is optional — and its Neon-contention fallback (Orange, 2026-07)

`--manifest` is **optional** on `export:query-table`. Without it the export still succeeds but
every `property_cid` is NULL — so run Stage 1 **after** Stage A produces the consolidation
manifest, then re-export (or re-join, below) with `--manifest` to populate the CIDs.

**Neon-contention fallback (do the CID join locally, no Neon).** If a concurrent
`elephant-query-bulk-loader` is saturating Neon, the manifest re-export **hangs** — it loads
the manifest fine, then starves on the Neon `SELECT`. Skip Neon entirely and join on disk:

- Use **pyarrow** to read the already-exported `query-table.parquet`, build a
  `propertyId → cid` map from the manifest's `entries[]`, join it onto the parquet's
  `property_id` column, and write the parquet back with `property_cid` filled.
- System python is PEP-668 **externally-managed** — create a **venv** for pyarrow (a bare
  `pip install pyarrow` is refused).
- Then validate with `validate:query-table … --parquet-only` (the `--parquet-only` path skips
  the Neon reconcile, which is safe **only here** because the folio reconcile was already
  proven pre-join, and Neon is the very thing that's contended).

## Stage 2 — Validate (THE GATE)

Prove the folio-cardinality contract before anyone publishes PII. Fails loud (`exit 1`) on
any mismatch or duplicate/null folio:

```bash
npm run validate:query-table -- \
  --county <county> \
  --env-file .env.local \
  --parquet .query-table-export/<county>/query-table.parquet
```

It checks:

1. **Parquet-internal:** `rowCount == distinct request_identifier` and **0 null/empty
   folios** — no DB needed.
2. **Reconcile vs Neon (the real gate):** parquet `rowCount ==` distinct
   `request_identifier` in Neon, computed with the **same COALESCE key** the export dedups
   on (`~511,695` for Lee). Requires `DATABASE_URL`. It is skippable with `--parquet-only`,
   which logs `neon_reconciliation_skipped` — **do NOT publish on a skipped reconcile**; the
   trans-Atlantic count is cheap, run it.

Pass = `query_table_validation_passed`. **Any failure ⇒ STOP, do not publish.** A mismatch
means the export dropped or duplicated folios and republishing would ship a corrupt index.

## Stage 3 — Publish (HUMAN-run: PII → public IPFS)

A human runs this. The agent may first `--dry-run` (no S3 PUT, no IPNS write) to confirm
the bucket, key, label, and local CID:

```bash
# agent may run this to verify wiring:
npm run publish:query-table -- --county <county> --env-file <publish-env> --dry-run

# HUMAN runs the real publish:
npm run publish:query-table -- --county <county> --env-file <publish-env>
```

Uploads the **single** parquet to `query-tables/<county>/query-table.parquet` in the
Filebase bucket, creates/upserts the IPNS label `oracle-query-table-<county>`, and re-points
it at the new CID. It prints the object CID, the resolvable **`network_key`** (`k51…`), the
two gateway URLs, and the ready-to-paste line:

```
PROPERTY_QUERY_TABLE_MAP={"<county>":"https://ipfs.filebase.io/ipns/<network_key>"}
```

Required env in `<publish-env>` (from the vault Filebase credentials):

| Variable | Value / source |
|---|---|
| `S3_ENDPOINT` | `https://s3.filebase.io` |
| `S3_BUCKET` | the county's **own** Filebase bucket |
| `S3_ACCESS_KEY_ID` | Filebase access key |
| `S3_SECRET_ACCESS_KEY` | Filebase secret key |
| `FILEBASE_API_TOKEN` | Filebase API token (IPNS REST) |
| `FILEBASE_QUERY_TABLE_IPNS_LABEL` | optional override; defaults to `oracle-query-table-<county>` |

### Baked-in gotchas

- **Per-county bucket + per-county IPNS label — never reuse another county's.** The upload
  writes a fixed key; reusing a bucket/label clobbers the other county's data or pointer.
- **The publisher HARD-REFUSES the property and geo labels.** It throws if the resolved
  label is `oracle-open-data-<county>` (the property dataset) or `oracle-geo-index-<county>`
  (the geo index) — re-pointing either would wipe that dataset. The query table has its own
  `oracle-query-table-<county>` namespace; keep it that way.
- **Filebase gateway is the reliable form for DuckDB `httpfs` range reads.** Prefer the
  `https://ipfs.filebase.io/ipns/<key>` URL in the MCP map; `dweb.link` Range support can be
  flaky.
- **IPNS is addressed by LABEL** via `https://api.filebase.io/v1/names`; the resolvable name
  is the `network_key` field. The publisher does create-or-update automatically.

## Stage 4 — Wire the MCP + donphan

The `elephant` MCP resolves a county → Parquet location from **`PROPERTY_QUERY_TABLE_MAP`**
(JSON `{"<county>":"<gateway url>", …}`). The map key MUST be the **exact lowercase-hyphen slug**
the export/publish used (see "County slug" above) — i.e. the same string donphan passes as
`county`; an underscore key silently reads as a different, unserved county. To add a county,
**merge** its entry into the existing map (don't overwrite other counties) and redeploy the MCP:

```
PROPERTY_QUERY_TABLE_MAP={"lee":"https://ipfs.filebase.io/ipns/<lee-key>","<county>":"https://ipfs.filebase.io/ipns/<county-key>"}
```

The MCP opens an in-process DuckDB, creates a view `properties` over the county's Parquet
(range-read over httpfs for an http(s) location), and serves two tools, both taking a
`county` argument:

- **`getPropertyQuerySchema { county }`** — column list + DuckDB types + one-line column
  descriptions (call this first so SQL is written without guessing).
- **`queryProperties { county, sql, limit? }`** — a single read-only `SELECT`/`WITH` over
  the `properties` view (mutating / file / extension keywords rejected; rows capped).

donphan (the explore-via-MCP agent) passes the **county key** on every call, so the new
county is queryable the moment the map entry is live. See `deploy-open-data-mcp` for the MCP
deploy mechanics; point `ORACLE_MCP_URL` at the STABLE MCP alias, not a pinned deploy URL.

### ⚠️ MCP wiring is the real go-live — TWO places, always MERGE (Orange, 2026-07)

`PROPERTY_QUERY_TABLE_MAP` is the **PRIMARY** source for all data tools: a county listed there
needs **no** `ORACLE_*` vars. Wiring it is the actual go-live, and it lives in **two** places —
**MERGE** the new county into the existing JSON both times, never overwrite (overwriting is the
"dropped Palm Beach" trap — you silently un-serve every other county):

1. **elephant-mcp Vercel *production* env** → then **REDEPLOY**. Env binds only on new deploys,
   so an updated var does nothing until you redeploy.
2. **Local Cursor `~/.cursor/mcp.json`.** There can be **3 overlapping servers**
   (`elephant` / `elephant-hosted` / `elephant-local`) — put the full map on the one donphan
   actually uses and consolidate the rest so they don't drift.

**Verify each county's IPNS is a real Parquet** before declaring done:
`curl -r 0-3 https://ipfs.filebase.io/ipns/<key>` → the first bytes must be `PAR1`.

### NEO catalog wiring (repo `elephant-xyz/catalog`)

The MCP map makes donphan queryable; NEO's catalog UI is a separate wiring in the
`elephant-xyz/catalog` repo. Base every change off the latest **`master`** — the shared
county-aware infra evolves per PR. Per county, add:

- `app/<county>/page.tsx` — **mirror the latest merged county page** (county-aware MCP,
  `dynamic`, `maxDuration = 60`, DB fallback); don't hand-roll it.
- a `COUNTY_OPTIONS` entry in `components/county-switcher.tsx`.
- `tests/<county>-page.test.tsx` + a `neo-county-catalog-path` assertion.

Gotchas:

- **NEO brand is DOMAIN-based, not an env flag.** `neo.prismteam.ai/<county>` renders as NEO;
  `catalog-*.vercel.app` and everything else render as SpeedBay. **Do NOT set `BRAND=neo` on
  shared prod** — view NEO at `neo.prismteam.ai/<county>` (gated by `NEO_PASSWORD`).
- **Vercel "Deployment was blocked / Git author must have access"** = the commit author's
  GitHub account isn't linked to a Vercel member with project access. It is **not** fixable by
  changing the commit email. `master` has no required checks, so it doesn't block the merge
  (production deploys run under the repo integration regardless).

## Data-coverage caveat — validate + report honestly

The schema is stable across counties, but **column coverage varies by county** — report
which columns are NULL rather than implying full coverage:

- **`hoa_flag` is a reserved placeholder NULL for EVERY county** — no HOA data is ingested
  into Neon yet. "Is this property in an HOA?" is unanswerable until upstream HOA ingestion
  lands; the column exists only so the schema stays stable when it does.
- **Lee**: no acreage and no structure-material coverage (`lot_size_acre`,
  `exterior_wall_material`, `roof_covering_material` largely NULL).
- **Palm Beach**: `lot_size_acre` ~0% but `lot_area_sqft` ~92% → acreage is derived from
  sqft (see Stage 1); situs address 100% from `unnormalized_addresses.full_address`.

Before declaring done, spot-check coverage with a DuckDB `count(*) FILTER (WHERE col IS NOT
NULL)` per notable column and state the gaps in the handoff — never claim a field is
queryable for a county whose source doesn't provide it.

## Run it in AWS us-east-1, NOT the laptop (the scale fix)

Run export + validate + publish from **AWS us-east-1**, next to Neon and Filebase — the same
place the load and consolidation export run. The **Lee query-table export took ~18 min from
the laptop** because every DB round-trip and the Filebase upload cross the Atlantic (Serbia
→ us-east-1). For a full county this is the difference between minutes and a stalled run. Use
the `county-open-data-publish` AWS approach (SSM-managed instance in us-east-1, Node 22); the
laptop only kicks it off and monitors. If you must run locally, keep it awake
(`caffeinate -i -s`) and expect the trans-Atlantic penalty.

## Done = both are true

1. **Validation gate passes** (`query_table_validation_passed`): parquet rows == distinct
   folio in Neon, 0 dup/null folios — reconcile NOT skipped.
2. **donphan answers a smoke question through the MCP** for the county — e.g. via
   `queryProperties { county, sql }`:
   ```sql
   SELECT count(*) FROM properties WHERE address_zip = '33410';
   ```
   returns a real count, and `getPropertyQuerySchema { county }` lists the columns. If donphan
   says the county "is not served", the `PROPERTY_QUERY_TABLE_MAP` entry is missing or the MCP
   wasn't redeployed.

## Related skills

- `query-db-loading-matching` — loads + reconciles the data this skill indexes (validate the
  distinct-folio count BY `request_identifier` first).
- `county-open-data-publish` — the property-consolidation publish that produces the
  `manifest.json` (CID map) Stage 1 needs; same Filebase/AWS mechanics.
- `deploy-open-data-mcp` — how to deploy the `elephant` MCP that reads
  `PROPERTY_QUERY_TABLE_MAP` and serves `queryProperties` / `getPropertyQuerySchema`.
- `monitoring-county-ingestion` — counts/ETAs for the upstream load.
