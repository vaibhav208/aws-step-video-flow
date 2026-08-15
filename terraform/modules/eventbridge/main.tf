# ---------------------------------------------------------------------------
# EventBridge — Phase 4
#
# S3 upload -> EventBridge rule -> trigger Lambda -> Step Functions
# StartExecution. The trigger Lambda (and its dedicated IAM role) live in
# THIS module rather than in modules/lambda (Phase 2), because they need
# var.state_machine_arn — which only exists after modules/step-functions
# (Phase 3) has been created. Putting the trigger function in modules/lambda
# would make that module depend on step-functions' output while
# step-functions itself depends on modules/lambda's four other function
# ARNs, a circular module dependency Terraform doesn't allow. Keeping it
# self-contained here (created AFTER step_functions in the root module) is
# the simplest way to avoid that without restructuring Phase 2/3.
# ---------------------------------------------------------------------------

# =============================================================================
# 1. The trigger Lambda itself
# =============================================================================

data "archive_file" "trigger" {
  type        = "zip"
  source_dir  = "${var.src_dir}/trigger"
  output_path = "${path.module}/build/trigger.zip"
}

data "aws_iam_policy_document" "trigger_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "trigger" {
  name               = "${var.name_prefix}-trigger-execution"
  assume_role_policy = data.aws_iam_policy_document.trigger_assume_role.json
  tags               = var.tags
}

# The ONLY AWS API this function calls is StartExecution, scoped to exactly
# this one state machine -- it never touches S3 or DynamoDB directly (it
# only reads bucket/key out of the EventBridge event payload it's already
# been given), so no other policy is attached to this role.
data "aws_iam_policy_document" "trigger_start_execution" {
  statement {
    sid       = "StartVideoPipelineExecution"
    actions   = ["states:StartExecution"]
    resources = [var.state_machine_arn]
  }
}

resource "aws_iam_policy" "trigger_start_execution" {
  name   = "${var.name_prefix}-trigger-start-execution"
  policy = data.aws_iam_policy_document.trigger_start_execution.json
}

resource "aws_iam_role_policy_attachment" "trigger_start_execution" {
  role       = aws_iam_role.trigger.name
  policy_arn = aws_iam_policy.trigger_start_execution.arn
}

data "aws_iam_policy_document" "trigger_logs" {
  statement {
    sid = "WriteOwnLogGroup"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-trigger",
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-trigger:*",
    ]
  }
}

resource "aws_iam_policy" "trigger_logs" {
  name   = "${var.name_prefix}-trigger-logs"
  policy = data.aws_iam_policy_document.trigger_logs.json
}

resource "aws_iam_role_policy_attachment" "trigger_logs" {
  role       = aws_iam_role.trigger.name
  policy_arn = aws_iam_policy.trigger_logs.arn
}

resource "aws_cloudwatch_log_group" "trigger" {
  name              = "/aws/lambda/${var.name_prefix}-trigger"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "trigger" {
  function_name = "${var.name_prefix}-trigger"
  role          = aws_iam_role.trigger.arn

  filename         = data.archive_file.trigger.output_path
  source_code_hash = data.archive_file.trigger.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"

  timeout     = var.trigger_timeout_seconds
  memory_size = var.trigger_memory_mb

  environment {
    variables = {
      STATE_MACHINE_ARN  = var.state_machine_arn
      TARGET_RESOLUTIONS = var.target_resolutions
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.trigger,
    aws_iam_role_policy_attachment.trigger_start_execution,
    aws_iam_role_policy_attachment.trigger_logs,
  ]
  tags = var.tags
}

# =============================================================================
# 2. EventBridge rule: S3 Object Created under uploads/, in this bucket
# =============================================================================

# Matches ALL object creates in the bucket (thumbnails/, processed/,
# metadata/ included) at the EventBridge level unless filtered -- the
# "uploads/" prefix filter below is what keeps this rule from re-triggering
# itself on the pipeline's own output writes.
resource "aws_cloudwatch_event_rule" "s3_upload" {
  name        = "${var.name_prefix}-s3-upload"
  description = "Matches S3 Object Created events for new uploads (key prefix 'uploads/') in the media bucket."

  event_pattern = jsonencode({
    source      = ["aws.s3"]
    detail-type = ["Object Created"]
    detail = {
      bucket = {
        name = [var.media_bucket_name]
      }
      object = {
        key = [{ prefix = "uploads/" }]
      }
    }
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "trigger_lambda" {
  rule = aws_cloudwatch_event_rule.s3_upload.name
  arn  = aws_lambda_function.trigger.arn
}

# EventBridge needs explicit, resource-based permission to invoke a Lambda
# function -- this is separate from (and in addition to) the trigger
# function's own execution role above, which governs what the function can
# do once it's running, not who's allowed to invoke it.
resource "aws_lambda_permission" "allow_eventbridge" {
  statement_id  = "AllowEventBridgeInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.trigger.function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.s3_upload.arn
}
