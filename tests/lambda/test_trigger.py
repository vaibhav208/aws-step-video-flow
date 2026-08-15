"""
Unit tests for src/lambda/trigger/handler.py: EventBridge S3 event ->
Step Functions StartExecution, including the malformed-key skip path and
the ExecutionAlreadyExists idempotency path.
"""

import json

import boto3
import pytest
from moto import mock_aws

from conftest import TEST_STATE_MACHINE_ARN

REGION = "us-east-1"


def _s3_object_created_event(bucket: str, key: str) -> dict:
    return {
        "source": "aws.s3",
        "detail-type": "Object Created",
        "detail": {
            "bucket": {"name": bucket},
            "object": {"key": key},
        },
    }


@pytest.fixture
def state_machine():
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
                "StartAt": "Done",
                "States": {"Done": {"Type": "Succeed"}},
            }
        )
        created = sfn.create_state_machine(
            name="test-pipeline",
            definition=definition,
            roleArn=role,
        )
        assert created["stateMachineArn"] == TEST_STATE_MACHINE_ARN

        yield sfn


def test_starts_execution_for_valid_key(trigger_handler, state_machine):
    event = _s3_object_created_event("my-media-bucket", "uploads/job-abc123/source.mp4")

    result = trigger_handler.lambda_handler(event, None)

    assert result["started"] is True
    assert result["job_id"] == "job-abc123"

    execution = state_machine.describe_execution(executionArn=result["execution_arn"])
    execution_input = json.loads(execution["input"])
    assert execution_input == {
        "job_id": "job-abc123",
        "bucket": "my-media-bucket",
        "key": "uploads/job-abc123/source.mp4",
        "resolutions": ["1080p", "720p", "480p"],
    }
    # StartExecution's own name uniqueness constraint is job_id-shaped, not
    # timestamp-suffixed -- see the idempotency discussion in handler.py.
    assert execution["name"] == "job-abc123"


def test_uses_custom_target_resolutions(trigger_handler, state_machine, monkeypatch):
    monkeypatch.setenv("TARGET_RESOLUTIONS", "1080p,240p")
    event = _s3_object_created_event("my-media-bucket", "uploads/job-res/source.mp4")

    result = trigger_handler.lambda_handler(event, None)

    execution = state_machine.describe_execution(executionArn=result["execution_arn"])
    assert json.loads(execution["input"])["resolutions"] == ["1080p", "240p"]


def test_duplicate_delivery_is_idempotent(trigger_handler, state_machine, monkeypatch):
    # moto's Step Functions backend doesn't enforce real AWS's
    # (name, input)-uniqueness rule for StartExecution, so a second
    # start_execution call with the same name wouldn't naturally raise here
    # the way it does against the real API. Simulating the ClientError
    # directly unit-tests handler.py's own catch/return logic for that case
    # without depending on a moto behavior that isn't implemented.
    from botocore.exceptions import ClientError

    def _raise_already_exists(**kwargs):
        raise ClientError(
            {"Error": {"Code": "ExecutionAlreadyExists", "Message": "already exists"}},
            "StartExecution",
        )

    monkeypatch.setattr(trigger_handler.sfn, "start_execution", _raise_already_exists)

    event = _s3_object_created_event("my-media-bucket", "uploads/job-dup/source.mp4")
    result = trigger_handler.lambda_handler(event, None)

    assert result["started"] is False
    assert result["reason"] == "ExecutionAlreadyExists"
    assert result["job_id"] == "job-dup"


@pytest.mark.parametrize(
    "key",
    [
        "uploads/",  # no job_id, no filename
        "uploads/job-only",  # job_id but no filename segment
        "processed/job-abc/1080p/video.mp4",  # not under uploads/ at all
    ],
)
def test_skips_malformed_or_unexpected_keys(trigger_handler, state_machine, key):
    event = _s3_object_created_event("my-media-bucket", key)

    result = trigger_handler.lambda_handler(event, None)

    assert result["skipped"] is True


def test_skips_event_missing_detail(trigger_handler, state_machine):
    result = trigger_handler.lambda_handler({"detail": {}}, None)

    assert result["skipped"] is True
