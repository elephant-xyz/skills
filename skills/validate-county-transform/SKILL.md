---
name: validate-county-transform
description: Prove a county's transform scripts extract 100% of the data available on the appraiser site across property-type variability, by diffing extracted fields against raw captures. Use before scaling any county ingestion run, after editing transform scripts, or when asked whether transform coverage is complete for a county.
metadata:
  author: elephant-xyz
---

# Validate County Transform

Existing scripts in `Counties-trasform-scripts/<county>/` must never be assumed complete.
Validate against fresh captures before any large run.

## Sample selection

Coverage failures come from variability, not volume. Pick 10-20 parcels spanning:

- usage types: commercial, industrial, residential single-family, condo, multi-family,
  agricultural, vacant, government/institutional
- edge cases: multiple buildings, multiple owners, recent sale, zero improvements,
  exemptions, very old construction
- at least one parcel with media/images and one with secondary tabs (cost cards, land
  lines, permits tab) if the site has them

Get usage-type spread from the seed CSV or county GIS export, not random sampling.

## Workflow

1. Capture each sample with the county browser flow (`elephant-cli prepare` locally) so
   you validate against exactly what the pipeline sees.
2. Run the transform locally on each capture (`elephant-cli transform
   --transform-version 2` with the county scripts; the `transform-v2-builder` skill covers
   mechanics and debugging).
3. Per sample, produce a field inventory diff:
   - Parse the raw HTML/JSON capture and enumerate every label/value pair, table, and
     media URL present on the page(s).
   - Enumerate every field present in the transformed lexicon output (all `data/*.json`).
   - Diff: anything in the raw inventory absent from the output is a gap. Classify each
     gap: (a) extractor bug, (b) page section not captured by the browser flow,
     (c) lexicon has no home for it.
4. Fix (a) in the transform scripts and (b) in the browser flow; re-run until the only
   remaining gaps are class (c).
5. For class (c) — lexicon gaps — do NOT drop data: keep it in `source_payload` and record
   the gap in `oracle-node/docs/` (pattern: `../elephant-query-db/docs/open-lexicon-gaps.md`).
   Lexicon expansion in `../lexicon` is a separate, deliberate follow-up.
6. Schema check: transformed output must validate (the Minting branch's SVL step is the
   strict validator; for archive-only runs, run validation locally via elephant-cli).
7. Verify `county_jurisdiction` in output matches the county for every sample (transform
   script mismatches have produced wrong-county labels before).

> ⚠️ **In-pipeline SVL gap (2026-06-24).** The `elephant-express` state machine historically
> ran SVL **only on the `minting` branch**. The Structured Archive default AND the
> property-first path (Lee fullcounty) skipped SVL — parcels were uploaded to S3, loaded to
> Neon, and enqueued for permits **with no schema validation** (a "successful" but wrong
> transform passed silently). Fixed by routing all non-minting parcels through the existing
> SVL gate, fail-closed (oracle-node PR #171). **RULE: every transform output must pass SVL
> before it is loaded/enqueued — validate per parcel, not only at the end of the run.** If you
> add a new post-transform branch, route it through SVL too.

## Acceptance

Record in `oracle-node/docs/<county>-county-findings.md`:

- sample list (parcel ids + usage types)
- field-coverage result per sample: extracted / total discoverable, with the class-(c)
  exception list
- assertion that no class-(a)/(b) gaps remain

Only then proceed to `county-ingest-run`. If transform scripts changed, commit them on a
branch and open a PR against `Counties-trasform-scripts` (`gh pr create`), then re-sync
to S3 (deploy with `UPLOAD_TRANSFORMS=true` or the GitHub sync function) — the deployed
worker uses S3, not your local checkout. Include the validation report and any comparison
scripts in the same PR so the coverage evidence isn't lost.
