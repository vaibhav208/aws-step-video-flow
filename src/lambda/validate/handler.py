"""
validate — lightweight, S3-metadata-only validation of an uploaded video.

Step Functions Task contract
-----------------------------
Input  (via InputPath, only the fields this state needs — see
         step-functions/state-machine.json in Phase 3):
    {
        "job_id": "abc123",
        "bucket": "aws-step-video-flow-dev-media-111111111111",
        "key": "uploads/abc123/source.mp4"
    }

Output (merged back into the execution state via ResultPath in Phase 3):
    {
        "job_id": "abc123",
        "bucket": "...",
        "key": "...",
        "is_valid": true,
        "validation_errors": [],
        "file_size": 104857600,
        "format": "mp4",
        "content_type": "video/mp4"
    }

This function deliberately does NOT decide what happens on invalid input —
that's the state machine's Choice state, not this Lambda's job. It reports
facts (is_valid + why); Step Functions branches on them. Keeping the
branching decision in ASL rather than in Lambda code is what makes it
visible in the Step Functions console and testable without invoking AWS at
all (see tests/lambda/test_validate.py).

Errors
------
`SourceObjectNotFoundError` is raised (not swallowed into is_valid=False)
when the S3 object itself doesn't exist, because that's a different failure
class from "the video is invalid" — an EventBridge event that raced ahead
of eventual-consistency, or a bad key, is worth retrying with backoff
(configured on the Task state in Phase 3), where a genuinely invalid video
format is not something a retry will ever fix.
"""

from __future__ import annotations

import logging
import os

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

DEFAULT_ALLOWED_FORMATS = "mp4,mov,mkv,avi"
DEFAULT_MAX_FILE_SIZE_BYTES = 5 * 1024 * 1024 * 1024  # 5 GiB


class SourceObjectNotFoundError(Exception):
    """The S3 object referenced by the job doesn't exist (yet, or at all)."""


class TransientS3Error(Exception):
    """A retryable S3-side error (throttling, internal error, timeout)."""


_RETRYABLE_S3_ERROR_CODES = {
    "Throttling",
    "ThrottlingException",
    "RequestTimeout",
    "InternalError",
    "ServiceUnavailable",
    "SlowDown",
}


def _allowed_formats() -> set[str]:
    raw = os.environ.get("ALLOWED_FORMATS", DEFAULT_ALLOWED_FORMATS)
    return {ext.strip().lower().lstrip(".") for ext in raw.split(",") if ext.strip()}


def _max_file_size_bytes() -> int:
    return int(os.environ.get("MAX_FILE_SIZE_BYTES", DEFAULT_MAX_FILE_SIZE_BYTES))


def lambda_handler(event, context):  # noqa: ARG001 - context required by Lambda
    job_id = event["job_id"]
    bucket = event["bucket"]
    key = event["key"]

    logger.info("Validating job_id=%s bucket=%s key=%s", job_id, bucket, key)

    try:
        head = s3.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "")
        if error_code in ("404", "NoSuchKey", "NotFound"):
            logger.error("Source object not found: s3://%s/%s", bucket, key)
            raise SourceObjectNotFoundError(f"s3://{bucket}/{key} does not exist") from exc
        if error_code in _RETRYABLE_S3_ERROR_CODES:
            logger.warning("Transient S3 error (%s) reading s3://%s/%s", error_code, bucket, key)
            raise TransientS3Error(str(exc)) from exc
        raise

    file_size = head["ContentLength"]
    content_type = head.get("ContentType", "application/octet-stream")

    extension = key.rsplit(".", 1)[-1].lower() if "." in key else ""
    allowed = _allowed_formats()
    max_size = _max_file_size_bytes()

    validation_errors: list[str] = []

    if extension not in allowed:
        validation_errors.append(
            f"Unsupported format '.{extension}'. Allowed formats: {sorted(allowed)}"
        )

    if file_size <= 0:
        validation_errors.append("File is empty (0 bytes).")
    elif file_size > max_size:
        validation_errors.append(
            f"File size {file_size} bytes exceeds the {max_size}-byte limit."
        )

    is_valid = len(validation_errors) == 0

    logger.info(
        "Validation result for job_id=%s: is_valid=%s errors=%s",
        job_id,
        is_valid,
        validation_errors,
    )

    return {
        "job_id": job_id,
        "bucket": bucket,
        "key": key,
        "is_valid": is_valid,
        "validation_errors": validation_errors,
        "file_size": file_size,
        "format": extension,
        "content_type": content_type,
    }
