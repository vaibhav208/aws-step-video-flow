"""
video-processor — the ECS Fargate task that does the actual CPU-heavy work:
download the source video from S3, transcode it to a requested resolution
with FFmpeg, upload the result, and report back what happened.

This is intentionally NOT a web service — it's a batch job. It reads its
parameters from environment variables (set per-invocation by Step
Functions' ecs:runTask.sync `overrides.containerOverrides[].environment` in
Phase 3), does one unit of work, writes a small JSON result to stdout (so
it shows up in the task's CloudWatch Logs regardless of how it's invoked),
and exits 0 on success / non-zero on failure. Exit code is what Step
Functions' RunTask.sync integration watches to decide whether the Task
state succeeded, failed (triggering Retry/Catch), or the task run itself
errored — which is also why every failure path here calls sys.exit(1)
rather than letting an unhandled exception produce a Python traceback exit
code that's harder to reason about.

Required environment variables
-------------------------------
JOB_ID           e.g. "abc123"
SOURCE_BUCKET    e.g. "aws-step-video-flow-dev-media-111111111111"
SOURCE_KEY       e.g. "uploads/abc123/source.mp4"
RESOLUTION       one of the keys in RESOLUTION_PRESETS below, e.g. "720p"
OUTPUT_BUCKET    defaults to SOURCE_BUCKET if unset

Optional
--------
OUTPUT_PREFIX    defaults to "processed"
FFMPEG_PATH      defaults to "ffmpeg" (on PATH inside the container image)
FFMPEG_PRESET    defaults to "medium" (x264 preset — speed/quality tradeoff)

Output contract (also what this prints to stdout as its last line, so it's
visible in CloudWatch Logs even when nothing downstream parses it):
    {
        "job_id": "abc123",
        "resolution": "720p",
        "status": "SUCCESS",
        "output_key": "processed/abc123/720p/video.mp4",
        "duration_seconds": 42
    }
"""

from __future__ import annotations

import json
import logging
import os
import subprocess
import sys
import tempfile
import time

import boto3
from botocore.exceptions import ClientError

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("video-processor")

# Resolution presets: target height + a matched video bitrate. Adding a new
# resolution to the pipeline (the spec explicitly calls out 360p/240p/1440p
# as things you should be able to add "without redesigning the state
# machine") is a two-step change: add a row here, and add the string to the
# `resolutions` list in the Step Functions Map state's input (Phase 3) — no
# code path branches on which resolution it is beyond this lookup table.
RESOLUTION_PRESETS = {
    "1440p": {"height": 1440, "video_bitrate": "10M"},
    "1080p": {"height": 1080, "video_bitrate": "6M"},
    "720p":  {"height": 720,  "video_bitrate": "3M"},
    "480p":  {"height": 480,  "video_bitrate": "1.5M"},
    "360p":  {"height": 360,  "video_bitrate": "800k"},
    "240p":  {"height": 240,  "video_bitrate": "400k"},
}


class ConfigError(Exception):
    pass


class ProcessingError(Exception):
    pass


def _require_env(name: str) -> str:
    value = os.environ.get(name)
    if not value:
        raise ConfigError(f"Required environment variable {name} is not set")
    return value


def _emit_result(result: dict) -> None:
    # This exact line is what a human (or a log-driven alarm/metric filter,
    # per docs/troubleshooting.md in a later phase) greps CloudWatch Logs
    # for: RESULT: {...}
    print(f"RESULT: {json.dumps(result)}", flush=True)


def main() -> int:
    start_time = time.monotonic()

    try:
        job_id = _require_env("JOB_ID")
        source_bucket = _require_env("SOURCE_BUCKET")
        source_key = _require_env("SOURCE_KEY")
        resolution = _require_env("RESOLUTION")
        output_bucket = os.environ.get("OUTPUT_BUCKET", source_bucket)
        output_prefix = os.environ.get("OUTPUT_PREFIX", "processed")
        ffmpeg_path = os.environ.get("FFMPEG_PATH", "ffmpeg")
        ffmpeg_preset = os.environ.get("FFMPEG_PRESET", "medium")

        if resolution not in RESOLUTION_PRESETS:
            raise ConfigError(
                f"Unsupported resolution '{resolution}'. "
                f"Supported: {sorted(RESOLUTION_PRESETS)}"
            )
    except ConfigError as exc:
        logger.error("Configuration error: %s", exc)
        _emit_result({"status": "FAILED", "error": str(exc)})
        return 1

    preset = RESOLUTION_PRESETS[resolution]
    output_key = f"{output_prefix}/{job_id}/{resolution}/video.mp4"

    logger.info(
        "Starting job_id=%s resolution=%s source=s3://%s/%s output=s3://%s/%s",
        job_id, resolution, source_bucket, source_key, output_bucket, output_key,
    )

    s3 = boto3.client("s3")

    with tempfile.TemporaryDirectory() as tmp_dir:
        input_path = os.path.join(tmp_dir, "input")
        output_path = os.path.join(tmp_dir, "output.mp4")

        try:
            logger.info("Downloading s3://%s/%s", source_bucket, source_key)
            s3.download_file(source_bucket, source_key, input_path)
        except ClientError as exc:
            logger.error("Download failed: %s", exc)
            _emit_result({"job_id": job_id, "resolution": resolution, "status": "FAILED", "error": f"download failed: {exc}"})
            return 1

        cmd = [
            ffmpeg_path,
            "-y",
            "-i", input_path,
            "-vf", f"scale=-2:{preset['height']}",
            "-b:v", preset["video_bitrate"],
            "-c:v", "libx264",
            "-preset", ffmpeg_preset,
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            output_path,
        ]

        logger.info("Running: %s", " ".join(cmd))
        proc = subprocess.run(cmd, capture_output=True, text=True)

        if proc.returncode != 0 or not os.path.exists(output_path):
            logger.error("ffmpeg failed (rc=%s)\n%s", proc.returncode, proc.stderr[-4000:])
            _emit_result({
                "job_id": job_id,
                "resolution": resolution,
                "status": "FAILED",
                "error": f"ffmpeg exited {proc.returncode}: {proc.stderr[-1000:]}",
            })
            return 1

        try:
            logger.info("Uploading result to s3://%s/%s", output_bucket, output_key)
            s3.upload_file(
                output_path,
                output_bucket,
                output_key,
                ExtraArgs={"ContentType": "video/mp4"},
            )
        except ClientError as exc:
            logger.error("Upload failed: %s", exc)
            _emit_result({"job_id": job_id, "resolution": resolution, "status": "FAILED", "error": f"upload failed: {exc}"})
            return 1

    duration_seconds = round(time.monotonic() - start_time, 1)
    result = {
        "job_id": job_id,
        "resolution": resolution,
        "status": "SUCCESS",
        "output_key": output_key,
        "duration_seconds": duration_seconds,
    }
    logger.info("Completed job_id=%s resolution=%s in %ss", job_id, resolution, duration_seconds)
    _emit_result(result)
    return 0


if __name__ == "__main__":
    sys.exit(main())
