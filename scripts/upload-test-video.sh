#!/usr/bin/env bash
#
# Upload a local video file to the pipeline's S3 bucket under the
# uploads/<job_id>/ prefix, which is all it takes to trigger a real
# execution once Phase 4 (EventBridge + trigger Lambda) is applied -- see
# src/lambda/trigger/handler.py for the exact key-shape contract this
# script satisfies (uploads/<job_id>/<filename>).
#
# The object is always uploaded as "source.mp4" regardless of the local
# filename, matching the manual `aws s3 cp` example in README.md section 21
# and the key shape every other example in this project assumes
# (uploads/<job_id>/source.mp4).
#
# Usage:
#   scripts/upload-test-video.sh <local-video-file> <job-id>
#
# Example:
#   scripts/upload-test-video.sh my-video.mp4 job-auto-0002
#
# After uploading, this polls `stepfunctions list-executions` for a few
# seconds looking for an execution named <job-id> -- EventBridge delivery
# and the trigger Lambda are usually fast, but not instant.
#
# Env vars:
#   TF_DIR        - path to the terraform root module (default: terraform)
#   POLL_ATTEMPTS - how many times to poll for the execution (default: 10)
#   POLL_INTERVAL - seconds between polls (default: 2)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TF_DIR="${TF_DIR:-$REPO_ROOT/terraform}"
POLL_ATTEMPTS="${POLL_ATTEMPTS:-10}"
POLL_INTERVAL="${POLL_INTERVAL:-2}"

LOCAL_FILE="${1:-}"
JOB_ID="${2:-}"

if [[ -z "$LOCAL_FILE" || -z "$JOB_ID" ]]; then
  echo "Usage: $0 <local-video-file> <job-id>" >&2
  exit 1
fi

if [[ ! -f "$LOCAL_FILE" ]]; then
  echo "Error: '$LOCAL_FILE' does not exist or is not a regular file." >&2
  exit 1
fi

tf_output() {
  terraform -chdir="$TF_DIR" output -raw "$1"
}

BUCKET="$(tf_output media_bucket_name)"
STATE_MACHINE_ARN="$(tf_output state_machine_arn)"
KEY="uploads/${JOB_ID}/source.mp4"

echo "Uploading '$LOCAL_FILE' to s3://${BUCKET}/${KEY} ..."
aws s3 cp "$LOCAL_FILE" "s3://${BUCKET}/${KEY}"

echo "Uploaded. Waiting for EventBridge + the trigger Lambda to start an execution named '${JOB_ID}' ..."

for ((i = 1; i <= POLL_ATTEMPTS; i++)); do
  MATCH="$(aws stepfunctions list-executions \
    --state-machine-arn "$STATE_MACHINE_ARN" \
    --query "executions[?name==\`${JOB_ID}\`] | [0]" \
    --output json)"

  if [[ "$MATCH" != "null" ]]; then
    echo "Execution found:"
    echo "$MATCH"
    echo
    echo "Track it with:"
    echo "  aws stepfunctions describe-execution --execution-arn \"\$(aws stepfunctions list-executions --state-machine-arn '${STATE_MACHINE_ARN}' --query \"executions[?name==\\\`${JOB_ID}\\\`].executionArn | [0]\" --output text)\""
    echo "Or check the job record directly:"
    echo "  aws dynamodb get-item --table-name \"\$(cd '${TF_DIR}' && terraform output -raw dynamodb_table_name)\" --key '{\"job_id\": {\"S\": \"${JOB_ID}\"}}'"
    exit 0
  fi

  echo "  (attempt ${i}/${POLL_ATTEMPTS}) not yet visible, retrying in ${POLL_INTERVAL}s ..."
  sleep "$POLL_INTERVAL"
done

echo
echo "No execution named '${JOB_ID}' showed up after $((POLL_ATTEMPTS * POLL_INTERVAL))s." >&2
echo "The object IS uploaded (s3://${BUCKET}/${KEY}) -- this just means the" >&2
echo "trigger didn't fire yet, or fired under a different name. Check:" >&2
echo "  aws events describe-rule --name \"\$(cd '${TF_DIR}' && terraform output -raw eventbridge_rule_name)\"" >&2
echo "  aws logs tail \"/aws/lambda/\$(cd '${TF_DIR}' && terraform output -raw trigger_function_name)\" --since 5m" >&2
exit 1
