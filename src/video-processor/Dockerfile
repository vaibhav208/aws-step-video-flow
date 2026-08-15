# syntax=docker/dockerfile:1
#
# video-processor — FFmpeg transcoding worker run as an ECS Fargate task.
#
# Design notes:
#   - python:3.12-slim (Debian bookworm-slim) rather than an ffmpeg-focused
#     image: Debian's own `ffmpeg` package is back in main (post licensing
#     changes) and this keeps the image on a well-maintained, security-patched
#     base rather than an unofficial third-party ffmpeg image.
#   - tini as PID 1 for correct signal handling / zombie reaping: ECS sends
#     SIGTERM on task stop (including Step Functions Timeout cancellation in
#     Phase 3); without a real init process, a bare `python app/main.py` as
#     PID 1 can silently ignore SIGTERM, leaving the task to be hard-killed
#     after the stop timeout instead of exiting cleanly.
#   - Non-root user: the container never needs root once ffmpeg/python are
#     installed, so it doesn't run as root.
#   - No secrets baked in: JOB_ID/SOURCE_BUCKET/SOURCE_KEY/RESOLUTION/
#     OUTPUT_BUCKET are read from the environment at runtime (see app/main.py)
#     and are injected by Step Functions' RunTask container overrides in
#     Phase 3, or manually for standalone testing — never hardcoded here.
#   - Logs to stdout/stderr only (Python's logging is configured with a
#     StreamHandler-equivalent default), which the ECS awslogs driver
#     (configured in terraform/modules/ecs) ships straight to CloudWatch.

FROM python:3.12-slim AS base

RUN apt-get update \
    && apt-get install -y --no-install-recommends ffmpeg tini \
    && rm -rf /var/lib/apt/lists/*

RUN groupadd --system appuser && useradd --system --gid appuser --create-home appuser

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/

RUN chown -R appuser:appuser /app

USER appuser

# Runtime configuration — all overridden per-invocation, see app/main.py's
# docstring for the full list. Nothing here is a secret.
ENV FFMPEG_PATH=ffmpeg \
    FFMPEG_PRESET=medium \
    OUTPUT_PREFIX=processed \
    PYTHONUNBUFFERED=1

ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["python3", "app/main.py"]
