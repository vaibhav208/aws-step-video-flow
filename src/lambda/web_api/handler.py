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
    Request body: ignored (job_id is generated server-side, avoiding any
    client-supplied job_id that would need sanitizing against the
    uploads/<job_id>/... key shape src/lambda/trigger/handler.py expects).
    Response: {"job_id": "...", "upload_url": "...", "key": "uploads/.../source.mp4"}

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


def _handle_presign() -> dict:
    job_id = f"job-web-{int(time.time())}-{uuid.uuid4().hex[:6]}"
    key = f"uploads/{job_id}/source.mp4"

    upload_url = s3.generate_presigned_url(
        "put_object",
        Params={"Bucket": MEDIA_BUCKET, "Key": key, "ContentType": "video/mp4"},
        ExpiresIn=PRESIGNED_URL_EXPIRY_SECONDS,
    )

    logger.info("Issued presigned upload URL for job_id=%s key=%s", job_id, key)
    return _response(200, {"job_id": job_id, "upload_url": upload_url, "key": key})


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


def lambda_handler(event, context):  # noqa: ARG001 - context required by Lambda
    http = event.get("requestContext", {}).get("http", {})
    method = http.get("method", "")
    path = event.get("rawPath", "")

    if method == "POST" and path == "/presign":
        return _handle_presign()

    if method == "GET" and path.startswith("/status/"):
        job_id = (event.get("pathParameters") or {}).get("job_id", "")
        if not job_id:
            return _response(400, {"error": "missing job_id"})
        return _handle_status(job_id)

    logger.warning("No route for %s %s", method, path)
    return _response(404, {"error": f"no route for {method} {path}"})
