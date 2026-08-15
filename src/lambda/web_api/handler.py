"""
web_api — small Lambda serving two routes for the browser frontend
(frontend/index.html.tpl): POST /presign issues a pre-signed S3 PUT URL for
a new job's source video; GET /status/{job_id} returns a frontend-friendly
summary of that job's Step Functions execution, parsed from
DescribeExecution + GetExecutionHistory into per-node status so the
frontend doesn't need to understand ASL/Step Functions event shapes at all.

Deployed as ONE Lambda behind an API Gateway HTTP API (Phase 6, see
terraform/modules/web) rather than two separate functions like the rest of
this project's "one Lambda per concern" pattern (validate/database/
metadata/thumbnail) -- both routes are trivial, read-mostly, and exist
purely to serve this one frontend, so a single small router keeps the new
infrastructure footprint down without meaningfully hurting readability.
CORS preflight (OPTIONS) is handled entirely by the HTTP API's
cors_configuration block and never reaches this function.

Routes
------
POST /presign
    Request body (optional):
        {"resolutions": ["1080p", "720p"]}   # any subset of ALLOWED_RESOLUTIONS
    Unrecognized values are dropped; if nothing valid is left (including an
    empty/missing body), DEFAULT_RESOLUTIONS is used -- same defaulting
    behavior as an upload that skips the web frontend entirely. The chosen
    list is baked into the presigned PUT as `x-amz-meta-resolutions` object
    metadata, which src/lambda/trigger/handler.py reads back via HeadObject
    once the upload fires the pipeline (EventBridge's S3 event itself
    doesn't carry object metadata, so it can't be threaded through that
    path directly -- see that module's docstring).
    Response:
        {
            "job_id": "...", "key": "uploads/.../source.mp4",
            "upload_url": "...", "resolutions": ["1080p", "720p"],
            "upload_headers": {"Content-Type": "video/mp4", "x-amz-meta-resolutions": "1080p,720p"}
        }
    The caller MUST send exactly `upload_headers` on the PUT to `upload_url`
    -- they're part of what was cryptographically signed into the URL, so
    any mismatch (a missing header, a different Content-Type) fails the PUT
    with SignatureDoesNotMatch rather than silently ignoring the metadata.

GET /status/{job_id}
    Response:
        {
            "job_id": "...",
            "execution_status": "RUNNING" | "SUCCEEDED" | "FAILED" | "TIMED_OUT" | "ABORTED",
            "started_at": "...", "stopped_at": "...",   # stopped_at only once terminal
            "nodes": {"<node_id>": {"status": "pending"|"running"|"succeeded"|"failed", ...}},
            "output": {...},          # present when SUCCEEDED
            "error": "...", "cause": "...",  # present when FAILED/TIMED_OUT/ABORTED
        }
    or {"execution_status": "NOT_FOUND", "job_id": "..."} (404) if no
    execution has started yet for this job_id -- expected for a few seconds
    right after upload, while EventBridge + the trigger Lambda catch up.

GET /download/{job_id}
    Only meaningful once /status reports SUCCEEDED (this route re-checks
    that itself rather than trusting the caller). Reads `thumbnail_key` and
    `resolutions_processed` off the execution's own output (written by the
    ASL's BuildExecutionSummary state) and turns each into a short-lived
    presigned GET URL -- the media bucket has no public read access, so
    these are the only way a browser can actually fetch the thumbnail or
    a transcoded resolution.
    Response:
        {"job_id": "...", "thumbnail_url": "..." | null, "videos": {"1080p": "...", ...}}
    or 409 {"job_id": "...", "execution_status": "RUNNING", "error": "..."}
    if the execution hasn't succeeded yet, or 404 NOT_FOUND as above.

Simplification, deliberate: this collapses the ASL's ~20 states (see
step-functions/state-machine.asl.json.tpl) onto 9 "logical" nodes for the
frontend's flow diagram (_NODE_ORDER / _STATE_TO_NODE below). States not
in that map (IsVideoValid, HandleValidationFailure, HandleProcessingFailure,
RecordResolutionFailure, BuildExecutionSummary, StaggerLaunch) simply
aren't tracked individually -- the frontend doesn't need Choice/Pass/Wait
plumbing states to convey "what's happening right now", and any failure
along those paths still surfaces via the "done" node turning red plus the
top-level error/cause fields DescribeExecution already provides.
"""

from __future__ import annotations

import base64
import json
import logging
import os
import time
import uuid

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

s3 = boto3.client("s3")
sfn = boto3.client("stepfunctions")

MEDIA_BUCKET = os.environ["MEDIA_BUCKET"]
STATE_MACHINE_ARN = os.environ["STATE_MACHINE_ARN"]
PRESIGNED_URL_EXPIRY_SECONDS = int(os.environ.get("PRESIGNED_URL_EXPIRY_SECONDS", "300"))
DOWNLOAD_URL_EXPIRY_SECONDS = int(os.environ.get("DOWNLOAD_URL_EXPIRY_SECONDS", "3600"))

# Mirrors src/video-processor/app/main.py's RESOLUTION_PRESETS keys and
# src/lambda/trigger/handler.py's ALLOWED_RESOLUTIONS -- kept as a separate
# literal in each function (rather than a shared import) because every
# Lambda in this project is packaged and deployed completely independently.
ALLOWED_RESOLUTIONS = {"1440p", "1080p", "720p", "480p", "360p", "240p"}
DEFAULT_RESOLUTIONS = ["1080p", "720p", "480p"]

# Matches the video-processor app's own OUTPUT_PREFIX default ("processed",
# see src/video-processor/app/main.py) -- not read from an env var here
# because nothing in this project's Terraform ever overrides that default
# on the ECS side either, so hardcoding the two in lockstep is simpler than
# threading one more variable through two unrelated modules for a value
# that has never actually varied.
OUTPUT_PREFIX = "processed"

_CORS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Headers": "*",
    "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
}

_NODE_ORDER = [
    "create_job",
    "validate",
    "extract_metadata",
    "generate_thumbnail",
    "record_media",
    "transcode",
    "record_complete",
    "notify",
    "done",
]

_STATE_TO_NODE = {
    "CreateJobRecord": "create_job",
    "ValidateVideo": "validate",
    "ExtractMetadata": "extract_metadata",
    "GenerateThumbnail": "generate_thumbnail",
    "RecordMediaDetails": "record_media",
    "RunTranscodeTask": "transcode",
    "RecordJobComplete": "record_complete",
    "NotifySuccess": "notify",
    "NotifyValidationFailure": "notify",
    "NotifyProcessingFailure": "notify",
    "JobSucceeded": "done",
    "ValidationFailedState": "done",
    "ResolutionFailed": "done",
    "ProcessingFailedState": "done",
}

# ASL Fail states -- *entering* one of these means the pipeline is failing
# right there, not "still running normally".
_FAIL_STATE_NAMES = {"ValidationFailedState", "ResolutionFailed", "ProcessingFailedState"}

# ASL Succeed state -- like a Fail state, entering it is itself terminal
# (Succeed states never "exit" the way a Task does), so it needs the same
# immediate-terminal-status handling rather than the generic
# entered -> "running" / exited -> "succeeded" flow every other node uses.
_SUCCEED_STATE_NAMES = {"JobSucceeded"}

# TranscodeAllResolutions is a Map state, so "RunTranscodeTask" is entered
# and exited once per resolution (default 3) rather than once overall --
# tracked separately below instead of through the generic entered/exited
# bookkeeping every other node uses.
_MAP_ITERATION_STATE = "RunTranscodeTask"
_DEFAULT_RESOLUTION_COUNT = 3


class MissingJobIdError(Exception):
    pass


def _response(status_code: int, body: dict) -> dict:
    return {
        "statusCode": status_code,
        "headers": {**_CORS_HEADERS, "Content-Type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _dedupe_preserve_order(values: list[str]) -> list[str]:
    seen: set[str] = set()
    result: list[str] = []
    for v in values:
        if v not in seen:
            seen.add(v)
            result.append(v)
    return result


def _resolutions_from_request_body(event: dict) -> list[str]:
    raw_body = event.get("body") or "{}"
    if event.get("isBase64Encoded"):
        try:
            raw_body = base64.b64decode(raw_body).decode("utf-8")
        except (ValueError, UnicodeDecodeError):
            raw_body = "{}"

    try:
        parsed = json.loads(raw_body)
    except json.JSONDecodeError:
        parsed = {}

    requested = parsed.get("resolutions") if isinstance(parsed, dict) else None
    if not isinstance(requested, list):
        requested = []

    valid = _dedupe_preserve_order(
        [r for r in requested if isinstance(r, str) and r in ALLOWED_RESOLUTIONS]
    )
    return valid or list(DEFAULT_RESOLUTIONS)


def _handle_presign(event: dict) -> dict:
    job_id = f"job-web-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    key = f"uploads/{job_id}/source.mp4"
    resolutions = _resolutions_from_request_body(event)
    resolutions_header = ",".join(resolutions)

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={
            "Bucket": MEDIA_BUCKET,
            "Key": key,
            "ContentType": "video/mp4",
            "Metadata": {"resolutions": resolutions_header},
        },
        ExpiresIn=PRESIGNED_URL_EXPIRY_SECONDS,
    )

    logger.info(
        "Issued presigned upload URL for job_id=%s key=%s resolutions=%s",
        job_id, key, resolutions,
    )
    return _response(200, {
        "job_id": job_id,
        "upload_url": upload_url,
        "key": key,
        "resolutions": resolutions,
        "upload_headers": {
            "Content-Type": "video/mp4",
            "x-amz-meta-resolutions": resolutions_header,
        },
    })


def _execution_arn_for(job_id: str) -> str:
    # Step Functions execution ARNs are deterministic from the state
    # machine ARN: swap ":stateMachine:" for ":execution:" and append the
    # execution name. This is safe here because every path that starts an
    # execution in this project (the trigger Lambda, and the manual
    # start-execution examples in step-functions/README.md) always uses
    # job_id as the execution name -- see trigger/handler.py's
    # "Idempotency" docstring section.
    return STATE_MACHINE_ARN.replace(":stateMachine:", ":execution:") + f":{job_id}"


def _get_all_history_events(execution_arn: str) -> list[dict]:
    events: list[dict] = []
    kwargs = {"executionArn": execution_arn, "maxResults": 1000}
    while True:
        resp = sfn.get_execution_history(**kwargs)
        events.extend(resp["events"])
        next_token = resp.get("nextToken")
        if not next_token:
            return events
        kwargs["nextToken"] = next_token


def _build_node_statuses(history_events: list[dict], total_resolutions: int) -> dict:
    nodes = {node_id: {"status": "pending"} for node_id in _NODE_ORDER}
    map_entered = 0
    map_exited = 0

    for event in history_events:
        entered = event.get("stateEnteredEventDetails")
        exited = event.get("stateExitedEventDetails")

        if entered:
            name = entered["name"]
            if name == _MAP_ITERATION_STATE:
                map_entered += 1
                if nodes["transcode"]["status"] == "pending":
                    nodes["transcode"]["status"] = "running"
                continue

            node_id = _STATE_TO_NODE.get(name)
            if node_id is None:
                continue
            if name in _FAIL_STATE_NAMES:
                nodes[node_id]["status"] = "failed"
            elif name in _SUCCEED_STATE_NAMES:
                nodes[node_id]["status"] = "succeeded"
            elif nodes[node_id]["status"] == "pending":
                nodes[node_id]["status"] = "running"

        if exited:
            name = exited["name"]
            if name == _MAP_ITERATION_STATE:
                map_exited += 1
                continue

            node_id = _STATE_TO_NODE.get(name)
            if node_id is None:
                continue
            nodes[node_id]["status"] = "succeeded"

    if map_entered:
        total = total_resolutions or _DEFAULT_RESOLUTION_COUNT
        nodes["transcode"]["status"] = "succeeded" if map_exited >= total else "running"
        nodes["transcode"]["progress"] = f"{map_exited}/{total}"

    return nodes


def _handle_status(job_id: str) -> dict:
    execution_arn = _execution_arn_for(job_id)

    try:
        desc = sfn.describe_execution(executionArn=execution_arn)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ExecutionDoesNotExist":
            return _response(404, {"execution_status": "NOT_FOUND", "job_id": job_id})
        raise

    try:
        exec_input = json.loads(desc.get("input") or "{}")
    except json.JSONDecodeError:
        exec_input = {}
    total_resolutions = len(exec_input.get("resolutions", [])) or _DEFAULT_RESOLUTION_COUNT

    history_events = _get_all_history_events(execution_arn)
    nodes = _build_node_statuses(history_events, total_resolutions)

    result = {
        "job_id": job_id,
        "execution_status": desc["status"],
        "started_at": desc["startDate"].isoformat(),
        "nodes": nodes,
    }

    if "stopDate" in desc:
        result["stopped_at"] = desc["stopDate"].isoformat()

    if desc["status"] == "SUCCEEDED" and desc.get("output"):
        try:
            result["output"] = json.loads(desc["output"])
        except json.JSONDecodeError:
            pass

    if desc["status"] in ("FAILED", "TIMED_OUT", "ABORTED"):
        result["error"] = desc.get("error", "")
        result["cause"] = desc.get("cause", "")

    return _response(200, result)


def _handle_download(job_id: str) -> dict:
    execution_arn = _execution_arn_for(job_id)

    try:
        desc = sfn.describe_execution(executionArn=execution_arn)
    except ClientError as exc:
        if exc.response.get("Error", {}).get("Code") == "ExecutionDoesNotExist":
            return _response(404, {"execution_status": "NOT_FOUND", "job_id": job_id})
        raise

    status = desc["status"]
    if status != "SUCCEEDED":
        # 409 Conflict: the request is well-formed, but downloads don't
        # exist yet (still RUNNING) or never will (FAILED/TIMED_OUT/ABORTED)
        # -- distinct from 404, which means "no such job at all".
        return _response(409, {
            "job_id": job_id,
            "execution_status": status,
            "error": "Downloads are only available once the execution has SUCCEEDED.",
        })

    try:
        output = json.loads(desc.get("output") or "{}")
    except json.JSONDecodeError:
        output = {}

    thumbnail_key = output.get("thumbnail_key")
    resolutions_processed = output.get("resolutions_processed") or []

    thumbnail_url = None
    if thumbnail_key:
        thumbnail_url = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": MEDIA_BUCKET, "Key": thumbnail_key},
            ExpiresIn=DOWNLOAD_URL_EXPIRY_SECONDS,
        )

    videos = {}
    for resolution in resolutions_processed:
        # Deterministic from src/video-processor/app/main.py's own
        # output_key construction -- this function never lists the bucket,
        # it just reconstructs the same key the ECS task already wrote to.
        key = f"{OUTPUT_PREFIX}/{job_id}/{resolution}/video.mp4"
        videos[resolution] = s3.generate_presigned_url(
            "get_object",
            Params={"Bucket": MEDIA_BUCKET, "Key": key},
            ExpiresIn=DOWNLOAD_URL_EXPIRY_SECONDS,
        )

    logger.info("Issued %d download URL(s) for job_id=%s", len(videos) + (1 if thumbnail_url else 0), job_id)
    return _response(200, {"job_id": job_id, "thumbnail_url": thumbnail_url, "videos": videos})


def lambda_handler(event, context):  # noqa: ARG001 - context required by Lambda
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "")
    path = event.get("rawPath", "")

    if method == "POST" and path == "/presign":
        return _handle_presign(event)

    if method == "GET" and path.startswith("/status/"):
        job_id = (event.get("pathParameters") or {}).get("job_id", "")
        if not job_id:
            return _response(400, {"error": "missing job_id"})
        return _handle_status(job_id)

    if method == "GET" and path.startswith("/download/"):
        job_id = (event.get("pathParameters") or {}).get("job_id", "")
        if not job_id:
            return _response(400, {"error": "missing job_id"})
        return _handle_download(job_id)

    logger.warning("No route for %s %s", method, path)
    return _response(404, {"error": f"no route for {method} {path}"})
