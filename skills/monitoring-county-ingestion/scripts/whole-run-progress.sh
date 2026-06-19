#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: whole-run-progress.sh --config <county-env-file>
       whole-run-progress.sh --feeder-state-uri s3://.../feeder-state.json [--total-rows N]

Reports whole-run progress for a property-first seed-feeder ingestion: how far the
feeder has advanced through the seed CSV (nextSourceRowNumber), how many rows it has
enqueued/skipped, whether the seed CSV is exhausted, and (if the seed total is known)
percent complete.

This reads the feeder checkpoint that the permit-harvest worker writes
(schemaVersion "permit-harvest.lee-property-first-seed-feeder-state.v1").

Resolve inputs from a config env file (same file used by ingestion-status.sh) or pass
them directly. Recognised config variables:

  FEEDER_STATE_S3_URI=s3://<env-bucket>/permit-harvest/<jobId>/feeder-state.json
  SEED_TOTAL_ROWS=516848        # data rows in the seed CSV (excl. header); optional

Direct flags override config values. Set AWS_PROFILE and AWS_REGION before running.
USAGE
}

CONFIG_FILE=""
FEEDER_STATE_URI_ARG=""
TOTAL_ROWS_ARG=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --feeder-state-uri)
      FEEDER_STATE_URI_ARG="${2:-}"
      shift 2
      ;;
    --total-rows)
      TOTAL_ROWS_ARG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -n "$CONFIG_FILE" ]]; then
  if [[ ! -f "$CONFIG_FILE" ]]; then
    echo "Config file not found: $CONFIG_FILE" >&2
    exit 2
  fi
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
fi

FEEDER_STATE_S3_URI="${FEEDER_STATE_URI_ARG:-${FEEDER_STATE_S3_URI:-}}"
SEED_TOTAL_ROWS="${TOTAL_ROWS_ARG:-${SEED_TOTAL_ROWS:-}}"

if [[ -z "$FEEDER_STATE_S3_URI" ]]; then
  echo "Missing feeder state URI: set FEEDER_STATE_S3_URI in --config or pass --feeder-state-uri" >&2
  usage >&2
  exit 2
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required" >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 127
fi

STATE_JSON="$(aws s3 cp "$FEEDER_STATE_S3_URI" - 2>/dev/null)" || {
  echo "Could not read feeder state at $FEEDER_STATE_S3_URI (check the URI and AWS creds/region)" >&2
  exit 1
}

echo "$STATE_JSON" | jq \
  --arg feederStateUri "$FEEDER_STATE_S3_URI" \
  --argjson total "${SEED_TOTAL_ROWS:-null}" '
  (.nextSourceRowNumber // 1) as $next
  | ($next - 1) as $processed
  | {
      feederStateUri: $feederStateUri,
      jobId: .jobId,
      sourceCsvS3Uri: .sourceCsvS3Uri,
      schemaVersion: .schemaVersion,
      nextSourceRowNumber: $next,
      processedRows: $processed,
      enqueuedCount: .enqueuedCount,
      skippedExistingCount: .skippedExistingCount,
      skippedInvalidCount: .skippedInvalidCount,
      sourceExhausted: .sourceExhausted,
      updatedAt: .updatedAt,
      lastRun: .lastRun,
      totalSeedRows: $total,
      percentComplete: (
        if ($total != null and $total > 0)
        then (($processed * 10000 / $total | floor) / 100)
        else null end
      ),
      remainingRows: (
        if ($total != null) then ($total - $processed) else null end
      ),
      note: (
        if (.sourceExhausted == true and $total != null and $total > 0 and $processed < ($total * 0.99))
        then "Feeder reports sourceExhausted but processedRows (\($processed)) is far below totalSeedRows (\($total)) — the feeder was likely superseded by a one-shot bulk enqueue (see lastRun). Use ingestion-status.sh queue drain as the real progress signal."
        elif .sourceExhausted == true
        then "Feeder has exhausted the seed CSV — every row has been enqueued."
        elif $total == null
        then "Set SEED_TOTAL_ROWS (or --total-rows) to get percentComplete."
        else "Feeder is still advancing through the seed CSV."
        end
      )
    }'
