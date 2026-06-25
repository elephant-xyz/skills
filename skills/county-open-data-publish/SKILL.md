---
name: county-open-data-publish
description: Publish county property data from the Neon query DB to IPFS as open data — one JSON file per property + a sharded index, uploaded to Filebase (S3-compatible IPFS), with a stable IPNS name re-pointed on every publish so downstream MCP/NEO never change. Use when exporting consolidated property JSON, uploading to Filebase, managing the IPNS pointer, or wiring an MCP server to read the published index.
metadata:
  author: elephant-xyz
---

# County Open-Data Publish (IPFS)

Publishes the county property dataset from the `elephant-query-db` Neon DB to **public
IPFS via Filebase**, as the open-data layer that the MCP server (and NEO) read. This is
the Story-2 publish step that follows `query-db-loading-matching`.

The model: **1 JSON file per property** + a **sharded index** (`shards/shard-NNNN.json`
+ a small `index.json`) + a flat `manifest.json` for back-compat. Each consolidated JSON
is CID-addressed; the index lists every property CID. A stable **IPNS name** resolves to
the latest index CID, so every consumer auto-gets new data on each re-publish with **zero
re-config**.

> **Lee County, FL** is the reference implementation. IPNS label `oracle-open-data-lee`,
> IPNS name `k51qzi5uqu5dlzgslzedrnk4whtd7ip69l0pmd3zxelz8hwjorbeyy0pyyeu4m`.

## ⚠️ PII / human-in-the-loop

Bulk PII → public IPFS is a **human-run** step. An agent prepares and verifies the
export and the wiring, but **a human runs the actual upload** of PII-bearing property
data to public IPFS. Do not auto-upload.

## Pipeline overview

```
Neon query DB
  │  npm run export:property-consolidation -- --shard-size 10000   (in elephant-query-db)
  ▼
local export dir:  <prop-cid>.json (one per property, ~22 KB each)
                   shards/shard-NNNN.json   (sharded index, ~10k props/shard)
                   index.json               (small: lists the shard CIDs)
                   manifest.json            (flat, back-compat)
  │  npm run publish:ipfs-upload            (Filebase, S3-compatible IPFS)
  ▼
Filebase bucket  + IPNS name re-pointed at the new index CID
  │  MCP resolves IPNS → index → property CIDs
  ▼
MCP server (per-consumer Nitro deploy) → NEO
```

CIDs are **pre-computed locally** with `ipfs-only-hash` before upload — its algorithm
matches Filebase's, so there is no need to read CIDs back from S3 metadata (see Bug C).

## Sizing (real numbers, Lee 512k)

- Consolidated JSON ≈ **22 KB each** → ~**11 GB** for 512k properties. (NOT ~80 GB — an
  early over-estimate; the consolidated record is compact.)
- `--shard-size 10000` → ~52 shards for 512k.
- Upload throughput: **~310 objects/sec at `--concurrency 64`** → **~25–30 min** for 512k.
- Export: ~1–3 h depending on DB CU and machine.

## Step 1 — Export

In the **`elephant-query-db`** checkout:

```bash
npm run export:property-consolidation -- --shard-size 10000
```

Produces, in the export dir: one `<cid>.json` per property, `shards/shard-NNNN.json`,
`index.json` (the sharded index), and `manifest.json` (flat back-compat). DB connection
comes from `DATABASE_URL` (the catalog plain `DATABASE_URL`, `ep-mute-leaf`).

### ⚠️ Appraisal addresses are free-text only — parse them (2026-06-25)

The appraisal source (`source_system='lee_appraiser'`) populates **only**
`addresses.unnormalized_address` (a free-text single line like
`"5845 CORPORATION CIRCLE, FORT MYERS, FL 33905"`). The structured columns
`street_number / street_name / street_suffix_type / city_name / latitude` are **100% null**
(verified: 0 of 511,968 Lee rows). An export that reads only the structured columns emits a
**null address for the entire county** — silent, because every row is "successfully" exported.

The export must parse `unnormalized_address` (format `"STREET, CITY, STATE ZIP"`) into the
discrete `street` / `city` / `postalCode` fields NEO renders, with structured columns still
winning when present (other sources). **Do NOT parse the state from the text:** the DB
`state_code` is `FL`-or-null (never a wrong value) and NEO falls back to `parcel.stateCode`
(FL for 100% of parcels); a parsed state token would inject wrong source values ("MI", "NC")
into the ~7% of rows whose `state_code` is null. `latitude/longitude` come from the
`geometries` table, not `addresses` (geometry is present for 100% of properties).

## Step 2 — Upload to Filebase

```bash
npm run publish:ipfs-upload
```

Resumable (writes a checkpoint; re-run to continue). **⚠️ Before a CORRECTED re-publish,
delete the stale checkpoint** (`.upload-runs/filebase-upload-checkpoint.json`): it skips by
S3 key (`properties/<uuid>.json`), not by content, so a leftover checkpoint from a previous
run will silently skip re-uploading every file and the fix never reaches IPFS. Required env:

| Variable | Value / source |
|---|---|
| `S3_ACCESS_KEY_ID` | Filebase access key (vault `Credentials/filebase-oracle-open-data`) |
| `S3_SECRET_ACCESS_KEY` | Filebase secret key (same vault note) |
| `S3_BUCKET` | `elephant-oracle-open-data` |
| `S3_ENDPOINT` | `https://s3.filebase.io` |
| `FILEBASE_IPNS_LABEL` | `oracle-open-data-lee` (per-county) |

Tune `--concurrency 64` for ~310 obj/s. The uploader **auto-derives the IPNS auth token
from the S3 keys** (see Step 3) and **upserts the IPNS name** at the end — no separate
token needed.

## Step 3 — IPNS (the always-latest pointer)

The IPNS name is what makes re-publishing free for consumers: the **same name** is
re-pointed at the new index CID on every publish → MCP/NEO never change.

Use the **Filebase Platform API** at **`https://api.filebase.io/v1/names`**
(NOT `/v1/ipns` — that path does not exist).

- **Auth** = `Authorization: Bearer base64(S3_ACCESS_KEY_ID:S3_SECRET_ACCESS_KEY)`.
  Derived directly from the S3 keys — there is **NO separate API token** to obtain.
- **Operations:**
  - `GET  /v1/names` — list names.
  - `POST /v1/names` body `{"label": "...", "cid": "..."}` — create.
  - `PUT  /v1/names/{label}` body `{"cid": "..."}` — re-point (this is the re-publish op).
- The response field **`network_key`** is the resolvable `k51…` IPNS name.

The uploader does this automatically (create-or-update). To re-point by hand:

```bash
AUTH=$(printf '%s:%s' "$S3_ACCESS_KEY_ID" "$S3_SECRET_ACCESS_KEY" | base64)
curl -X PUT "https://api.filebase.io/v1/names/oracle-open-data-lee" \
  -H "Authorization: Bearer $AUTH" \
  -H "Content-Type: application/json" \
  -d '{"cid":"<new index cid>"}'
```

## Step 4 — MCP reads IPNS

The MCP server resolves the IPNS name → fetches the index. It **auto-detects** sharded
`index.json` vs flat `manifest.json` (parse as the sharded schema; on failure, fall back
to the flat manifest at the same IPNS-resolved CID).

**IPNS resolution must be header-based.** Public gateways **dropped the Kubo RPC**
`/api/v0/name/resolve` endpoint (returns "Kubo RPC is not here"). Resolve via a HEAD
request and read the **`x-ipfs-roots`** response header:

- `https://<name>.ipns.dweb.link/`
- `https://ipfs.filebase.io/ipns/<name>`

MCP env: set `ORACLE_OPEN_DATA_IPNS=<name>` and leave the fixed index-CID env unset, so
IPNS is the single source of truth.

## Bugs caught + fixed (do not re-hit)

> ⚠️ **These fixes have drifted off `elephant-query-db` `main` once already.** Bugs B, C, D
> below were documented here but the actual fixes lived on an un-merged branch, so a later
> publish run from `main` re-hit all of them live. **Before publishing, confirm the
> `upload-consolidation-to-filebase.ts` / export code on `main` actually contains these
> fixes** (re-landed in elephant-query-db PR for the 2026-06-25 publish). Doc ≠ code.

**A. `.env` quote-stripping.** The env loader did not strip surrounding quotes from
values, so a quoted `DATABASE_URL` (or any host) parsed wrong — the DB host came through
as literally `base`, failing with `getaddrinfo ENOTFOUND base`. Strip surrounding quotes
when reading `.env`.

**B. Double export-dir prefix.** The manifest stores `filePath` WITH the export-dir prefix
already, so `join(exportDir, entry.filePath)` doubles it → `ENOENT` fatal on the first file.
Build the path from the relative key (`properties/<uuid>.json`), not `entry.filePath`.

**C. Per-upload S3 deserialize middleware is NOT concurrency-safe.** Reading the
`x-amz-meta-cid` response header via a deserialize middleware added by a fixed name to the
**shared** S3 client caused `Duplicate middleware name` and cross-request header
contamination at `--concurrency > 1`. **Two valid fixes** — either drop the middleware and
trust the locally pre-computed CID (`ipfs-only-hash` yields the same CID as Filebase), or
attach the middleware to **each `PutObjectCommand`'s own stack** (`command.middlewareStack.add`,
isolated per call) which keeps the Filebase read-back as a cross-check. Main uses the
command-scoped form. Either way: **never add the capture middleware to the shared client.**

**D. IPNS update `404`.** The uploader hit `https://api.filebase.io/v1/ipns` with an
`_id`-keyed PUT — that path does not exist. The real API is `/v1/names`, **label-keyed**
(see Step 3), name = `record.network_key`. Symptom: upload succeeds, `ipns_update_failed:
… 404`, pointer never moves, consumers stay on the old CID.

**E. Silent IPNS skip when the bearer is unset.** If `FILEBASE_API_TOKEN` is empty the run
"succeeds" but logs `skipping IPNS update` and the pointer never moves. The uploader now
**auto-derives** the bearer = `base64(S3_ACCESS_KEY_ID:S3_SECRET_ACCESS_KEY)` so only the S3
keys + `FILEBASE_IPNS_LABEL` are needed. Always confirm the final log shows the IPNS name
bumped to the new sequence — don't trust "upload complete" alone.

## AWS approach (run near Neon + Filebase)

Run export + upload from an **EC2 instance in us-east-1** (same region as Neon and
Filebase) via **SSM Session Manager** — no SSH key, no open inbound ports.

- IAM **role + instance profile** `elephant-publish-ssm` with the managed policy
  `AmazonSSMManagedInstanceCore`.
- Instance: **`c7g.2xlarge`** (Graviton3), **150 GB gp3**, **AL2023 arm64**
  (`ami-06c84fbfd615657d3`), `DeleteOnTermination: true`.
- User-data bootstrap: install **Node 22** via native `dnf install nodejs22` (no nvm / no
  curl-pipe), clone the repo, `npm install`. See
  `elephant-query-db/scripts/aws-publish-bootstrap.sh`.
- Connect: `aws ssm start-session --target <instance-id>`.

### ⚠️ AWS vCPU quota blocker (read this first)

**New AWS accounts have an on-demand vCPU quota of `1`** for both:

- Standard on-demand: `L-1216C47A`
- Graviton on-demand: `L-34B43A08`

A `c7g.2xlarge` needs **8 vCPUs** → `run-instances` fails with **`VcpuLimitExceeded`**.
Quota-increase requests land in **`CASE_OPENED`** and take hours-to-days and need console
approval — they are **not** instant.

**Fallback = run on the laptop.** Keep it awake (`caffeinate -i -s`); export ~1–3 h,
upload ~25–30 min. A laptop sleep kills the current step (the upload resumes from its
checkpoint; the export restarts). The proper long-term fix is running in AWS once the
quota is raised.

## Verification

### Pre-publish reconciliation: source → DB → export (do this before uploading)

Prove the export is complete and faithful for EVERY field, not just addresses, before you
publish. Three cheap checks:

1. **DB ↔ export, full counts (all properties).** For each `source_system` child table
   (`taxes, sales_histories, structures, layouts, lots, utilities, ownerships, deeds, files,
   property_valuations, geometries, flood_storm_information`) compare the DB count
   (`WHERE source_system='<county>_appraiser'` — these tables carry their own `source_system`,
   so no join needed) to the aggregate array length summed across all exported property JSONs.
   **DB == export exactly** ⇒ the export is lossless AND there are zero orphaned child rows
   (an orphan would make DB > export). Mismatch ⇒ stop, do not publish.
2. **Source (S3) ↔ DB ↔ export, ~12 random folios.** Each property row carries
   `source_artifact_uri` → the S3 `transformed_output.zip`. For a sample of folios, count the
   data files per class in the zip (`tax_N.json`, `sales_N.json`, `deed_N.json`, `file_N.json`,
   `layout_N.json`, `structure_N.json`, `lot.json`, `utility.json`, `geometry.json`,
   `flood_storm_information.json`; owners are `person_N.json` **or** `company_N.json` — count
   both) and assert S3 count == DB rows for that `property_id` == export array length. This is
   the true source proof. (`relationship_*`/`fact_sheet`/`property_seed` files are links, not
   data — exclude them.)
3. **Parent identity:** distinct folios (`request_identifier`) in `parcels` == source count
   (see `query-db-loading-matching` — validate BY FOLIO, never the normalized parcel id).

### Post-publish

- `GET /v1/names` shows the label pointing at the expected index CID.
- Resolve `https://<ipns-name>.ipns.dweb.link/` → HEAD → `x-ipfs-roots` == index CID.
- Through the MCP: `listOracleProperties {limit:2}` returns real data and `total` ==
  the published property count.
- **Re-publish proof:** set a bogus fixed index-CID env on the MCP and confirm data still
  loads — proves it is coming via IPNS, not a hard-coded CID.

## Related skills

- `query-db-loading-matching` — loads the data this skill publishes. **Validate the
  distinct-parcel count BY FOLIO (`request_identifier`) before publishing** — see that
  skill's parcel-id normalization warning.
- `monitoring-county-ingestion` — counts/ETAs for the upstream load.
