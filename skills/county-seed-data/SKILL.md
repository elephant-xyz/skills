---
name: county-seed-data
description: Produce and stage the parcel seed CSV that drives oracle-node county ingestion, at s3://counties-seeds/<county>.csv. Use when onboarding a county, when the seed feeder reports missing or malformed seed data, or when asked where parcel lists come from.
metadata:
  author: elephant-xyz
---

# County Seed Data

The entire pipeline is driven by one CSV per county in the seeds bucket:
`s3://counties-seeds/<county>.csv`. One row per parcel.

First ask the operator: do they already have a seed CSV or a preferred parcel-roll source
for this county? Check `s3://counties-seeds/` for an existing file before producing one.

## Required columns

The pre-processor and seed feeder read:

- `parcel_id` — the county parcel identifier, in the format the APPRAISER portal expects
- `source_identifier` — identifier used for the source request (often same as parcel_id)
- Address columns (street/city/zip) — used for `best_permit_address` and cross-source
  address-hash matching

Check `workflow/lambdas/pre/index.mjs` for the currently consumed column set before
producing a new seed; column handling evolves.

## Sourcing parcel lists

Preference order for Florida counties:

1. **County appraiser bulk download** — most appraiser sites publish full parcel rolls
   (CSV/Excel/Access). Found during `county-discovery`.
2. **Florida DOR Name-Address-Legal (NAL) rolls** — statewide, one file per county,
   published yearly; reliable fallback with consistent columns.
3. **County GIS / open-data portal** — parcel layers exportable to CSV.

For non-FL states, use the county/state equivalent of 1 or 3. To locate the official
offices and their download pages, start from the NETR Online directory:
`https://publicrecords.netronline.com/state/<STATE>/county/<county>`.

## Workflow

1. Download the roll; inspect columns and row count. Record provenance (URL, date) in
   `oracle-node/docs/<county>-county-findings.md`.
2. Map columns to the seed schema. Keep the parcel id EXACTLY as the appraiser portal
   expects it (punctuation matters; e.g. Lee STRAP vs numeric variants). Keep any
   alternate id formats as extra columns — the permit portal may use a different format.
3. Sanity checks before upload:
   - row count vs county's published parcel count (within a few %)
   - no duplicate `parcel_id`
   - spot-check 5 ids resolve on the appraiser portal
4. Upload:

```bash
aws s3 cp <county>.csv s3://counties-seeds/<county>.csv
```

5. Record row count — it is the denominator for all ETA math during the run.

## Prioritization

The Lee run prioritized commercial properties. If the same is wanted, either sort the seed
CSV (commercial usage codes first) before upload, or rely on the post-transform
eligibility branch which only sends eligible usage types to permit harvest. Sorting the
seed is the only way to make APPRAISAL scraping itself commercial-first.
