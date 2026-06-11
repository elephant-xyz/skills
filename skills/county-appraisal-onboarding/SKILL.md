---
name: county-appraisal-onboarding
description: Wire a new county's appraisal scraping into oracle-node - browser flow JSON, per-county prepare queue, per-county prepare flags, and transform scripts from Counties-trasform-scripts. Use when onboarding a county's property appraiser site, creating browser flows, or when prepare fails for a specific county.
metadata:
  author: elephant-xyz
---

# County Appraisal Onboarding

Goal: a workflow execution for one parcel of the new county completes Prepare → Transform
→ Structured Archive.

## 1. Browser flow

Prepare runs `elephant-cli prepare` against the appraiser site. If plain fetch works the
flow may not need a browser; most counties need a Browser Flow v2 JSON.

1. Check `oracle-node/browser-flows/` for an existing `<County>*.json` (Lee has
   `LeeCurated.json`, `LeeCostCard.json` — use them as templates).
2. Author the flow: navigate → fill the parcel search input (selector from discovery) →
   submit → capture detail page(s) and any media/cost-card subpages. Capture as much of
   the site's data as possible — images and secondary tabs included; the Lee run's explicit
   requirement was "extract as much data as possible".
3. Test locally against 3+ parcels of different property types:

```bash
npx elephant-cli prepare <parcel-or-url> \
  --browser-flow <flow.json> --browser-flow-parameters '{"parcel_id":"..."}'
```

4. Per-county prepare flags (set at deploy, stored as env on the downloader):
   `ELEPHANT_PREPARE_USE_BROWSER_<County>`, continue-button selector, captcha flags —
   see `oracle-node/README.md` "Prepare function flags".

## 2. Per-county prepare queue

```bash
./scripts/create-county-prepare-queue.sh <county_key>
```

This creates `<stack>-prepare-queue-<county_key>` with its own event-source mapping so the
county's portal tolerance can be tuned independently (start `MaximumConcurrency` low,
raise while watching errors — Lee sustained 50+, but only after burn-in).

## 3. Transform scripts (reuse first)

County transform scripts live in `github.com/elephant-xyz/Counties-trasform-scripts`
under `<county>/scripts/` (`data_extractor.js` + mapping modules), synced to S3 for the
transform worker. The scripts-manager matches county-name variants (spaces, underscores,
hyphens).

1. If the county folder EXISTS: do not trust it blindly. Run the `validate-county-transform`
   skill against fresh prepare captures covering data variability. Fix gaps before scaling.
2. If it does NOT exist: author a transform v2 handler package — use the
   `transform-v2-builder` skill — then validate the same way.
3. The transform must emit `data/property.json` with `property_usage_type`; the
   post-transform permit-eligibility branch reads it.

## 4. Usage-type eligibility

Collect the county's usage-type labels (from transform output, not from the portal UI) and
decide the eligible set for property-first permit harvest. Configure via the
`PROPERTY_FIRST_PERMIT_ELIGIBLE_USAGE_TYPES` env (CSV) on the transform and permit
workers; defaults live in `workflow/lambdas/transform-worker/index.mjs` and
`workflow/lambdas/permit-harvest-worker/index.mjs` and are keyed to LEE vocabulary — a new
county almost certainly needs an override.

## 5. Smoke test

Send one workflow message for one parcel (see `county-ingest-run` for message shape) and
verify in order: prepare capture zip in S3 → transform artifact zip → structured-archive
success event → eligibility manifest present. Use
`npm run query-post-logs` and CloudWatch logs for the downloader/transform workers when
debugging.

## Gotchas

- Geo-blocking: some county portals block datacenter IPs; proxy rotation is supported via
  `PROXY_FILE` (see README) and was needed intermittently for Lee.
- A transform-script county-name mismatch can silently produce wrong-county labels in
  output (the "Columbia county" incident) — verify `county_jurisdiction` in transformed
  output equals the expected county.
