"""
Real, end-to-end tests against a deployed stack. See conftest.py's module
docstring for why these are unmocked, costly-in-minutes-not-seconds, and
deliberately excluded from the on-every-push CI workflow.

Three deterministic scenarios are covered here -- chosen specifically
because each can be triggered reliably through the pipeline's own
documented inputs, with no need to temporarily break IAM policies, tamper
with TimeoutSeconds, or otherwise mutate the deployed infrastructure to
force a failure (which would be a much riskier thing to automate against a
real AWS account than the fully self-contained tests below):

  1. Success: a real (tiny) video, 480p only, all the way through to
     JobSucceeded and NotifySuccess.
  2. Validation failure: a .txt object under uploads/, which ValidateVideo
     rejects on file extension -- routes through HandleValidationFailure /
     NotifyValidationFailure to ValidationFailedState.
  3. Processing failure: a valid video but an unsupported resolution
     string ("8k") -- the video-processor container exits 1, which
     RunTranscodeTask's Catch routes through HandleProcessingFailure /
     NotifyProcessingFailure to ProcessingFailedState.

The remaining scenarios documented in step-functions/README.md's
"Simulating failures" section (Lambda transient failure exhausting Retry,
an ECS task killed out from under RunTranscodeTask, a state's
TimeoutSeconds actually firing) aren't automated here because reliably
forcing them requires deliberately degrading the real deployed
infrastructure (revoking a permission, killing a task mid-flight, cutting
a timeout to something that will legitimately race) -- appropriate to walk
through by hand against a dev stack, not to script unattended against
whatever account CI happens to be pointed at.
"""

from __future__ import annotations

from conftest import (
    start_execution,
    upload_invalid_object,
    upload_sample_video,
    wait_for_execution,
)


def test_successful_execution_completes(
    sfn_client, s3_client, dynamodb_table, state_machine_arn, media_bucket_name, unique_job_id
):
    key = upload_sample_video(s3_client, media_bucket_name, unique_job_id)

    execution_arn = start_execution(
        sfn_client, state_machine_arn, unique_job_id, media_bucket_name, key, resolutions=["480p"]
    )
    result = wait_for_execution(sfn_client, execution_arn)

    assert result["status"] == "SUCCEEDED", (
        f"execution ended in {result['status']}, expected SUCCEEDED -- see CloudWatch Logs "
        f"for {execution_arn} and docs/troubleshooting.md"
    )

    item = dynamodb_table.get_item(Key={"job_id": unique_job_id}).get("Item")
    assert item is not None, "expected a DynamoDB job record to exist after a successful run"
    assert item["status"] == "SUCCESS"
    assert item.get("resolutions_processed") == ["480p"]
    assert "thumbnail_key" in item
    # Written by the metadata Lambda's ffprobe output -- confirms the
    # ExtractMetadata branch of the Parallel state actually ran, not just
    # the thumbnail branch.
    assert "duration_seconds" in item


def test_validation_failure_routes_correctly(
    sfn_client, s3_client, dynamodb_table, state_machine_arn, media_bucket_name, unique_job_id
):
    key = upload_invalid_object(s3_client, media_bucket_name, unique_job_id)

    execution_arn = start_execution(sfn_client, state_machine_arn, unique_job_id, media_bucket_name, key)
    result = wait_for_execution(sfn_client, execution_arn)

    assert result["status"] == "FAILED", (
        f"execution ended in {result['status']}, expected FAILED (ValidationFailedState) -- "
        f"a .txt upload should always be rejected by ValidateVideo's format check"
    )

    item = dynamodb_table.get_item(Key={"job_id": unique_job_id}).get("Item")
    assert item is not None
    assert item["status"] == "FAILED"
    assert item.get("failure_stage") == "VALIDATION"
    assert item.get("validation_errors")


def test_processing_failure_routes_correctly(
    sfn_client, s3_client, dynamodb_table, state_machine_arn, media_bucket_name, unique_job_id
):
    key = upload_sample_video(s3_client, media_bucket_name, unique_job_id)

    execution_arn = start_execution(
        sfn_client, state_machine_arn, unique_job_id, media_bucket_name, key, resolutions=["8k"]
    )
    result = wait_for_execution(sfn_client, execution_arn)

    assert result["status"] == "FAILED", (
        f"execution ended in {result['status']}, expected FAILED (ProcessingFailedState) -- "
        f"'8k' isn't one of the six resolution presets video-processor supports"
    )

    item = dynamodb_table.get_item(Key={"job_id": unique_job_id}).get("Item")
    assert item is not None
    assert item["status"] == "FAILED"
    assert item.get("failure_stage") == "PROCESSING"
