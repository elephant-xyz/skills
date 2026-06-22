---
name: bbb-harvest
description: Harvest BBB (Better Business Bureau) business profiles by category for contractor reputation and quality enrichment in the elephant query DB, with throughput checks before long crawls. Use when asked to collect BBB profiles, contractor reputation data, or refresh bbb_* tables.
metadata:
  author: elephant-xyz
---

# BBB Harvest

National data source — county-agnostic. Local Puppeteer crawler at
`oracle-node/scripts/harvest-bbb-category.mjs`, output feeds the `bbb_*` tables in
`elephant-query-db` (contractor reputation/quality scores joined to permits via
contractor names).

## Run

```bash
node scripts/harvest-bbb-category.mjs \
  --category-url https://www.bbb.org/us/category/<category> \
  --output-s3-uri s3://<env-bucket>/bbb-harvest/<job-id>/ \
  --max-pages 50 --page-delay-ms 2000 --profile-delay-ms 1500
```

Useful flags (see `--help` for the full set):

- `--output-dir` (local) XOR `--output-s3-uri`
- `--start-page` / `--max-pages` / `--max-profiles` — resumable pagination
- `--profile-subpages` (repeatable) — capture extra tabs per profile
- `--challenge-attempts` / `--challenge-check-interval-ms` — bot-challenge retry tuning
- `--headless false` + `--chromium-executable-path` — when challenges need a real browser
- `--no-html` — skip raw HTML capture (keep HTML by default; raw-first principle)

## Output layout

- `profiles/profiles-part-NNNN.jsonl` — extracted profile records (chunked by
  `--part-record-limit`)
- `failures/failed-profiles.jsonl` — record failures rather than aborting; re-run with the
  failed URLs after a challenge-tuning change
- `manifest/summary.json` — counters for reconciliation

## Workflow

1. Pick the category relevant to the enrichment goal (e.g. construction/contractor
   categories for permit contractor matching).
2. Run a small probe (`--max-pages 2`) to confirm challenge handling works from the
   current network; BBB serves bot challenges that the script retries through, but
   datacenter IPs may need `--headless false` or a different egress. If pages come back
   403/blocked, check the egress country (`curl -s ipinfo.io/country`) — a US VPN/proxy
   exit may be required before anything else is worth debugging.
3. Estimate total crawl time from probe latency, page/profile counts, delays, retries, and
   safe concurrency. If the estimate is more than 48 hours, ask whether to download BBB
   artifacts anyway, ingest them into the query DB, or retrieve BBB profile data at
   runtime from the owning app/service. For runtime retrieval, capture the expected API or
   scrape path, cache/freshness needs, and failure behavior.
4. Run the full category with conservative delays; the crawler is resumable via
   `--start-page` and stable output parts.
5. Reconcile `summary.json` counts vs profiles parts, retry failures.
6. Load into Neon `bbb_*` tables per the `query-db-loading-matching` skill.

Tests for the harvester live at `tests/scripts/harvest-bbb-category.test.mjs` — keep them
passing if the script is modified.

Script changes are committed in `oracle-node`. Category lists, run notes, and any
source-specific docs produced for a county or category also get committed and PR'd to
`github.com/elephant-xyz/Counties-trasform-scripts` (`gh pr create`) so they aren't lost.
