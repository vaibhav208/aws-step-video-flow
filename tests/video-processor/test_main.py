"""
Unit tests for src/video-processor/app/main.py, covering the four Phase 2
scenarios called out in the project spec: valid input, FFmpeg failure,
missing S3 object, unsupported resolution.

ffmpeg itself is never actually invoked here — subprocess.run is
monkeypatched so these tests run anywhere (no ffmpeg binary required) and
stay fast. What IS real: S3 (via moto) and the app's own control flow
(env var validation, error handling, exit codes, the RESULT: JSON line).
"""

import os

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


def _base_env(monkeypatch, **overrides):
    env = {
        "JOB_ID": "job-1",
        "SOURCE_BUCKET": BUCKET,
        "SOURCE_KEY": "uploads/job-1/source.mp4",
        "RESOLUTION": "720p",
        "OUTPUT_BUCKET": BUCKET,
        **overrides,
    }
    for k, v in env.items():
        monkeypatch.setenv(k, v)


def test_missing_required_env_var_fails(main_module, monkeypatch, capsys):
    # No env vars set at all.
    rc = main_module.main()
    assert rc == 1
    assert '"status": "FAILED"' in capsys.readouterr().out


def test_unsupported_resolution_fails(main_module, monkeypatch, capsys):
    _base_env(monkeypatch, RESOLUTION="8k")
    rc = main_module.main()
    assert rc == 1
    out = capsys.readouterr().out
    assert '"status": "FAILED"' in out
    assert "Unsupported resolution" in out


def test_missing_s3_object_fails(main_module, monkeypatch, s3_bucket, capsys):
    _base_env(monkeypatch)  # source key was never uploaded to the bucket
    rc = main_module.main()
    assert rc == 1
    assert "download failed" in capsys.readouterr().out


def test_ffmpeg_failure_is_reported(main_module, monkeypatch, s3_bucket, capsys):
    _base_env(monkeypatch)
    s3_bucket.put_object(Bucket=BUCKET, Key="uploads/job-1/source.mp4", Body=b"fake video")

    def fake_run(cmd, capture_output, text, **kwargs):
        class Result:
            returncode = 1
            stderr = "ffmpeg: invalid data found when processing input"
        return Result()

    monkeypatch.setattr(main_module.subprocess, "run", fake_run)

    rc = main_module.main()
    assert rc == 1
    out = capsys.readouterr().out
    assert '"status": "FAILED"' in out
    assert "ffmpeg exited" in out


def test_valid_input_succeeds(main_module, monkeypatch, s3_bucket, capsys):
    _base_env(monkeypatch)
    s3_bucket.put_object(Bucket=BUCKET, Key="uploads/job-1/source.mp4", Body=b"fake video")

    def fake_run(cmd, capture_output, text, **kwargs):
        # cmd[-1] is the output path main.py asked ffmpeg to write to;
        # simulate a successful transcode by actually creating that file.
        output_path = cmd[-1]
        with open(output_path, "wb") as f:
            f.write(b"fake transcoded output")

        class Result:
            returncode = 0
            stderr = ""
        return Result()

    monkeypatch.setattr(main_module.subprocess, "run", fake_run)

    rc = main_module.main()
    assert rc == 0

    out = capsys.readouterr().out
    assert '"status": "SUCCESS"' in out
    assert '"output_key": "processed/job-1/720p/video.mp4"' in out

    # And the "uploaded" object really exists in the mocked bucket.
    head = s3_bucket.head_object(Bucket=BUCKET, Key="processed/job-1/720p/video.mp4")
    assert head["ContentLength"] == len(b"fake transcoded output")
