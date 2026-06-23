#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Usage: ingestion-status.sh --config <county-env-file> [--window-minutes 60] [--job-id <job-id>]

Prints a consolidated JSON status report for one county's oracle-node ingestion:
appraisal prepare queue, property-first permit queue(s), S3 artifact counts, and
optional Sunbiz transform summary.

The config file is a shell env file defining the county's resources, e.g.:

  APPRAISAL_QUEUE_URL=...
  APPRAISAL_QUEUE_NAME=...
  APPRAISAL_EVENT_SOURCE_UUID=...
  APPRAISAL_FUNCTION_NAME=...
  PERMIT_QUEUE_URL=...
  PERMIT_QUEUE_NAME=...
  PERMIT_DLQ_URL=...
  PERMIT_FUNCTION_NAME=...
  PERMIT_JOB_PREFIX=s3://<env-bucket>/permit-harvest/<jobId>
  PERMIT_JOB_ROOT=permit-harvest/lee-property-first-seed/  # optional auto-detect root
  COUNTY_KEY=lee
  SUNBIZ_SUMMARY_S3_URI=...   # optional

See config/lee.env.example for a complete example. Discover values via:
  aws cloudformation describe-stacks (queue URLs from stack outputs)
  aws lambda list-event-source-mappings --function-name <fn>
Set AWS_PROFILE and AWS_REGION before running.
USAGE
}

WINDOW_MINUTES=60
CONFIG_FILE=""
JOB_ID=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --config)
      CONFIG_FILE="${2:-}"
      shift 2
      ;;
    --window-minutes)
      WINDOW_MINUTES="${2:-}"
      shift 2
      ;;
    --job-id)
      JOB_ID="${2:-}"
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

if [[ -z "$CONFIG_FILE" || ! -f "$CONFIG_FILE" ]]; then
  echo "Missing --config env file" >&2
  usage >&2
  exit 2
fi

# shellcheck disable=SC1090
source "$CONFIG_FILE"

for req in APPRAISAL_QUEUE_URL APPRAISAL_QUEUE_NAME APPRAISAL_FUNCTION_NAME PERMIT_QUEUE_URL PERMIT_QUEUE_NAME PERMIT_DLQ_URL PERMIT_FUNCTION_NAME COUNTY_KEY; do
  if [[ -z "${!req:-}" ]]; then
    echo "Config missing required variable: $req" >&2
    exit 2
  fi
done

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required" >&2
  exit 127
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required" >&2
  exit 127
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOW_UTC="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
if date -u -v-1M +%Y-%m-%dT%H:%M:%SZ >/dev/null 2>&1; then
  START_UTC="$(date -u -v-"${WINDOW_MINUTES}"M +%Y-%m-%dT%H:%M:%SZ)"
else
  START_UTC="$(date -u -d "${WINDOW_MINUTES} minutes ago" +%Y-%m-%dT%H:%M:%SZ)"
fi

s3_bucket_from_uri() {
  local s3_uri="$1"
  local without_scheme="${s3_uri#s3://}"
  printf '%s\n' "${without_scheme%%/*}"
}

latest_active_permit_job_prefix() {
  local bucket="$1"
  local root="${2%/}/"
  local root_segments
  local objects
  local best_line
  root_segments="$(
    awk -v root="${root%/}" 'BEGIN {
      split(root, parts, "/")
      for (i in parts) {
        if (parts[i] != "") count++
      }
      print count
    }'
  )"
  if ! objects="$(
    aws s3api list-objects-v2 \
      --bucket "$bucket" \
      --prefix "$root" \
      --query 'Contents[].[LastModified,Key]' \
      --output text
  )"; then
    echo "Failed to auto-detect permit job prefix under s3://${bucket}/${root}" >&2
    return 2
  fi
  best_line="$(
    printf '%s\n' "$objects" \
      | awk -v county="$COUNTY_KEY" -v jobSegmentCount="$root_segments" '
          index($2, "/" county "/extracted/permits/") || index($2, "/" county "/raw/permit-details/") {
            split($2, parts, "/")
            if (parts[jobSegmentCount + 1] != "") {
              jobKey = parts[1]
              for (i = 2; i <= jobSegmentCount + 1; i++) {
                jobKey = jobKey "/" parts[i]
              }
              print $1 "\t" jobKey
            }
          }
        ' \
      | sort \
      | tail -n 1
  )"
  if [[ -z "$best_line" ]]; then
    return 1
  fi
  printf 's3://%s/%s\n' "$bucket" "${best_line#*$'\t'}"
}

resolve_permit_job_prefix() {
  local configured_prefix="${PERMIT_JOB_PREFIX:-}"
  local bucket="${PERMIT_ARTIFACT_BUCKET:-}"
  local root="${PERMIT_JOB_ROOT:-permit-harvest/${COUNTY_KEY}-property-first-seed/}"

  if [[ -z "$bucket" && -n "$configured_prefix" ]]; then
    bucket="$(s3_bucket_from_uri "$configured_prefix")"
  fi
  if [[ -z "$bucket" ]]; then
    echo "Config must set PERMIT_JOB_PREFIX or PERMIT_ARTIFACT_BUCKET for permit artifact lookup" >&2
    exit 2
  fi

  if [[ -n "$JOB_ID" ]]; then
    printf '%s\t%s\n' "job-id" "s3://${bucket}/${root%/}/${JOB_ID}"
    return
  fi

  local detected_prefix=""
  local detect_status=0
  detected_prefix="$(latest_active_permit_job_prefix "$bucket" "$root")" || detect_status=$?
  if [[ "$detect_status" -eq 0 ]]; then
    printf '%s\t%s\n' "auto-detected" "$detected_prefix"
    return
  fi
  if [[ "$detect_status" -ne 1 ]]; then
    exit "$detect_status"
  fi

  if [[ -n "$configured_prefix" ]]; then
    printf '%s\t%s\n' "configured" "$configured_prefix"
    return
  fi

  echo "No permit job prefix found under s3://${bucket}/${root}" >&2
  exit 2
}

queue_attrs() {
  local queue_url="$1"
  aws sqs get-queue-attributes --queue-url "$queue_url" --attribute-names All \
    | jq '.Attributes | {
        visible: (.ApproximateNumberOfMessages | tonumber),
        notVisible: (.ApproximateNumberOfMessagesNotVisible | tonumber),
        delayed: (.ApproximateNumberOfMessagesDelayed | tonumber),
        visibilityTimeoutSeconds: (.VisibilityTimeout | tonumber)
      }'
}

sqs_deleted_sum() {
  local queue_name="$1"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/SQS \
    --metric-name NumberOfMessagesDeleted \
    --dimensions "Name=QueueName,Value=${queue_name}" \
    --start-time "$START_UTC" \
    --end-time "$NOW_UTC" \
    --period 300 \
    --statistics Sum \
    | jq '[.Datapoints[].Sum] | add // 0'
}

lambda_concurrency_max() {
  local function_name="$1"
  aws cloudwatch get-metric-statistics \
    --namespace AWS/Lambda \
    --metric-name ConcurrentExecutions \
    --dimensions "Name=FunctionName,Value=${function_name}" \
    --start-time "$START_UTC" \
    --end-time "$NOW_UTC" \
    --period 300 \
    --statistics Maximum \
    | jq '[.Datapoints[].Maximum] | max // 0'
}

event_source_summary() {
  local uuid="$1"
  aws lambda get-event-source-mapping --uuid "$uuid" \
    | jq '{state: .State, batchSize: .BatchSize, maximumConcurrency: (.ScalingConfig.MaximumConcurrency // null)}'
}

first_event_source_summary() {
  local function_name="$1"
  aws lambda list-event-source-mappings --function-name "$function_name" \
    | jq '.EventSourceMappings[0] | {state: .State, batchSize: .BatchSize, maximumConcurrency: (.ScalingConfig.MaximumConcurrency // null), uuid: .UUID}'
}

reserved_concurrency() {
  local function_name="$1"
  local response
  response="$(aws lambda get-function-concurrency --function-name "$function_name" 2>/dev/null || true)"
  if [[ -z "$response" ]]; then
    printf 'null\n'
    return
  fi
  jq '.ReservedConcurrentExecutions // null' <<<"$response"
}

eta_hours_from_rate() {
  local backlog="$1"
  local processed="$2"
  jq -n --argjson backlog "$backlog" --argjson processed "$processed" --argjson windowMinutes "$WINDOW_MINUTES" '
    if $processed <= 0 then null
    else (($backlog / ($processed / $windowMinutes)) / 60)
    end
  '
}

APPRAISAL_ATTRS="$(queue_attrs "$APPRAISAL_QUEUE_URL")"
APPRAISAL_DELETED="$(sqs_deleted_sum "$APPRAISAL_QUEUE_NAME")"
if [[ -n "${APPRAISAL_EVENT_SOURCE_UUID:-}" ]]; then
  APPRAISAL_EVENT_SOURCE="$(event_source_summary "$APPRAISAL_EVENT_SOURCE_UUID")"
else
  APPRAISAL_EVENT_SOURCE="$(first_event_source_summary "$APPRAISAL_FUNCTION_NAME")"
fi
APPRAISAL_CONCURRENCY_MAX="$(lambda_concurrency_max "$APPRAISAL_FUNCTION_NAME")"
APPRAISAL_RESERVED="$(reserved_concurrency "$APPRAISAL_FUNCTION_NAME")"
APPRAISAL_BACKLOG="$(jq -n --argjson attrs "$APPRAISAL_ATTRS" '$attrs.visible + $attrs.notVisible + $attrs.delayed')"
APPRAISAL_ETA_HOURS="$(eta_hours_from_rate "$APPRAISAL_BACKLOG" "$APPRAISAL_DELETED")"

PERMIT_ATTRS="$(queue_attrs "$PERMIT_QUEUE_URL")"
PERMIT_DLQ_ATTRS="$(queue_attrs "$PERMIT_DLQ_URL")"
PERMIT_DELETED="$(sqs_deleted_sum "$PERMIT_QUEUE_NAME")"
PERMIT_EVENT_SOURCE="$(first_event_source_summary "$PERMIT_FUNCTION_NAME")"
PERMIT_CONCURRENCY_MAX="$(lambda_concurrency_max "$PERMIT_FUNCTION_NAME")"
PERMIT_RESERVED="$(reserved_concurrency "$PERMIT_FUNCTION_NAME")"
PERMIT_BACKLOG="$(jq -n --argjson attrs "$PERMIT_ATTRS" '$attrs.visible + $attrs.notVisible + $attrs.delayed')"
PERMIT_QUEUE_ETA_HOURS="$(eta_hours_from_rate "$PERMIT_BACKLOG" "$PERMIT_DELETED")"
PERMIT_JOB_RESOLUTION="$(resolve_permit_job_prefix)"
PERMIT_JOB_PREFIX_SOURCE="${PERMIT_JOB_RESOLUTION%%$'\t'*}"
PERMIT_JOB_PREFIX_RESOLVED="${PERMIT_JOB_RESOLUTION#*$'\t'}"
PERMIT_JOB_PREFIX_RESOLVED="${PERMIT_JOB_PREFIX_RESOLVED%/}"

PERMIT_EXTRACTED="$(${SCRIPT_DIR}/s3-prefix-count.sh --s3-uri "${PERMIT_JOB_PREFIX_RESOLVED}/${COUNTY_KEY}/extracted/permits/" --window-minutes "$WINDOW_MINUTES")"
PERMIT_RAW_DETAILS="$(${SCRIPT_DIR}/s3-prefix-count.sh --s3-uri "${PERMIT_JOB_PREFIX_RESOLVED}/${COUNTY_KEY}/raw/permit-details/" --window-minutes "$WINDOW_MINUTES")"
PERMIT_LISTS="$(${SCRIPT_DIR}/s3-prefix-count.sh --s3-uri "${PERMIT_JOB_PREFIX_RESOLVED}/${COUNTY_KEY}/permit-lists/" --window-minutes "$WINDOW_MINUTES")"

if [[ -n "${SUNBIZ_SUMMARY_S3_URI:-}" ]]; then
  SUNBIZ_SUMMARY="$(SUNBIZ_SUMMARY_S3_URI="$SUNBIZ_SUMMARY_S3_URI" ${SCRIPT_DIR}/sunbiz-summary.sh)"
else
  SUNBIZ_SUMMARY="null"
fi

jq -n \
  --arg generatedAt "$NOW_UTC" \
  --arg countyKey "$COUNTY_KEY" \
  --arg permitJobPrefix "$PERMIT_JOB_PREFIX_RESOLVED" \
  --arg permitJobPrefixSource "$PERMIT_JOB_PREFIX_SOURCE" \
  --argjson windowMinutes "$WINDOW_MINUTES" \
  --argjson appraisalAttrs "$APPRAISAL_ATTRS" \
  --argjson appraisalDeleted "$APPRAISAL_DELETED" \
  --argjson appraisalEventSource "$APPRAISAL_EVENT_SOURCE" \
  --argjson appraisalConcurrencyMax "$APPRAISAL_CONCURRENCY_MAX" \
  --argjson appraisalReserved "$APPRAISAL_RESERVED" \
  --argjson appraisalEtaHours "$APPRAISAL_ETA_HOURS" \
  --argjson permitAttrs "$PERMIT_ATTRS" \
  --argjson permitDlqAttrs "$PERMIT_DLQ_ATTRS" \
  --argjson permitDeleted "$PERMIT_DELETED" \
  --argjson permitEventSource "$PERMIT_EVENT_SOURCE" \
  --argjson permitConcurrencyMax "$PERMIT_CONCURRENCY_MAX" \
  --argjson permitReserved "$PERMIT_RESERVED" \
  --argjson permitQueueEtaHours "$PERMIT_QUEUE_ETA_HOURS" \
  --argjson permitExtracted "$PERMIT_EXTRACTED" \
  --argjson permitRawDetails "$PERMIT_RAW_DETAILS" \
  --argjson permitLists "$PERMIT_LISTS" \
  --argjson sunbiz "$SUNBIZ_SUMMARY" \
  '{
    generatedAt: $generatedAt,
    countyKey: $countyKey,
    windowMinutes: $windowMinutes,
    appraisal: {
      status: (if $appraisalEventSource.state == "Enabled" then "running" else "paused" end),
      queue: $appraisalAttrs,
      eventSource: $appraisalEventSource,
      lambda: {reservedConcurrency: $appraisalReserved, maxConcurrentExecutionsInWindow: $appraisalConcurrencyMax},
      messagesDeletedInWindow: $appraisalDeleted,
      etaHoursAtCurrentDeleteRate: (if $appraisalEventSource.state == "Enabled" then $appraisalEtaHours else null end),
      note: (if $appraisalEventSource.state == "Enabled" then "ETA uses recent SQS delete rate." else "Event source is disabled; backlog is not draining, so live ETA is paused." end)
    },
    permits: {
      status: (if $permitEventSource.state == "Enabled" then "running" else "paused" end),
      queue: $permitAttrs,
      deadLetterQueue: $permitDlqAttrs,
      eventSource: $permitEventSource,
      lambda: {reservedConcurrency: $permitReserved, maxConcurrentExecutionsInWindow: $permitConcurrencyMax},
      jobPrefix: $permitJobPrefix,
      jobPrefixSource: $permitJobPrefixSource,
      messagesDeletedInWindow: $permitDeleted,
      currentQueueDrainEtaHours: $permitQueueEtaHours,
      s3Artifacts: {
        extractedPermits: $permitExtracted,
        rawPermitDetails: $permitRawDetails,
        permitLists: $permitLists
      },
      note: "ETA is a lower bound: upstream stages and the seed feeder can still enqueue more work."
    },
    sunbiz: (if $sunbiz == null then null else {
      status: (if ($sunbiz.counters.invalidRecordCount == 0 and $sunbiz.counters.transformedRecordCount == $sunbiz.counters.sourceRecordCount) then "complete" else "needs_attention" end),
      summary: $sunbiz
    } end)
  }'
