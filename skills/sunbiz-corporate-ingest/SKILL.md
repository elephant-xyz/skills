---
name: sunbiz-corporate-ingest
description: Ingest Florida Sunbiz corporate registration bulk data scoped to a county - bulk download, ZIP-prefix extraction via the permit-harvest worker, and lexicon transform. Use when onboarding a Florida county's business-registration data, refreshing quarterly Sunbiz data, or matching corporate entities to county addresses.
metadata:
  author: elephant-xyz
---

# Sunbiz Corporate Ingest

Sunbiz is STATEWIDE Florida data — the pipeline is fully reusable across FL counties.
The only county-specific input is the ZIP-code prefix list.

Canonical runbook lives in `oracle-node/docs/sunbiz-bulk-download-runbook.md`; durable
findings in `docs/sunbiz-lexicon-transform-findings.md`. Read both before running.

## 1. Acquire the bulk file

- Source: Sunbiz Data Access Portal, quarterly corporate file `doc > quarterly > cor >
  cordata.zip` (~1.7 GB).
- The host is Cloudflare-challenged: plain `curl` fails; use a real browser (headless
  Chromium works, manual browser is fine) per the runbook.
- **Deflate64 pitfall**: `cordata.zip` uses ZIP method 9 which streaming libs (yauzl)
  cannot read in Lambda. Expand locally with system `unzip` and stage the `cordata*.txt`
  entries to S3, then run with `--source-format text`:

```bash
unzip cordata.zip -d cordata-expanded/
aws s3 cp cordata-expanded/ s3://<env-bucket>/permit-harvest/sunbiz-source/quarterly/cor/cordata-<quarter>-expanded/ --recursive
```

Daily incremental files (`YYYYMMDDc.txt`) are plain text and work directly.

## 2. Extract county records (ZIP-prefix scan)

Build the county ZIP list (from `county-discovery`), then enqueue:

```bash
node scripts/enqueue-sunbiz-corporate-zip-extract.mjs \
  --stack elephant-permit-harvest \
  --job-id sunbiz-<county>-corporate-quarterly-<quarter> \
  --source-data-s3-uri s3://<env-bucket>/.../cordata-<quarter>-expanded/ \
  --source-format text \
  --zip-prefixes-json '["334","33401",...]'
```

(`--lee-county-zips` is a Lee-only convenience flag; pass explicit prefixes for other
counties.) The worker scans the fixed-width records and matches principal, mailing,
registered-agent, AND officer addresses; output is chunked JSONL plus `manifest.json`
under `permit-harvest/<job-id>/sunbiz/corporate-by-zip/`.

Scale reference (Lee): 12.6M records scanned, 379k matched, ~80 chunks; worker needs the
4 GB `/tmp` configuration.

## 3. Transform to lexicon

```bash
node scripts/transform-sunbiz-corporate-to-lexicon.mjs \
  --source <manifest or chunks S3 URI> \
  --output s3://.../lexicon-transform/business-registration-v1/
```

Emits `business_registration`, `business_registration_address` (role bridge),
`business_registration_party`, companies, de-duplicated addresses, and relationship
records, plus `summary.json` with counters. Complete when `invalidRecordCount == 0` and
`transformedRecordCount == sourceRecordCount` (check via the monitoring skill's
`sunbiz-summary.sh`).

## 4. Address matching (optional, later)

`scripts/enqueue-sunbiz-corporate-address-match.mjs` matches a supplied address batch
(e.g. permit work locations) against corporate addresses — useful once enough permits
have accumulated for the county.

## Known gaps (do not silently fix)

- `corevent.zip` (filing-history events) is not ingested — separate scope.
- `party_type_code` decoding is incomplete; officers are not normalized to person/company.
- Unmapped fields are intentionally preserved in the output for future lexicon expansion.

## Persist your work

Extraction/transform scripts live in `oracle-node` (commit on the county branch). Any new
docs, ZIP-prefix lists, or mapping notes produced for a county also get committed and
PR'd to `github.com/elephant-xyz/Counties-trasform-scripts` under `<county>/docs/`
(`gh pr create`) so they survive outside this machine.
