# ---------------------------------------------------------------------------
# Lambda — Phase 2
#
# Four functions, two deployment mechanisms — see src/lambda/README.md for
# the full explanation of why. Zip-based functions (validate, database) are
# self-contained: `archive_file` zips the source directory at plan/apply
# time, so `terraform apply` alone is enough to deploy or update them.
# Image-based functions (metadata, thumbnail) depend on an image already
# sitting in the ECR repo this module creates — that repo starts empty, so
# the very first apply needs the two-step sequence documented in the root
# README ("terraform apply -target=...ecr_repository..." → build & push →
# "terraform apply" again).
#
# Every function gets its OWN CloudWatch log group, created explicitly with
# a retention policy, rather than letting Lambda auto-create one on first
# invocation. Auto-created log groups default to "Never expire", which
# quietly accumulates cost forever; pre-creating them here means retention
# is enforced from the very first invocation, not just after you notice and
# fix it later.
# ---------------------------------------------------------------------------

# =============================================================================
# Zip-based functions: validate, database
# =============================================================================

data "archive_file" "validate" {
  type        = "zip"
  source_dir  = "${var.src_dir}/validate"
  output_path = "${path.module}/build/validate.zip"
}

data "archive_file" "database" {
  type        = "zip"
  source_dir  = "${var.src_dir}/database"
  output_path = "${path.module}/build/database.zip"
}

resource "aws_cloudwatch_log_group" "validate" {
  name              = "/aws/lambda/${var.name_prefix}-validate"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "validate" {
  function_name = "${var.name_prefix}-validate"
  role          = var.lambda_execution_role_arn

  filename         = data.archive_file.validate.output_path
  source_code_hash = data.archive_file.validate.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"

  timeout     = var.validate_timeout_seconds
  memory_size = var.validate_memory_mb

  environment {
    variables = {
      ALLOWED_FORMATS     = var.allowed_video_formats
      MAX_FILE_SIZE_BYTES = tostring(var.max_file_size_bytes)
    }
  }

  depends_on = [aws_cloudwatch_log_group.validate]
  tags       = var.tags
}

resource "aws_cloudwatch_log_group" "database" {
  name              = "/aws/lambda/${var.name_prefix}-database"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "database" {
  function_name = "${var.name_prefix}-database"
  role          = var.lambda_execution_role_arn

  filename         = data.archive_file.database.output_path
  source_code_hash = data.archive_file.database.output_base64sha256
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"

  timeout     = var.database_timeout_seconds
  memory_size = var.database_memory_mb

  environment {
    variables = {
      TABLE_NAME = var.dynamodb_table_name
    }
  }

  depends_on = [aws_cloudwatch_log_group.database]
  tags       = var.tags
}

# =============================================================================
# Container-image functions: metadata, thumbnail (share one image)
# =============================================================================

resource "aws_ecr_repository" "lambda_ffmpeg" {
  name                 = "${var.name_prefix}-lambda-ffmpeg"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

resource "aws_ecr_lifecycle_policy" "lambda_ffmpeg" {
  repository = aws_ecr_repository.lambda_ffmpeg.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 3 days"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 3
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Keep only the last 5 tagged images"
        selection = {
          tagStatus     = "tagged"
          tagPrefixList = ["v", "latest"]
          countType     = "imageCountMoreThan"
          countNumber   = 5
        }
        action = { type = "expire" }
      }
    ]
  })
}

locals {
  ffmpeg_image_uri = coalesce(var.ffmpeg_image_uri, "${aws_ecr_repository.lambda_ffmpeg.repository_url}:latest")
}

resource "aws_cloudwatch_log_group" "metadata" {
  name              = "/aws/lambda/${var.name_prefix}-metadata"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "metadata" {
  function_name = "${var.name_prefix}-metadata"
  role          = var.lambda_execution_role_arn
  package_type  = "Image"
  image_uri     = local.ffmpeg_image_uri

  image_config {
    command = ["metadata_handler.lambda_handler"]
  }

  timeout     = var.metadata_timeout_seconds
  memory_size = var.metadata_memory_mb

  depends_on = [aws_cloudwatch_log_group.metadata]
  tags       = var.tags
}

resource "aws_cloudwatch_log_group" "thumbnail" {
  name              = "/aws/lambda/${var.name_prefix}-thumbnail"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_lambda_function" "thumbnail" {
  function_name = "${var.name_prefix}-thumbnail"
  role          = var.lambda_execution_role_arn
  package_type  = "Image"
  image_uri     = local.ffmpeg_image_uri

  image_config {
    command = ["thumbnail_handler.lambda_handler"]
  }

  timeout     = var.thumbnail_timeout_seconds
  memory_size = var.thumbnail_memory_mb

  depends_on = [aws_cloudwatch_log_group.thumbnail]
  tags       = var.tags
}
