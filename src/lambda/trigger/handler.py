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

STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
DEFAULT_TARGET_RESOLUTIONS = "1080p,720p,480p"


class UnrecognizedKeyShapeError(Exception):
    """The object key isn't shaped like uploads/<job_id>/<filename>."""


def _target_resolutions() -> list[str]:
    raw = os.environ.get("TARGET_RESOLUTIONS", DEFAULT_TARGET_RESOLUTIONS)
    return [r.strip() for r in raw.split(",") if r.strip()]


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
        "resolutions": _target_resolutions(),
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
