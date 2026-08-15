"""
Unit tests for src/lambda/web_api/handler.py (Phase 6): the /presign and
/status/{job_id} routes behind the frontend's API Gateway HTTP API.

_build_node_statuses() -- the part translating raw Step Functions history
events into the frontend's simplified 9-node view -- is tested directly
with synthetic event lists (real GetExecutionHistory shape) covering the
success path, a validation-failure path, and an in-progress Map (transcode)
state, since constructing a full ~20-state ASL machine in moto for every
scenario would be a lot of setup for what's fundamentally pure parsing
logic. _handle_status is additionally tested end-to-end against a real
(minimal) moto state machine to confirm the DescribeExecution/
GetExecutionHistory wiring itself is correct.
"""

import json

import boto3
import pytest
from moto import mock_aws

REGION = "us-east-1"
TEST_STATE_MACHINE_ARN = "arn:aws:states:us-east-1:123456789012:stateMachine:test-pipeline"


def _entered(name):
    return {"stateEnteredEventDetails": {"name": name}}


def _exited(name):
    return {"stateExitedEventDetails": {"name": name}}


# --- _execution_arn_for -----------------------------------------------------


def test_execution_arn_for(web_api_handler):
    assert (
        web_api_handler._execution_arn_for("job-abc")
        == "arn:aws:states:us-east-1:123456789012:execution:test-pipeline:job-abc"
    )


# --- _build_node_statuses ----------------------------------------------------


def test_build_node_statuses_happy_path(web_api_handler):
    events = [
        _entered("CreateJobRecord"),
        _exited("CreateJobRecord"),
        _entered("ValidateVideo"),
        _exited("ValidateVideo"),
        _entered("GenerateThumbnail"),
        _entered("ExtractMetadata"),
        _exited("GenerateThumbnail"),
        _exited("ExtractMetadata"),
        _entered("RecordMediaDetails"),
        _exited("RecordMediaDetails"),
        _entered("RunTranscodeTask"),
        _entered("RunTranscodeTask"),
        _entered("RunTranscodeTask"),
        _exited("RunTranscodeTask"),
        _exited("RunTranscodeTask"),
        _exited("RunTranscodeTask"),
        _entered("RecordJobComplete"),
        _exited("RecordJobComplete"),
        _entered("NotifySuccess"),
        _exited("NotifySuccess"),
        _entered("JobSucceeded"),
    ]

    nodes = web_api_handler._build_node_statuses(events, total_resolutions=3)

    assert nodes["create_job"]["status"] == "succeeded"
    assert nodes["validate"]["status"] == "succeeded"
    assert nodes["generate_thumbnail"]["status"] == "succeeded"
    assert nodes["extract_metadata"]["status"] == "succeeded"
    assert nodes["record_media"]["status"] == "succeeded"
    assert nodes["transcode"]["status"] == "succeeded"
    assert nodes["transcode"]["progress"] == "3/3"
    assert nodes["record_complete"]["status"] == "succeeded"
    assert nodes["notify"]["status"] == "succeeded"
    assert nodes["done"]["status"] == "succeeded"  # entering a Succeed state IS the success


def test_build_node_statuses_in_progress_transcode(web_api_handler):
    events = [
        _entered("CreateJobRecord"),
        _exited("CreateJobRecord"),
        _entered("ValidateVideo"),
        _exited("ValidateVideo"),
        _entered("GenerateThumbnail"),
        _entered("ExtractMetadata"),
        _exited("GenerateThumbnail"),
        _exited("ExtractMetadata"),
        _entered("RecordMediaDetails"),
        _exited("RecordMediaDetails"),
        _entered("RunTranscodeTask"),
        _entered("RunTranscodeTask"),
        _entered("RunTranscodeTask"),
        _exited("RunTranscodeTask"),  # only 1 of 3 resolutions done so far
    ]

    nodes = web_api_handler._build_node_statuses(events, total_resolutions=3)

    assert nodes["transcode"]["status"] == "running"
    assert nodes["transcode"]["progress"] == "1/3"
    assert nodes["record_complete"]["status"] == "pending"


def test_build_node_statuses_validation_failure(web_api_handler):
    events = [
        _entered("CreateJobRecord"),
        _exited("CreateJobRecord"),
        _entered("ValidateVideo"),
        _exited("ValidateVideo"),
        _entered("HandleValidationFailure"),  # not in _STATE_TO_NODE -- ignored
        _exited("HandleValidationFailure"),
        _entered("NotifyValidationFailure"),
        _exited("NotifyValidationFailure"),
        _entered("ValidationFailedState"),
    ]

    nodes = web_api_handler._build_node_statuses(events, total_resolutions=3)

    assert nodes["validate"]["status"] == "succeeded"  # ValidateVideo itself ran fine
    assert nodes["notify"]["status"] == "succeeded"
    assert nodes["done"]["status"] == "failed"
    assert nodes["extract_metadata"]["status"] == "pending"
    assert nodes["transcode"]["status"] == "pending"


# --- _handle_presign ----------------------------------------------------------


def test_handle_presign_returns_valid_shape(web_api_handler):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        response = web_api_handler._handle_presign({})

    assert response["statusCode"] == 200
    body = json.loads(response["body"])

    assert body["job_id"].startswith("job-web-")
    assert body["key"] == f"uploads/{body['job_id']}/source.mp4"
    assert "test-media-bucket" in body["upload_url"]
    assert body["key"] in body["upload_url"]
    # No body was sent -- falls back to the same default resolutions the
    # trigger Lambda uses for any non-web upload.
    assert body["resolutions"] == web_api_handler.DEFAULT_RESOLUTIONS
    assert body["upload_headers"]["x-amz-meta-resolutions"] == ",".join(web_api_handler.DEFAULT_RESOLUTIONS)


def test_handle_presign_accepts_custom_resolutions(web_api_handler):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        event = {"body": json.dumps({"resolutions": ["720p", "480p", "720p"]})}
        response = web_api_handler._handle_presign(event)

    body = json.loads(response["body"])
    # De-duped, order preserved -- the duplicate "720p" collapses to one.
    assert body["resolutions"] == ["720p", "480p"]
    assert body["upload_headers"]["x-amz-meta-resolutions"] == "720p,480p"


def test_handle_presign_drops_unrecognized_resolutions_and_falls_back_if_none_valid(web_api_handler):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        event = {"body": json.dumps({"resolutions": ["8k", "not-a-resolution"]})}
        response = web_api_handler._handle_presign(event)

    body = json.loads(response["body"])
    assert body["resolutions"] == web_api_handler.DEFAULT_RESOLUTIONS


def test_handle_presign_mixed_valid_and_invalid_keeps_only_valid(web_api_handler):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        event = {"body": json.dumps({"resolutions": ["1440p", "8k", "240p"]})}
        response = web_api_handler._handle_presign(event)

    body = json.loads(response["body"])
    assert body["resolutions"] == ["1440p", "240p"]


def test_handle_presign_malformed_json_body_falls_back_to_default(web_api_handler):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        response = web_api_handler._handle_presign({"body": "not json"})

    body = json.loads(response["body"])
    assert body["resolutions"] == web_api_handler.DEFAULT_RESOLUTIONS


# --- _handle_download ----------------------------------------------------------


def test_handle_download_returns_presigned_urls_when_succeeded(web_api_handler, monkeypatch):
    fake_output = json.dumps({
        "job_id": "job-dl-1",
        "status": "SUCCESS",
        "resolutions_processed": ["1080p", "720p"],
        "thumbnail_key": "thumbnails/job-dl-1/thumbnail.jpg",
        "duration_seconds": 12.3,
    })

    def _fake_describe_execution(executionArn):  # noqa: N803 - matches boto3's kwarg name
        return {"status": "SUCCEEDED", "output": fake_output}

    monkeypatch.setattr(web_api_handler.sfn, "describe_execution", _fake_describe_execution)

    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        response = web_api_handler._handle_download("job-dl-1")

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["job_id"] == "job-dl-1"
    assert "test-media-bucket" in body["thumbnail_url"]
    assert "thumbnails/job-dl-1/thumbnail.jpg" in body["thumbnail_url"]
    assert set(body["videos"].keys()) == {"1080p", "720p"}
    assert "processed/job-dl-1/1080p/video.mp4" in body["videos"]["1080p"]
    assert "processed/job-dl-1/720p/video.mp4" in body["videos"]["720p"]


def test_handle_download_missing_thumbnail_key_returns_null_url(web_api_handler, monkeypatch):
    fake_output = json.dumps({"resolutions_processed": ["480p"]})

    def _fake_describe_execution(executionArn):  # noqa: N803
        return {"status": "SUCCEEDED", "output": fake_output}

    monkeypatch.setattr(web_api_handler.sfn, "describe_execution", _fake_describe_execution)

    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        response = web_api_handler._handle_download("job-no-thumb")

    body = json.loads(response["body"])
    assert body["thumbnail_url"] is None
    assert set(body["videos"].keys()) == {"480p"}


def test_handle_download_not_ready_when_still_running(web_api_handler, monkeypatch):
    def _fake_describe_execution(executionArn):  # noqa: N803
        return {"status": "RUNNING"}

    monkeypatch.setattr(web_api_handler.sfn, "describe_execution", _fake_describe_execution)

    response = web_api_handler._handle_download("job-still-running")

    assert response["statusCode"] == 409
    body = json.loads(response["body"])
    assert body["execution_status"] == "RUNNING"


def test_handle_download_not_found(web_api_handler, two_state_machine):
    response = web_api_handler._handle_download("job-does-not-exist")

    assert response["statusCode"] == 404
    body = json.loads(response["body"])
    assert body["execution_status"] == "NOT_FOUND"


# --- _handle_status end-to-end against a real (minimal) moto state machine --


@pytest.fixture
def two_state_machine():
    with mock_aws():
        iam = boto3.client("iam", region_name=REGION)
        role = iam.create_role(
            RoleName="fake-sfn-role",
            AssumeRolePolicyDocument=json.dumps(
                {
                    "Version": "2012-10-17",
                    "Statement": [
                        {
                            "Effect": "Allow",
                            "Principal": {"Service": "states.amazonaws.com"},
                            "Action": "sts:AssumeRole",
                        }
                    ],
                }
            ),
        )["Role"]["Arn"]

        sfn = boto3.client("stepfunctions", region_name=REGION)
        definition = json.dumps(
            {
                "StartAt": "CreateJobRecord",
                "States": {
                    "CreateJobRecord": {"Type": "Pass", "Next": "JobSucceeded"},
                    "JobSucceeded": {"Type": "Succeed"},
                },
            }
        )
        created = sfn.create_state_machine(name="test-pipeline", definition=definition, roleArn=role)
        assert created["stateMachineArn"] == TEST_STATE_MACHINE_ARN

        yield sfn


def test_handle_status_wiring_against_real_describe_and_history_apis(web_api_handler, two_state_machine):
    # This deliberately does NOT assert on individual node statuses --
    # moto's Step Functions execution engine doesn't actually interpret the
    # ASL definition; get_execution_history comes back with a hardcoded
    # generic state name ("A State") no matter what states this fixture
    # defines, and describe_execution's top-level `status` field doesn't
    # reliably leave "RUNNING" either. Real per-node mapping logic is
    # already covered thoroughly and correctly by the
    # test_build_node_statuses_* tests above using realistic event shapes
    # straight from AWS's own API documentation. What THIS test actually
    # verifies is the wiring: _handle_status calls describe_execution +
    # get_execution_history with the right execution ARN, doesn't blow up
    # on real (if generically-named) API responses, and shapes a
    # 200 response with the fields the frontend depends on.
    two_state_machine.start_execution(
        stateMachineArn=TEST_STATE_MACHINE_ARN,
        name="job-e2e-1",
        input=json.dumps({"job_id": "job-e2e-1", "resolutions": ["1080p", "720p", "480p"]}),
    )

    response = web_api_handler._handle_status("job-e2e-1")

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["job_id"] == "job-e2e-1"
    assert body["execution_status"] in ("RUNNING", "SUCCEEDED")
    assert "started_at" in body
    assert set(body["nodes"].keys()) == set(web_api_handler._NODE_ORDER)


def test_handle_status_not_found(web_api_handler, two_state_machine):
    response = web_api_handler._handle_status("job-does-not-exist")

    assert response["statusCode"] == 404
    body = json.loads(response["body"])
    assert body["execution_status"] == "NOT_FOUND"


# --- lambda_handler routing ---------------------------------------------------


def _api_gw_event(method, path, path_params=None):
    return {
        "requestContext": {"http": {"method": method}},
        "rawPath": path,
        "pathParameters": path_params or {},
    }


def test_lambda_handler_routes_presign(web_api_handler):
    with mock_aws():
        s3 = boto3.client("s3", region_name=REGION)
        s3.create_bucket(Bucket="test-media-bucket")

        response = web_api_handler.lambda_handler(_api_gw_event("POST", "/presign"), None)

    assert response["statusCode"] == 200


def test_lambda_handler_routes_status(web_api_handler, two_state_machine):
    two_state_machine.start_execution(
        stateMachineArn=TEST_STATE_MACHINE_ARN, name="job-route-1", input="{}"
    )

    event = _api_gw_event("GET", "/status/job-route-1", {"job_id": "job-route-1"})
    response = web_api_handler.lambda_handler(event, None)

    assert response["statusCode"] == 200


def test_lambda_handler_routes_download(web_api_handler, monkeypatch):
    def _fake_describe_execution(executionArn):  # noqa: N803
        return {"status": "SUCCEEDED", "output": json.dumps({"resolutions_processed": [], "thumbnail_key": None})}

    monkeypatch.setattr(web_api_handler.sfn, "describe_execution", _fake_describe_execution)

    event = _api_gw_event("GET", "/download/job-route-2", {"job_id": "job-route-2"})
    response = web_api_handler.lambda_handler(event, None)

    assert response["statusCode"] == 200
    body = json.loads(response["body"])
    assert body["thumbnail_url"] is None
    assert body["videos"] == {}


def test_lambda_handler_unknown_route(web_api_handler):
    response = web_api_handler.lambda_handler(_api_gw_event("DELETE", "/nope"), None)
    assert response["statusCode"] == 404
