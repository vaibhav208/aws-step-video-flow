"""
Unit tests for src/lambda/database/handler.py: job creation (and its
idempotency guarantee), and attribute updates.
"""

from decimal import Decimal

import boto3
import pytest
from moto import mock_aws

TABLE_NAME = "test-jobs-table"


@pytest.fixture
def jobs_table():
    with mock_aws():
        client = boto3.client("dynamodb", region_name="us-east-1")
        client.create_table(
            TableName=TABLE_NAME,
            KeySchema=[{"AttributeName": "job_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "job_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        yield boto3.resource("dynamodb", region_name="us-east-1").Table(TABLE_NAME)


def test_create_job(database_handler, jobs_table):
    result = database_handler.lambda_handler(
        {"job_id": "job-1", "create": True, "updates": {"status": "PENDING", "input_bucket": "b"}},
        None,
    )

    assert result["job_id"] == "job-1"
    item = jobs_table.get_item(Key={"job_id": "job-1"})["Item"]
    assert item["status"] == "PENDING"
    assert item["input_bucket"] == "b"
    assert "created_at" in item


def test_create_job_twice_raises(database_handler, jobs_table):
    database_handler.lambda_handler(
        {"job_id": "job-2", "create": True, "updates": {"status": "PENDING"}}, None
    )

    with pytest.raises(database_handler.JobAlreadyExistsError):
        database_handler.lambda_handler(
            {"job_id": "job-2", "create": True, "updates": {"status": "PENDING"}}, None
        )


def test_update_job_status(database_handler, jobs_table):
    database_handler.lambda_handler(
        {"job_id": "job-3", "create": True, "updates": {"status": "PENDING"}}, None
    )

    database_handler.lambda_handler(
        {"job_id": "job-3", "updates": {"status": "PROCESSING", "started_at": "2026-08-14T10:00:00Z"}},
        None,
    )

    item = jobs_table.get_item(Key={"job_id": "job-3"})["Item"]
    assert item["status"] == "PROCESSING"
    assert item["started_at"] == "2026-08-14T10:00:00Z"


def test_update_job_with_float_attribute(database_handler, jobs_table):
    # Regression test for a real production bug: boto3's DynamoDB *resource*
    # API rejects native Python floats outright ("Float types are not
    # supported. Use Decimal types instead."). metadata_handler.py returns
    # duration_seconds as a real float from ffprobe, which flows straight
    # into this handler's `updates` payload via Step Functions -- every
    # other test in this file only ever used ints/strings, so this path
    # went untested until a real video hit it in production. handler.py's
    # _to_dynamodb_safe() is what fixes this; this test pins the fix.
    database_handler.lambda_handler(
        {"job_id": "job-5", "create": True, "updates": {"status": "PENDING"}}, None
    )

    database_handler.lambda_handler(
        {
            "job_id": "job-5",
            "updates": {
                "status": "SUCCESS",
                "duration_seconds": 42.7,
                "nested": {"bitrate": 5_000_000.5},
                "list_of_floats": [1.1, 2.2],
            },
        },
        None,
    )

    item = jobs_table.get_item(Key={"job_id": "job-5"})["Item"]
    assert item["duration_seconds"] == Decimal("42.7")
    assert item["nested"]["bitrate"] == Decimal("5000000.5")
    assert item["list_of_floats"] == [Decimal("1.1"), Decimal("2.2")]


def test_update_uses_reserved_word_attribute_names(database_handler, jobs_table):
    # "status", "duration", and "format" are all DynamoDB reserved words —
    # this specifically exercises the ExpressionAttributeNames aliasing
    # rather than relying on values that happen not to collide.
    database_handler.lambda_handler(
        {"job_id": "job-4", "create": True, "updates": {"status": "PENDING"}}, None
    )

    database_handler.lambda_handler(
        {"job_id": "job-4", "updates": {"status": "SUCCESS", "duration": 42, "format": "mp4"}},
        None,
    )

    item = jobs_table.get_item(Key={"job_id": "job-4"})["Item"]
    assert item["status"] == "SUCCESS"
    assert item["duration"] == 42
    assert item["format"] == "mp4"
