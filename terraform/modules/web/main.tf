# ---------------------------------------------------------------------------
# Web — Phase 6
#
# A small browser frontend (frontend/index.html.tpl) that uploads a video
# and watches the resulting Step Functions execution's state transitions
# live, as an alternative to the AWS console for demoing this project. Two
# pieces:
#
#   1. web_api — one Lambda behind an API Gateway HTTP API, serving
#      POST /presign (issue a pre-signed S3 PUT URL for a new job) and
#      GET /status/{job_id} (DescribeExecution + GetExecutionHistory,
#      simplified into a frontend-friendly per-node status map). See
#      src/lambda/web_api/handler.py for the full route contract.
#   2. An S3 bucket configured for static website hosting, serving the
#      single templated index.html with the real API Gateway invoke URL
#      baked in at apply time.
#
# Created LAST (after step_functions in the root module) for the same
# reason modules/eventbridge is: this needs var.state_machine_arn, which
# only exists once Phase 3 has run.
#
# Deliberately simple for a learning/demo project: the frontend bucket
# serves plain HTTP via S3 website hosting (no CloudFront/ACM/HTTPS) and
# the API Gateway CORS policy allows any origin, matching the media
# bucket's own CORS default (s3_cors_allowed_origins = ["*"], see
# terraform/variables.tf). Tighten both before using this pattern for
# anything beyond a demo.
# ---------------------------------------------------------------------------

# =============================================================================
# 1. web_api Lambda
# =============================================================================

data "archive_file" "web_api" {
  type        = "zip"
  source_dir  = "${var.src_dir}/web_api"
  output_path = "${path.module}/build/web_api.zip"
}

data "aws_iam_policy_document" "web_api_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "web_api" {
  name               = "${var.name_prefix}-web-api-execution"
  assume_role_policy = data.aws_iam_policy_document.web_api_assume_role.json
  tags               = var.tags
}

# Only what /presign needs: sign PUT URLs for new-job source videos.
# Scoped to uploads/*, not the whole bucket -- this function never reads or
# lists anything, and has no business touching processed/thumbnails/
# metadata output prefixes.
data "aws_iam_policy_document" "web_api_s3" {
  statement {
    sid       = "PresignUploadUrls"
    actions   = ["s3:PutObject"]
    resources = ["${var.media_bucket_arn}/uploads/*"]
  }
}

resource "aws_iam_policy" "web_api_s3" {
  name   = "${var.name_prefix}-web-api-s3-presign"
  policy = data.aws_iam_policy_document.web_api_s3.json
}

resource "aws_iam_role_policy_attachment" "web_api_s3" {
  role       = aws_iam_role.web_api.name
  policy_arn = aws_iam_policy.web_api_s3.arn
}

# Only what /status/{job_id} needs: read-only visibility into executions of
# THIS state machine specifically -- never states:StartExecution (that
# remains the trigger Lambda's job, see modules/eventbridge) and never any
# other state machine in the account.
data "aws_iam_policy_document" "web_api_sfn" {
  statement {
    sid = "ReadThisStateMachinesExecutions"
    actions = [
      "states:DescribeExecution",
      "states:GetExecutionHistory",
    ]
    resources = ["${replace(var.state_machine_arn, ":stateMachine:", ":execution:")}:*"]
  }
}

resource "aws_iam_policy" "web_api_sfn" {
  name   = "${var.name_prefix}-web-api-sfn-read"
  policy = data.aws_iam_policy_document.web_api_sfn.json
}

resource "aws_iam_role_policy_attachment" "web_api_sfn" {
  role       = aws_iam_role.web_api.name
  policy_arn = aws_iam_policy.web_api_sfn.arn
}

data "aws_iam_policy_document" "web_api_logs" {
  statement {
    sid = "WriteOwnLogGroup"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-web-api",
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-web-api:*",
    ]
  }
}

resource "aws_iam_policy" "web_api_logs" {
  name   = "${var.name_prefix}-web-api-logs"
  policy = data.aws_iam_policy_document.web_api_logs.json
}

resource "aws_iam_role_policy_attachment" "web_api_logs" {
  role       = aws_iam_role.web_api.name
  policy_arn = aws_iam_policy.web_api_logs.arn
}

resource "aws_cloudwatch_log_group" "web_api" {
  name              = "/aws/lambda/${var.name_prefix}-web-api"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "web_api" {
  function_name = "${var.name_prefix}-web-api"
  role          = aws_iam_role.web_api.arn

  filename         = data.archive_file.web_api.output_path
  source_code_hash = data.archive_file.web_api.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"

  timeout     = var.web_api_timeout_seconds
  memory_size = var.web_api_memory_mb

  environment {
    variables = {
      MEDIA_BUCKET                 = var.media_bucket_name
      STATE_MACHINE_ARN            = var.state_machine_arn
      PRESIGNED_URL_EXPIRY_SECONDS = tostring(var.presigned_url_expiry_seconds)
    }
  }

  depends_on = [
    aws_cloudwatch_log_group.web_api,
    aws_iam_role_policy_attachment.web_api_s3,
    aws_iam_role_policy_attachment.web_api_sfn,
    aws_iam_role_policy_attachment.web_api_logs,
  ]
  tags = var.tags
}

# =============================================================================
# 2. API Gateway HTTP API
# =============================================================================

resource "aws_apigatewayv2_api" "web" {
  name          = "${var.name_prefix}-web-api"
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["*"]
  }

  tags = var.tags
}

resource "aws_apigatewayv2_integration" "web_api" {
  api_id                 = aws_apigatewayv2_api.web.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.web_api.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "presign" {
  api_id    = aws_apigatewayv2_api.web.id
  route_key = "POST /presign"
  target    = "integrations/${aws_apigatewayv2_integration.web_api.id}"
}

resource "aws_apigatewayv2_route" "status" {
  api_id    = aws_apigatewayv2_api.web.id
  route_key = "GET /status/{job_id}"
  target    = "integrations/${aws_apigatewayv2_integration.web_api.id}"
}

resource "aws_cloudwatch_log_group" "web_api_access_logs" {
  name              = "/aws/apigateway/${var.name_prefix}-web-api"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.web.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.web_api_access_logs.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      integrationErr = "$context.integrationErrorMessage"
      responseTime   = "$context.responseLatency"
    })
  }

  tags = var.tags
}

resource "aws_lambda_permission" "allow_apigateway" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.web_api.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.web.execution_arn}/*/*"
}

# =============================================================================
# 3. Frontend static hosting
# =============================================================================

resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.name_prefix}-web-${var.account_id}"
  force_destroy = true

  tags = var.tags
}

resource "aws_s3_bucket_website_configuration" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  index_document {
    suffix = "index.html"
  }
}

# Public READ only -- this bucket serves one static HTML file to anyone,
# by design (it's a public demo page with no secrets in it; the only
# privileged operations, presigning uploads and reading execution state,
# happen through web_api's own IAM role, not through this bucket). No
# write/list/delete access is granted publicly.
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = false
  ignore_public_acls      = true
  restrict_public_buckets = false
}

data "aws_iam_policy_document" "frontend_public_read" {
  statement {
    sid       = "PublicReadGetObject"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]
    principals {
      type        = "*"
      identifiers = ["*"]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend_public_read" {
  bucket     = aws_s3_bucket.frontend.id
  policy     = data.aws_iam_policy_document.frontend_public_read.json
  depends_on = [aws_s3_bucket_public_access_block.frontend]
}

resource "aws_s3_object" "index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"

  # The API's invoke_url is baked directly into the page at apply time
  # (see frontend/index.html.tpl's ${api_base_url} placeholder) rather than
  # fetched at runtime from some separate config endpoint -- there's only
  # ever one API per deployment of this project, so a build-time constant
  # is simpler than adding a config-fetch round trip for no real benefit.
  content = templatefile("${var.frontend_dir}/index.html.tpl", {
    api_base_url = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
  })

  etag = md5(templatefile("${var.frontend_dir}/index.html.tpl", {
    api_base_url = trimsuffix(aws_apigatewayv2_stage.default.invoke_url, "/")
  }))
}
