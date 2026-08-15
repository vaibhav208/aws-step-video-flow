"""
Unit tests for src/lambda/validate/handler.py, covering the four Phase 2
scenarios called out in the project spec: valid video, invalid format,
oversized file, missing object.
"""

import boto3
import pytest
from moto import mock_aws

BUCKET = "test-media-bucket"


@pytest.fixture
def s3_bucket():
    with mock_aws():
        client = boto3.client("s3", region_name="us-east-1")
        client.create_bucket(Bucket=BUCKET)
        yield client


def test_valid_video_passes(validate_handler, s3_bucket, monkeypatch):
    monkeypatch.setenv("ALLOWED_FORMATS", "mp4,mov,mkv,avi")
    monkeypatch.setenv("MAX_FILE_SIZE_BYTES", str(5 * 1024 * 1024 * 1024))

    key = "uploads/job-1/source.mp4"
    s3_bucket.put_object(Bucket=BUCKET, Key=key, Body=b"fake video bytes", ContentType="video/mp4")

    result = validate_handler.lambda_handler(
        {"job_id": "job-1", "bucket": BUCKET, "key": key}, None
    )

    assert result["is_valid"] is True
    assert result["validation_errors"] == []
    assert result["format"] == "mp4"
    assert result["file_size"] == len(b"fake video bytes")


def test_invalid_format_is_rejected(validate_handler, s3_bucket):
    key = "uploads/job-2/source.txt"
    s3_bucket.put_object(Bucket=BUCKET, Key=key, Body=b"not a video")

    result = validate_handler.lambda_handler(
        {"job_id": "job-2", "bucket": BUCKET, "key": key}, None
    )

    assert result["is_valid"] is False
    assert any("Unsupported format" in e for e in result["validation_errors"])


def test_oversized_file_is_rejected(validate_handler, s3_bucket, monkeypatch):
    monkeypatch.setenv("MAX_FILE_SIZE_BYTES", "100")  # tiny limit for the test

    key = "uploads/job-3/source.mp4"
    s3_bucket.put_object(Bucket=BUCKET, Key=key, Body=b"x" * 200)

    result = validate_handler.lambda_handler(
        {"job_id": "job-3", "bucket": BUCKET, "key": key}, None
    )

    assert result["is_valid"] is False
    assert any("exceeds" in e for e in result["validation_errors"])


def test_missing_object_raises(validate_handler, s3_bucket):
    with pytest.raises(validate_handler.SourceObjectNotFoundError):
        validate_handler.lambda_handler(
            {"job_id": "job-4", "bucket": BUCKET, "key": "uploads/job-4/does-not-exist.mp4"},
            None,
        )
