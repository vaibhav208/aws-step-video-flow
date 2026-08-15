# ---------------------------------------------------------------------------
# VideoProcessingJobs table
#
# One item per job_id. DynamoDB is schemaless beyond its declared key
# attributes, so only job_id (hash key) and the two GSI attributes below are
# declared to Terraform/AWS — the rest of the item shape (status,
# input_bucket, input_key, file_size, duration, format,
# requested_resolutions, completed_resolutions, failed_resolutions,
# output_locations, thumbnail_location, created_at, started_at,
# completed_at, processing_duration, error_message, ...) is written by the
# Phase 2 "database" Lambda and by Step Functions' native DynamoDB
# integration in Phase 3. See docs/architecture.md for the full item shape.
#
# PAY_PER_REQUEST billing avoids paying for idle provisioned throughput
# between learning sessions — this table will see bursty, low-volume
# traffic, which is exactly what on-demand billing is for.
# ---------------------------------------------------------------------------

resource "aws_dynamodb_table" "jobs" {
  name         = var.table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "job_id"

  attribute {
    name = "job_id"
    type = "S"
  }

  # Attributes backing the GSI below. Only attributes used as a table or
  # index key need to be declared here; everything else in the item is
  # freeform.
  attribute {
    name = "status"
    type = "S"
  }

  attribute {
    name = "created_at"
    type = "S"
  }

  # Lets the API / operators list jobs by status (e.g. "show me every
  # FAILED job", or "show me everything still PROCESSING") without a table
  # scan, ordered by creation time within each status.
  global_secondary_index {
    name            = "status-created_at-index"
    hash_key        = "status"
    range_key       = "created_at"
    projection_type = "ALL"
  }

  point_in_time_recovery {
    enabled = var.enable_point_in_time_recovery
  }

  server_side_encryption {
    enabled = true
  }

  tags = var.tags
}
