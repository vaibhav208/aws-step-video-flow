"""
thumbnail — extracts a single JPEG frame from the source video using ffmpeg
and uploads it to S3 under thumbnails/<job_id>/thumbnail.jpg.

Deployed as a Lambda CONTAINER IMAGE sharing the same image as
metadata_handler.py — see that file's docstring and
src/lambda/ffmpeg/Dockerfile for why (250MB zip+layer limit vs 10GB
container image limit).

Like the metadata function, this reads the source via a presigned URL
rather than downloading the whole video to /tmp — ffmpeg only has to
decode forward to the requested timestamp, not pull the entire file. Only
the small JPEG OUTPUT touches /tmp.

This runs as one branch of the Phase 3 Parallel state (alongside metadata
storage), which is why it's a Lambda rather than an ECS task: it's a
few-hundred-millisecond, low-memory operation, not the CPU-heavy
multi-resolution transcoding the Map/ECS branch handles.

Step Functions Task contract
-----------------------------
Input:
    {
        "job_id": "abc123",
        "bucket": "...",
        "key": "uploads/abc123/source.mp4",
        "timestamp_seconds": 1      // optional, defaults to
                                    // THUMBNAIL_OFFSET_SECONDS env var
    }

Output:
    {
        "job_id": "abc123",
        "thumbnail_bucket": "...",
        "thumbnail_key": "thumbnails/abc123/thumbnail.jpg",
        "status": "SUCCESS"
    }
"""

from __future__ import annotations

import logging
import os
import subprocess
import tempfile

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

FFMPEG_PATH = os.environ.get("FFMPEG_PATH", "/usr/local/bin/ffmpeg")
DEFAULT_OFFSET_SECONDS = os.environ.get("THUMBNAIL_OFFSET_SECONDS", "1")
PRESIGNED_URL_EXPIRY_SECONDS = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", "300"))
FFMPEG_TIMEOUT_SECONDS = int(os.environ.get("FFMPEG_TIMEOUT_SECONDS", "25"))


class SourceObjectNotFoundError(Exception):
    pass


class ThumbnailGenerationError(Exception):
    pass


def lambda_handler(event, context):  # noqa: ARG001
    job_id = event["job_id"]
    bucket = event["bucket"]
    key = event["key"]
    output_bucket = event.get("output_bucket", bucket)
    offset_seconds = str(event.get("timestamp_seconds", DEFAULT_OFFSET_SECONDS))

    try:
        s3.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "")
        if error_code in ("404", "NoSuchKey", "NotFound"):
            raise SourceObjectNotFoundError(f"s3://{bucket}/{key} does not exist") from exc
        raise

    source_url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=PRESIGNED_URL_EXPIRY_SECONDS,
    )

    thumbnail_key = f"thumbnails/{job_id}/thumbnail.jpg"

    with tempfile.TemporaryDirectory() as tmp_dir:
        output_path = os.path.join(tmp_dir, "thumbnail.jpg")

        cmd = [
            FFMPEG_PATH,
            "-y",
            "-ss", offset_seconds,
            "-i", source_url,
            "-frames:v", "1",
            "-q:v", "2",
            output_path,
        ]

        logger.info("Running ffmpeg for job_id=%s (offset=%ss)", job_id, offset_seconds)
        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=FFMPEG_TIMEOUT_SECONDS,
                check=False,
            )
        except subprocess.TimeoutExpired as exc:
            raise ThumbnailGenerationError(
                f"ffmpeg timed out after {FFMPEG_TIMEOUT_SECONDS}s"
            ) from exc

        if result.returncode != 0 or not os.path.exists(output_path):
            logger.error("ffmpeg failed (rc=%s): %s", result.returncode, result.stderr[-2000:])
            raise ThumbnailGenerationError(
                f"ffmpeg exited {result.returncode}: {result.stderr[-500:]}"
            )

        s3.upload_file(
            output_path,
            output_bucket,
            thumbnail_key,
            ExtraArgs={"ContentType": "image/jpeg"},
        )

    logger.info("Uploaded thumbnail for job_id=%s to s3://%s/%s", job_id, output_bucket, thumbnail_key)

    return {
        "job_id": job_id,
        "thumbnail_bucket": output_bucket,
        "thumbnail_key": thumbnail_key,
        "status": "SUCCESS",
    }
