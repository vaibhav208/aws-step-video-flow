"""
metadata — extracts real video metadata (duration, resolution, codecs,
bitrate) using ffprobe.

Deployed as a Lambda CONTAINER IMAGE, not a zip + layer. ffmpeg/ffprobe
static binaries run ~140MB apiece (see src/lambda/ffmpeg/Dockerfile) —
comfortably past the 250MB *unzipped* limit that applies to a zip-packaged
function plus every layer attached to it, but nowhere near the 10GB limit
for container images. This function and thumbnail_handler.py are built
into ONE shared image (see the Dockerfile in this directory); the
`terraform/modules/lambda` module points two separate Lambda functions at
that same image and overrides which handler each one runs via
`image_config.command`, so the (large, slow-to-rebuild) ffmpeg layer only
has to be built and pushed once for both functions.

Design choice: this function does NOT download the source video into /tmp.
ffprobe only needs to read the container's header/index structures (a few
KB-MB at most, wherever they sit in the file), not the whole video, and S3
presigned URLs support HTTP Range requests — so ffprobe is pointed directly
at a short-lived presigned GET URL and reads only the bytes it needs over
the network. For a multi-GB source video this is the difference between a
sub-second Lambda invocation and one that has to pull the entire file into
/tmp first. This is also why this function stays classified as
"lightweight" per the architecture's Lambda-vs-ECS split even though it's
technically an FFmpeg-family tool doing the work.

Step Functions Task contract
-----------------------------
Input:
    {"job_id": "abc123", "bucket": "...", "key": "uploads/abc123/source.mp4"}

Output:
    {
        "job_id": "abc123",
        "duration_seconds": 42.7,
        "width": 1920,
        "height": 1080,
        "video_codec": "h264",
        "audio_codec": "aac",
        "bitrate": 5_000_000,
        "container_format": "mov,mp4,m4a,3gp,3g2,mj2"
    }
"""

from __future__ import annotations

import json
import logging
import os
import subprocess

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")

FFPROBE_PATH = os.environ.get("FFPROBE_PATH", "/usr/local/bin/ffprobe")
PRESIGNED_URL_EXPIRY_SECONDS = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", "300"))
FFPROBE_TIMEOUT_SECONDS = int(os.environ.get("FFPROBE_TIMEOUT_SECONDS", "20"))


class SourceObjectNotFoundError(Exception):
    pass


class MetadataExtractionError(Exception):
    """ffprobe ran but couldn't make sense of the file (corrupt/unsupported)."""


def lambda_handler(event, context):  # noqa: ARG001
    job_id = event["job_id"]
    bucket = event["bucket"]
    key = event["key"]

    try:
        s3.head_object(Bucket=bucket, Key=key)
    except ClientError as exc:
        error_code = exc.response.get("Error", {}).get("Code", "")
        if error_code in ("404", "NoSuchKey", "NotFound"):
            raise SourceObjectNotFoundError(f"s3://{bucket}/{key} does not exist") from exc
        raise

    url = s3.generate_presigned_url(
        "get_object",
        Params={"Bucket": bucket, "Key": key},
        ExpiresIn=PRESIGNED_URL_EXPIRY_SECONDS,
    )

    cmd = [
        FFPROBE_PATH,
        "-v", "error",
        "-print_format", "json",
        "-show_format",
        "-show_streams",
        url,
    ]

    logger.info("Running ffprobe for job_id=%s (key=%s)", job_id, key)
    try:
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=FFPROBE_TIMEOUT_SECONDS,
            check=False,
        )
    except subprocess.TimeoutExpired as exc:
        raise MetadataExtractionError(f"ffprobe timed out after {FFPROBE_TIMEOUT_SECONDS}s") from exc

    if result.returncode != 0:
        logger.error("ffprobe failed (rc=%s): %s", result.returncode, result.stderr[:2000])
        raise MetadataExtractionError(f"ffprobe exited {result.returncode}: {result.stderr[:500]}")

    try:
        probe = json.loads(result.stdout)
    except json.JSONDecodeError as exc:
        raise MetadataExtractionError("ffprobe produced non-JSON output") from exc

    fmt = probe.get("format", {})
    streams = probe.get("streams", [])
    video_stream = next((s for s in streams if s.get("codec_type") == "video"), {})
    audio_stream = next((s for s in streams if s.get("codec_type") == "audio"), {})

    metadata = {
        "job_id": job_id,
        "duration_seconds": float(fmt.get("duration", 0.0)),
        "width": video_stream.get("width"),
        "height": video_stream.get("height"),
        "video_codec": video_stream.get("codec_name"),
        "audio_codec": audio_stream.get("codec_name"),
        "bitrate": int(fmt.get("bit_rate", 0)) if fmt.get("bit_rate") else None,
        "container_format": fmt.get("format_name"),
    }

    logger.info("Extracted metadata for job_id=%s: %s", job_id, metadata)
    return metadata
