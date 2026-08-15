"""
Fixtures shared by tests/step-functions/*.py.

Unlike tests/lambda/ and tests/video-processor/ (unit tests, mocked with
moto, safe to run anywhere with no AWS account), everything in this
directory drives REAL executions against a REAL deployed state machine --
a real S3 upload, a real EventBridge/Lambda trigger or a real
start-execution call, real ECS Fargate tasks transcoding a real (tiny)
video, and real DynamoDB reads. There is no way to meaningfully mock
"does the whole pipeline actually work end to end" -- that's the entire
point of this test suite, and it's exactly what unit tests with mocked
boto3 clients cannot catch (wrong IAM permission, a Task's Parameters
pointing at the wrong field, a real timeout that's too tight, ECS/VPC
networking that only breaks against a real subnet).

Because of that, this suite:
  - costs a small amount of real money each time it runs (a handful of
    Step Functions state transitions, a few seconds of Fargate, a few KB
    of S3/DynamoDB) -- see docs/troubleshooting.md and the root README's
    Phase 5 cost note.
  - takes minutes, not seconds, per test (waiting for real Step Functions
    executions and real ECS tasks to finish).
  - requires three environment variables identifying an already-deployed
    stack (see below). It deliberately does NOT read terraform outputs or
    terraform state itself, so it stays decoupled from how/where that
    state lives (local file, S3 backend, run from a laptop vs CI) --
    whoever runs it just exports three values.

That's why this suite is NOT part of the on-every-push CI workflow
(.github/workflows/ci.yml only runs the mocked unit tests in tests/lambda/
and tests/video-processor/, plus terraform fmt/validate). It runs via the
separate, manually-triggered .github/workflows/integration.yml, or by hand
locally against your own deployed dev stack.
"""

from __future__ import annotations

import os
import time
import uuid
from pathlib import Path

import boto3
import pytest

FIXTURES_DIR = Path(__file__).parent / "fixtures"
SAMPLE_VIDEO = FIXTURES_DIR / "sample.mp4"

# How long to wait for a full pipeline execution (validate -> parallel
# thumbnail+metadata -> Map transcode across however many resolutions were
# requested -> notify) before giving up. The sample fixture is a 1-second,
# 64x64 clip specifically so real executions finish in well under a
# minute even on Fargate's cold-start-heavy per-task startup time; this
# ceiling leaves generous headroom above that without letting a genuinely
# stuck execution hang the test suite indefinitely.
EXECUTION_TIMEOUT_SECONDS = 300
POLL_INTERVAL_SECONDS = 5


def _require_env(name: str) -> str:
    value = os.environ.get(name, "")
    if not value:
        pytest.skip(
            f"{name} is not set -- tests/step-functions/ needs a real deployed stack "
            "to test against (STATE_MACHINE_ARN, MEDIA_BUCKET_NAME, DYNAMODB_TABLE_NAME, "
            "and optionally AWS_REGION). See tests/step-functions/README.md."
        )
    return value


@pytest.fixture(scope="session")
def aws_region() -> str:
    return os.environ.get("AWS_REGION", "us-east-1")


@pytest.fixture(scope="session")
def state_machine_arn() -> str:
    return _require_env("STATE_MACHINE_ARN")


@pytest.fixture(scope="session")
def media_bucket_name() -> str:
    return _require_env("MEDIA_BUCKET_NAME")


@pytest.fixture(scope="session")
def dynamodb_table_name() -> str:
    return _require_env("DYNAMODB_TABLE_NAME")


@pytest.fixture(scope="session")
def sfn_client(aws_region):
    return boto3.client("stepfunctions", region_name=aws_region)


@pytest.fixture(scope="session")
def s3_client(aws_region):
    return boto3.client("s3", region_name=aws_region)


@pytest.fixture(scope="session")
def dynamodb_table(aws_region, dynamodb_table_name):
    return boto3.resource("dynamodb", region_name=aws_region).Table(dynamodb_table_name)


@pytest.fixture()
def unique_job_id() -> str:
    # "test-" prefix makes these easy to spot (and bulk-delete) in the
    # DynamoDB table / S3 bucket / Step Functions execution history
    # alongside real manual/EventBridge-triggered jobs.
    return f"test-{uuid.uuid4().hex[:12]}"


def upload_sample_video(s3_client, bucket: str, job_id: str, filename: str = "source.mp4") -> str:
    """Uploads the tiny real fixture video and returns its S3 key."""
    key = f"uploads/{job_id}/{filename}"
    s3_client.upload_file(str(SAMPLE_VIDEO), bucket, key)
    return key


def upload_invalid_object(s3_client, bucket: str, job_id: str) -> str:
    """
    Uploads a plainly-rejectable object (wrong extension) -- exercises the
    ValidateVideo -> IsVideoValid=false -> HandleValidationFailure branch
    without needing a second binary fixture. See src/lambda/validate/
    handler.py: rejection here is a metadata check (file extension against
    ALLOWED_FORMATS), not a deep content probe, so a .txt object is enough
    to reliably trigger it.
    """
    key = f"uploads/{job_id}/notes.txt"
    s3_client.put_object(Bucket=bucket, Key=key, Body=b"this is not a video", ContentType="text/plain")
    return key


def start_execution(sfn_client, state_machine_arn: str, job_id: str, bucket: str, key: str, resolutions=None):
    import json

    payload = {
        "job_id": job_id,
        "bucket": bucket,
        "key": key,
        "resolutions": resolutions or ["480p"],
    }
    response = sfn_client.start_execution(
        stateMachineArn=state_machine_arn,
        name=job_id,
        input=json.dumps(payload),
    )
    return response["executionArn"]


def wait_for_execution(sfn_client, execution_arn: str, timeout_seconds: int = EXECUTION_TIMEOUT_SECONDS) -> dict:
    """Polls DescribeExecution until it leaves RUNNING, or raises TimeoutError."""
    deadline = time.monotonic() + timeout_seconds
    while time.monotonic() < deadline:
        description = sfn_client.describe_execution(executionArn=execution_arn)
        if description["status"] != "RUNNING":
            return description
        time.sleep(POLL_INTERVAL_SECONDS)
    raise TimeoutError(
        f"Execution {execution_arn} did not finish within {timeout_seconds}s -- see "
        "docs/troubleshooting.md#integration-tests-time-out for what to check."
    )
