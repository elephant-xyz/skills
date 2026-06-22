---
name: county-appraisal-onboarding
description: Wire a new county's appraisal scraping into oracle-node - browser flow JSON, per-county prepare queue, per-county prepare flags, transform scripts from Counties-trasform-scripts, and appraisal-source throughput gates. Use when onboarding a county's property appraiser site, creating browser flows, or when prepare fails for a specific county.
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

Before scaling beyond smoke tests, use the `county-discovery` source-feasibility estimate
or pilot timings from `county-ingest-run`. If the full appraisal download is estimated
above 48 hours, ask the operator whether to continue the scrape, ingest records into
the query DB, or move this source to runtime retrieval in an owning app.

## 3. Transform scripts (reuse first)

County transform scripts live in `github.com/elephant-xyz/Counties-trasform-scripts`
under `<county>/scripts/` (`data_extractor.js` + mapping modules), synced to S3 for the
transform worker. The scripts-manager matches county-name variants (spaces, underscores,
hyphens).

1. If the county folder EXISTS: do not trust it blindly. Run the `validate-county-transform`
   skill against fresh prepare captures covering data variability. Fix gaps before scaling.
2. If it does NOT exist: author a transform v2 handler package — use the
   `transform-v2-builder` skill — then validate the same way. New or changed scripts must
   be committed on a branch and PR'd to `Counties-trasform-scripts` (`gh pr create`) —
   never left only in a local checkout or only synced to S3.
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

## Transform worker tuning (heavy parcels)

The default `TransformWorkerFunction` config (512 MB / 300 s) is **too low for heavy
parcels** (400+ data files in `output.zip`). Two failure modes observed in Lee full-county
ingestion:

| Failure | Root cause | Fix |
|---------|-----------|-----|
| 300 s TIMEOUT | 512 MB = too little CPU allocation; transform takes 30–180 s on arm64 at 512 MB | Bump MemorySize (more RAM = more vCPU) |
| EMFILE "too many open files" | `@elephant-xyz/cli` reads via `fs.promises` with unbounded `Promise.all`, hitting Lambda's 1024-fd limit | Monkey-patch `fs.promises` with a semaphore (NOT `graceful-fs`) |

**Production settings (in `prepare/template.yaml`, `TransformWorkerFunction`):**

```yaml
MemorySize: 10240  # was 512 (3008 is good; 10240 is max — use what the run needs)
Timeout: 900       # was 300 — max allowed; covers worst-case heavy parcels
```

**EMFILE fix — why `graceful-fs` does NOT work here:**

`graceful-fs.gracefulify()` only patches Node's callback-based and sync `fs` API.
`@elephant-xyz/cli` uses `fs.promises` (async/await), which `graceful-fs` does NOT patch
— so adding `graceful-fs` as a dependency and calling `gracefulify(require('fs'))` has
zero effect on the EMFILE errors.

**The real fix:** monkey-patch `fs.promises` directly in the transform worker at init
time, before any other module is imported. Wrap `readFile`, `readdir`, `writeFile`,
`stat`, `mkdir`, `rm`, and any other `fs.promises` methods the CLI uses with a
concurrency-limited semaphore (~128 concurrent operations). Since `fs.promises` is a
singleton object in the Node module graph, patching it in the worker entry point
(`workflow/lambdas/transform-worker/index.mjs`) affects the same object that the CLI
imports — no `createRequire` tricks needed.

This is implemented in `oracle-node` on branch `fix/transform-worker-emfile-fd-limiter`.
The fd-limiter utility lives at `workflow/lambdas/transform-worker/fd-limiter.mjs`.
Import and call it as the very first statement in the worker before any other imports.

**Deploy after any config change:**

```bash
AWS_PROFILE=elephant-oracle-node AWS_REGION=us-east-1 ./scripts/deploy-infra.sh
```

This runs `sam build` + `sam deploy` against `prepare/template.yaml` on stack
`elephant-oracle-node`. The IaC change is the durable fix; a temporary CLI bump
(`aws lambda update-function-configuration`) can be applied for immediate relief before
the next deploy.

## Surgical worker hotfix (when local sam build can't run)

If `sam build` fails locally (e.g. nodejs22 unavailable, arm64 build env mismatch),
hotfix the deployed Lambda bundle directly:

1. **Download the deployed bundle:**
   ```bash
   # Get the signed S3 URL for the deployed code
   aws lambda get-function --function-name <TransformWorkerFunctionName> \
     --query 'Code.Location' --output text
   # Download it
   curl -o /tmp/transform-worker.zip "<url>"
   ```
2. **Swap the file:**
   ```bash
   cd /tmp && unzip transform-worker.zip -d tw-bundle
   cp /path/to/oracle-node/workflow/lambdas/transform-worker/index.mjs tw-bundle/
   # Add any new files (e.g. fd-limiter.mjs)
   cp /path/to/oracle-node/workflow/lambdas/transform-worker/fd-limiter.mjs tw-bundle/
   cd tw-bundle && zip -r /tmp/transform-worker-patched.zip .
   ```
3. **Upload via S3 (bundles >50 MB require S3, not direct upload):**
   ```bash
   aws s3 cp /tmp/transform-worker-patched.zip \
     s3://<deployment-bucket>/hotfix/transform-worker-patched.zip \
     --profile elephant-oracle-node
   aws lambda update-function-code \
     --function-name <TransformWorkerFunctionName> \
     --s3-bucket <deployment-bucket> \
     --s3-key hotfix/transform-worker-patched.zip \
     --profile elephant-oracle-node --region us-east-1
   ```
4. **Verify** — invoke a test parcel, confirm EMFILE errors are gone.
5. **Follow up** with a proper `sam deploy` as soon as the build env is available — the
   hotfix is ephemeral and will be overwritten by the next deploy.
