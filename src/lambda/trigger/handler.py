"""
trigger — thin Lambda that turns an S3 "Object Created" EventBridge event
into a Step Functions execution. This is the ONLY piece of Phase 4 that
runs as Lambda rather than declaratively in ASL, and deliberately so: it's
the one place actual event-shape parsing has to happen before the state
machine's structured input even exists.

Event contract (EventBridge "Object Created" notification, filtered by the
eventbridge module's rule to this bucket + the "uploads/" key prefix — see
terraform/modules/eventbridge/main.tf):
    {
        "detail": {
            "bucket": {"name": "aws-step-video-flow-dev-media-111111111111"},
            "object": {"key": "uploads/job-abc123/source.mp4", ...}
        },
        ...
    }

This function does NOT duplicate the validate Lambda's format/size checks —
consistent with the rest of this project (see src/lambda/validate/handler.py's
docstring), "is this video acceptable" is a decision the state machine's
ValidateVideo/IsVideoValid states make, not this trigger. The only filtering
here is structural: is this key shaped like `uploads/<job_id>/<filename>` at
all. Anything under uploads/ that isn't (e.g. a bare "uploads/" folder-marker
object, or a key with no filename segment) is skipped rather than starting a
doomed execution.

Idempotency
-----------
The Step Functions execution name is set to the job_id itself (not
job_id + a timestamp). Standard Workflow StartExecution is idempotent on
(name, input): a duplicate EventBridge delivery of the same S3 event (which
does happen — see AWS's own docs on "at least once" delivery) calls
StartExecution with the same name and the same input, and Step Functions
just returns the ARN of the execution already running rather than starting a
second one. `ExecutionAlreadyExists` is caught and logged at INFO, not
treated as a failure.

The tradeoff: re-uploading a real replacement file to the exact same job_id
key within 90 days will hit ExecutionAlreadyExists and NOT start a new
execution. That's judged the right default for this project (one S3 upload
== one job_id == one execution) — a genuine reprocess-this-job workflow
would need a caller-supplied distinct job_id, which is how the manual
`aws stepfunctions start-execution` path (step-functions/README.md) already
works.

Per-upload resolution choice (added alongside the web frontend, Phase 6)
--------------------------------------------------------------------------
EventBridge's S3 "Object Created" notification does NOT include the
object's user-defined metadata — only bucket/key/size/etag/etc — so this
function can't read a caller's resolution choice straight off the event
that woke it up. Instead, `web_api`'s `/presign` route (see
src/lambda/web_api/handler.py) signs the upload with an
`x-amz-meta-resolutions` header baked into the presigned URL, and this
function makes its own HeadObject call to read that metadata back once the
event fires. Any upload that doesn't go through the web frontend (the S3
console, the CLI, `scripts/upload-test-video.sh`, a direct `aws s3 cp`) has
no such metadata, so it falls through to the same TARGET_RESOLUTIONS
default this function has always used — this is purely additive.
"""

from __future__ import annotations

import json
import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

sfn = boto3.client("stepfunctions")
s3 = boto3.client("s3")

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
DEFAULT_TARGET_RESOLUTIONS = "1080p,720p,480p"

# Mirrors src/video-processor/app/main.py's RESOLUTION_PRESETS keys — kept
# as a separate literal here (rather than imported) because this function
# and the ECS app are packaged and deployed completely independently.
ALLOWED_RESOLUTIONS = {"1440p", "1080p", "720p", "480p", "360p", "240p"}


class UnrecognizedKeyShapeError(Exception):
    """The object key isn't shaped like uploads/<job_id>/<filename>."""


def _target_resolutions() -> list[str]:
    raw = os.environ.get("TARGET_RESOLUTIONS", DEFAULT_TARGET_RESOLUTIONS)
    return [r.strip() for r in raw.split(",") if r.strip()]


def _dedupe_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for v in values:
        if v not in seen:
            seen.add(v)
            result.append(v)
    return result


def _resolutions_for_upload(bucket: str, key: str) -> list[str]:
    """Reads the uploaded object's `resolutions` metadata (set by web_api's
    /presign) and falls back to the project-wide TARGET_RESOLUTIONS default
    whenever that metadata is missing, unreadable, or contains nothing
    recognized. A HeadObject failure (object not there yet, wrong bucket in
    a test, permissions hiccup) is treated the same as "no metadata" rather
    than as a reason to fail the whole trigger — starting the execution
    with sane defaults is better than not starting it at all, and the
    (separate) validate Lambda is what actually decides pass/fail once the
    execution reaches ValidateVideo.
    """
    try:
        head = s3.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        logger.info(
            "Could not read metadata for s3://%s/%s (%s) — using default resolutions",
            bucket, key, exc,
        )
        return _target_resolutions()

    raw = head.get("Metadata", {}).get("resolutions", "")
    requested = [r.strip() for r in raw.split(",") if r.strip()]
    valid = _dedupe_preserve_order([r for r in requested if r in ALLOWED_RESOLUTIONS])

    if not valid:
        return _target_resolutions()
    return valid


def _job_id_from_key(key: str) -> str:
    # Expected shape: "uploads/<job_id>/<filename>" (at least 3 segments,
    # non-empty job_id and filename). The EventBridge rule (eventbridge
    # module) already filters to the "uploads/" prefix before this function
    # is ever invoked, but that filter lives in infrastructure config, not
    # code -- checking it again here is a deliberate defense-in-depth
    # backstop against a future rule change (or a direct test invocation)
    # that doesn't go through the rule at all.
    parts = key.split("/")
    if len(parts) < 3 or parts[0] != "uploads" or not parts[1] or not parts[2]:
        raise UnrecognizedKeyShapeError(f"key '{key}' is not shaped like uploads/<job_id>/<filename>")
    return parts[1]


def lambda_handler(event, context):  # noqa: ARG001 - context required by Lambda
    detail = event.get("detail", {})
    bucket = detail.get("bucket", {}).get("name")
    key = detail.get("object", {}).get("key")

    if not bucket or not key:
        logger.warning("Event missing detail.bucket.name/detail.object.key, skipping: %s", event)
        return {"skipped": True, "reason": "malformed event"}

    try:
        job_id = _job_id_from_key(key)
    except UnrecognizedKeyShapeError as exc:
        logger.info("Skipping s3://%s/%s: %s", bucket, key, exc)
        return {"skipped": True, "reason": str(exc)}

    execution_input = {
        "job_id": job_id,
        "bucket": bucket,
        "key": key,
        "resolutions": _resolutions_for_upload(bucket, key),
    }

    logger.info(
        "Starting execution for job_id=%s from s3://%s/%s, resolutions=%s",
        job_id,
        bucket,
        key,
        execution_input["resolutions"],
    )

    try:
        response = sfn.start_execution(
            stateMachineArn=STATE_MACHINE_ARN,
            name=job_id,
            input=json.dumps(execution_input),
        )
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "")
        if error_code == "ExecutionAlreadyExists":
            logger.info(
                "Execution already exists for job_id=%s (duplicate S3 event delivery, or a "
                "prior attempt for this job) — not starting a second one.",
                job_id,
            )
            return {"job_id": job_id, "started": False, "reason": "ExecutionAlreadyExists"}
        raise

    logger.info("Started execution %s for job_id=%s", response["executionArn"], job_id)
    return {"job_id": job_id, "started": True, "execution_arn": response["executionArn"]}
