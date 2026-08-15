"""
database — the single Lambda that owns every write to the VideoProcessingJobs
DynamoDB table. Every other component (validate/metadata/thumbnail Lambdas,
the ECS video processor via its results, and Step Functions itself) reports
what happened by calling this function with a job_id and a flat map of
attributes to set; it never talks to DynamoDB directly. That's a deliberate
single-writer design: one place to get conditional-write/idempotency and
reserved-word handling right, instead of repeating DynamoDB update-expression
code in five places.

Reused across multiple different Step Functions Task states (Phase 3) that
each build a different `updates` payload before calling this same function —
e.g. "Initialize Job" calls it with {"status": "PENDING"}, "Store Failure
Info" calls it with {"status": "FAILED", "error_message": "..."}. That
reuse is a deliberate demonstration of Parameters/InputPath shaping
different inputs for the same Task resource, documented in
docs/step-functions.md (Phase 3).

Step Functions Task contract
-----------------------------
Create (idempotent — safe to retry):
    {
        "job_id": "abc123",
        "create": true,
        "updates": {"status": "PENDING", "input_bucket": "...", "input_key": "..."}
    }

Update (job must already exist):
    {
        "job_id": "abc123",
        "updates": {"status": "PROCESSING", "started_at": "2026-08-14T10:00:00Z"}
    }

Output (always echoes back what's now in the table for the fields touched):
    {"job_id": "abc123", "updates": {...}, "updated_at": "2026-08-14T10:00:05Z"}

Errors
------
`JobAlreadyExistsError` — raised on a `create: true` call for a job_id that
already exists. Callers that want "create or update" semantics should not
pass `create: true`; it exists specifically so the "Initialize Job" state
fails loudly on a duplicate EventBridge delivery rather than silently
resetting an in-progress job back to PENDING.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from botocore.exceptions import ClientError

logger = logging.getLogger()
logger.setLevel(logging.INFO)

dynamodb = boto3.resource("dynamodb")
TABLE_NAME = os.environ["TABLE_NAME"]
table = dynamodb.Table(TABLE_NAME)

# DynamoDB reserved words that commonly show up as job attribute names.
# ExpressionAttributeNames sidesteps all of them, so this list is just
# documentation of *why* every attribute is aliased rather than a filter.
_RESERVED_EXAMPLES = {"status", "duration", "format", "bucket"}


class JobAlreadyExistsError(Exception):
    pass


def _now_iso() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _to_dynamodb_safe(value):
    """Recursively convert native Python floats to decimal.Decimal.

    boto3's DynamoDB *resource* API (what this module uses via
    dynamodb.Table) rejects native floats outright with "Float types are
    not supported. Use Decimal types instead." -- every caller of this
    function passes attributes straight through from ffprobe/JSON-derived
    data (e.g. metadata_handler.py's `duration_seconds`), so floats are a
    routine, expected input here, not an edge case.

    Round-trips through str() before Decimal() (rather than Decimal(value)
    directly) to avoid baking in binary-float representation artifacts --
    e.g. Decimal(1.1) == Decimal('1.100000000000000088817841970012523...'),
    while Decimal(str(1.1)) == Decimal('1.1'), which is what a human
    reading the DynamoDB item would actually expect.

    Since this is the project's single DynamoDB-writer chokepoint (see
    module docstring), fixing float-handling here covers every current and
    future caller -- metadata, thumbnail, ECS results -- not just one.
    """
    if isinstance(value, float):
        return Decimal(str(value))
    if isinstance(value, dict):
        return {k: _to_dynamodb_safe(v) for k, v in value.items()}
    if isinstance(value, list):
        return [_to_dynamodb_safe(v) for v in value]
    return value


def lambda_handler(event, context):  # noqa: ARG001
    job_id = event["job_id"]
    updates: dict = _to_dynamodb_safe(dict(event.get("updates", {})))
    create = bool(event.get("create", False))

    updates["updated_at"] = _now_iso()

    if create:
        item = {"job_id": job_id, "created_at": updates.get("created_at", _now_iso()), **updates}
        try:
            table.put_item(
                Item=item,
                ConditionExpression="attribute_not_exists(job_id)",
            )
        except ClientError as exc:
            if exc.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
                raise JobAlreadyExistsError(f"job_id={job_id} already exists") from exc
            raise

        logger.info("Created job_id=%s item=%s", job_id, item)
        return {"job_id": job_id, "updates": item, "updated_at": item["updated_at"]}

    # Build a safe UpdateExpression using ExpressionAttributeNames for every
    # attribute (cheaper than maintaining a reserved-word denylist, and
    # correct even for attribute names DynamoDB adds to its reserved list in
    # the future).
    update_expr_parts = []
    expr_attr_names = {}
    expr_attr_values = {}

    for i, (attr, value) in enumerate(updates.items()):
        name_placeholder = f"#a{i}"
        value_placeholder = f":v{i}"
        update_expr_parts.append(f"{name_placeholder} = {value_placeholder}")
        expr_attr_names[name_placeholder] = attr
        expr_attr_values[value_placeholder] = value

    update_expression = "SET " + ", ".join(update_expr_parts)

    table.update_item(
        Key={"job_id": job_id},
        UpdateExpression=update_expression,
        ExpressionAttributeNames=expr_attr_names,
        ExpressionAttributeValues=expr_attr_values,
    )

    logger.info("Updated job_id=%s updates=%s", job_id, updates)
    return {"job_id": job_id, "updates": updates, "updated_at": updates["updated_at"]}
