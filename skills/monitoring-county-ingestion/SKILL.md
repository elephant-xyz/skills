---
name: monitoring-county-ingestion
description: Monitor oracle-node county ingestion - SQS queue health, event-source state, Lambda concurrency, S3 artifact counts, Neon row counts, and ETAs - for any county plus Sunbiz transforms. Use when asked for ingestion status, ETA, backlog, permit harvest progress, appraisal queue progress, or why ingestion stalled.
metadata:
  author: elephant-xyz
---

# Monitoring County Ingestion

## Quick start

> Run these scripts — do not re-implement their AWS calls inline. They encode the correct
> queue/metric/stall-diagnosis logic and are macOS/Linux portable. Hand-rolling the checks
> re-introduces bugs these scripts already handle (e.g. `date` portability).

If a filled config already exists (e.g. `config/lee.env`), just use it. Otherwise create one
once: copy `config/lee.env.example` and fill it from CloudFormation stack outputs. Then:

```bash
AWS_PROFILE=<profile> AWS_REGION=<region> \
  scripts/ingestion-status.sh --config <county>.env --window-minutes 60
```

Paths are relative to this skill's directory.

**Permit job prefix is auto-detected.** By default the script auto-detects the latest active
`permit-harvest/<county>-property-first-seed/<jobId>` prefix, so permit counts always reflect
the *current* run (not a stale hardcoded job). Use `--job-id <job-id>` to force a specific
property-first seed run. It falls back to `PERMIT_JOB_PREFIX` only when no active prefix is
found. (This prevents the stale-prefix bug where a finished job's counts get reported as if
they were the live run's.)

## Workflow

1. Run `scripts/ingestion-status.sh`. It reports, per county: appraisal queue depth +
   delete rate + event-source state/concurrency, permit queue + DLQ, S3 artifact counts
   for the resolved job prefix, and (optionally) the Sunbiz transform summary.
2. Treat SQS counts as approximate (1-minute metric resolution; in-flight messages hidden
   during visibility timeout).
3. ETAs:
   - Appraisal: backlog ÷ recent delete rate. If the event-source mapping is `Disabled`,
     report the track as paused — no live ETA.
   - Permits: queue-drain ETA is a lower bound (the seed feeder and eligibility branch
     keep adding work). The extracted-permit S3 `recentCount` is the real throughput signal.
   - Whole run: `scripts/whole-run-progress.sh --config <county>.env` reads the feeder
     checkpoint (`feeder-state.json` `nextSourceRowNumber`) ÷ seed CSV total rows. Caveat: if
     `sourceExhausted` is true but processed rows are far below the seed total, the feeder was
     superseded by a one-shot bulk enqueue (see `lastRun`) — use the queue-drain signal from
     `ingestion-status.sh` instead.
4. Neon counts complement S3 counts — connect with `DATABASE_URL` from
   `../elephant-query-db/.env.local` and count `properties` / permit rows inserted in the
   window.
5. Stall diagnosis order: event-source mappings `Enabled`? → Lambda `Errors`/`Throttles`
   metrics → DLQ depth → CloudWatch logs (`aws logs tail /aws/lambda/<fn> --since 15m`).
   A disabled mapping with zero errors usually means something disabled it externally
   (the budget-handler incident pattern).
6. Legacy Lee date-window harvest only: `scripts/permit-list-progress.mjs` estimates
   split-tree completion for `lee-permit-list-window` runs.

## Helper scripts

- `scripts/ingestion-status.sh` — consolidated per-county report (requires `--config`)
- `scripts/whole-run-progress.sh` — feeder-checkpoint progress vs seed total (`--config`, or `--feeder-state-uri` + `--total-rows`)
- `scripts/s3-prefix-count.sh` — object count / recent count / bytes for any S3 prefix
- `scripts/sunbiz-summary.sh` — Sunbiz lexicon-transform counters (env `SUNBIZ_SUMMARY_S3_URI`)
- `scripts/permit-list-progress.mjs` — legacy Lee list-window progress

## Reporting guidance

Keep updates concise: status (running/paused/complete/blocked), key backlog count,
throughput window used, ETA or why ETA is not meaningful, and a caveat when a track is
dynamically discovering more work.
