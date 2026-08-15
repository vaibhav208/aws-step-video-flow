# ---------------------------------------------------------------------------
# IAM — Phase 1
#
# This module creates the identities (roles) for the two compute layers that
# depend only on resources that already exist after Phase 1 (S3 + DynamoDB):
# Lambda functions and the ECS Fargate video processor. The actual Lambda
# functions and ECS task definition are built in Phase 2 and simply
# reference these role ARNs — creating the roles first (with policies scoped
# to real resource ARNs, not wildcards or placeholders) means every policy
# below is genuinely least-privilege from day one instead of "TODO: tighten
# later".
#
# The Step Functions execution role is deliberately NOT created here. Its
# permissions (invoke specific Lambda ARNs, RunTask on a specific ECS task
# definition, Publish to a specific SNS topic, UpdateItem on the jobs table)
# only make sense once those resources exist, so it's built in Phase 3
# alongside the state machine itself. Scoping a role to resources that don't
# exist yet would mean either wildcarding it (violates least privilege) or
# hand-waving ARNs that will change — neither is worth doing here.
#
# Three roles are created:
#   1. lambda_execution       - assumed by every Phase 2 Lambda function
#   2. ecs_task                - assumed BY THE CONTAINER at runtime (the
#                                 FFmpeg app's own AWS permissions)
#   3. ecs_task_execution     - assumed BY ECS ITSELF to pull the image from
#                                 ECR and ship logs to CloudWatch on the
#                                 task's behalf
#
# ecs_task vs ecs_task_execution is a common point of confusion: the task
# role is "what can my application do", the execution role is "what does
# the ECS agent need to do to start my container in the first place". They
# are intentionally separate so the running application never has
# permission to, say, pull other teams' images from ECR.
# ---------------------------------------------------------------------------

# --- Trust policies (who can assume each role) -----------------------------

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "ecs_tasks_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

# =============================================================================
# 1. Lambda execution role
# =============================================================================

resource "aws_iam_role" "lambda_execution" {
  name               = "${var.name_prefix}-lambda-execution"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  tags               = var.tags
}

# Read/write the media bucket. Scoped to GetObject/PutObject/HeadObject on
# objects (not the whole S3 API), plus ListBucket on the bucket itself so
# functions can check for an object's existence/prefix without a wildcard
# "s3:*". Lambdas in this project only ever touch objects, never bucket
# configuration, so no bucket-admin actions (PutBucketPolicy etc.) appear
# here at all.
data "aws_iam_policy_document" "lambda_s3" {
  statement {
    sid       = "ListMediaBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.s3_bucket_arn]
  }

  statement {
    sid = "ReadWriteMediaObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:HeadObject",
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "lambda_s3" {
  name   = "${var.name_prefix}-lambda-s3-access"
  policy = data.aws_iam_policy_document.lambda_s3.json
}

resource "aws_iam_role_policy_attachment" "lambda_s3" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_s3.arn
}

# Read/write job records. Scoped to the specific item-level actions the
# validate/metadata/thumbnail/database Lambdas need, on this table and its
# indexes only — no dynamodb:*, no CreateTable/DeleteTable, no access to any
# other table in the account.
data "aws_iam_policy_document" "lambda_dynamodb" {
  statement {
    sid = "ReadWriteJobItems"
    actions = [
      "dynamodb:GetItem",
      "dynamodb:PutItem",
      "dynamodb:UpdateItem",
      "dynamodb:Query",
    ]
    resources = [
      var.dynamodb_table_arn,
      "${var.dynamodb_table_arn}/index/*",
    ]
  }
}

resource "aws_iam_policy" "lambda_dynamodb" {
  name   = "${var.name_prefix}-lambda-dynamodb-access"
  policy = data.aws_iam_policy_document.lambda_dynamodb.json
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_dynamodb.arn
}

# CloudWatch Logs for the Lambda functions this project will create.
# Scoped by naming convention (${name_prefix}-*) to log groups under
# /aws/lambda/, rather than the AWS-managed AWSLambdaBasicExecutionRole
# policy which allows logging to log groups anywhere in the account.
data "aws_iam_policy_document" "lambda_logs" {
  statement {
    sid = "WriteOwnLogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-*",
      "arn:aws:logs:*:*:log-group:/aws/lambda/${var.name_prefix}-*:*",
    ]
  }
}

resource "aws_iam_policy" "lambda_logs" {
  name   = "${var.name_prefix}-lambda-logs"
  policy = data.aws_iam_policy_document.lambda_logs.json
}

resource "aws_iam_role_policy_attachment" "lambda_logs" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = aws_iam_policy.lambda_logs.arn
}

# =============================================================================
# 2. ECS task role (the FFmpeg application's own permissions)
# =============================================================================

resource "aws_iam_role" "ecs_task" {
  name               = "${var.name_prefix}-ecs-task"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = var.tags
}

# The video processor only ever needs to: list/read the source video under
# uploads/, and write its transcoded output under processed/. It never
# touches DynamoDB directly (the Step Functions "database" Lambda owns job
# state updates, per the architecture's separation of responsibilities), so
# no DynamoDB policy is attached to this role at all.
data "aws_iam_policy_document" "ecs_task_s3" {
  statement {
    sid       = "ListMediaBucket"
    actions   = ["s3:ListBucket"]
    resources = [var.s3_bucket_arn]
  }

  statement {
    sid = "ReadWriteMediaObjects"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
    ]
    resources = ["${var.s3_bucket_arn}/*"]
  }
}

resource "aws_iam_policy" "ecs_task_s3" {
  name   = "${var.name_prefix}-ecs-task-s3-access"
  policy = data.aws_iam_policy_document.ecs_task_s3.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_s3" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task_s3.arn
}

data "aws_iam_policy_document" "ecs_task_logs" {
  statement {
    sid = "WriteOwnLogGroups"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "arn:aws:logs:*:*:log-group:/ecs/${var.name_prefix}-*",
      "arn:aws:logs:*:*:log-group:/ecs/${var.name_prefix}-*:*",
    ]
  }
}

resource "aws_iam_policy" "ecs_task_logs" {
  name   = "${var.name_prefix}-ecs-task-logs"
  policy = data.aws_iam_policy_document.ecs_task_logs.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_logs" {
  role       = aws_iam_role.ecs_task.name
  policy_arn = aws_iam_policy.ecs_task_logs.arn
}

# =============================================================================
# 3. ECS task EXECUTION role (used by the ECS agent, not the application)
# =============================================================================

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.name_prefix}-ecs-task-execution"
  assume_role_policy = data.aws_iam_policy_document.ecs_tasks_assume_role.json
  tags               = var.tags
}

# This is the one place in the project that uses an AWS-managed policy
# rather than a hand-scoped one. AmazonECSTaskExecutionRolePolicy is the
# standard, narrowly-scoped policy AWS publishes specifically for this
# purpose (ECR image pull + CloudWatch Logs delivery on the task's behalf);
# hand-rolling an equivalent buys nothing since it can't be scoped to a
# not-yet-created ECR repository ARN any tighter than this policy already
# scopes it operationally, and using the AWS-maintained version means it
# stays correct as ECS's own requirements evolve.
resource "aws_iam_role_policy_attachment" "ecs_task_execution_managed" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}
