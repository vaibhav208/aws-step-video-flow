# ---------------------------------------------------------------------------
# Step Functions — Phase 3
#
# This module creates the Standard Workflow state machine (definition
# rendered in the root module and passed in via var.definition) plus its
# dedicated IAM execution role. That role is deliberately NOT part of the
# Phase 1 iam module — see the comment at the top of modules/iam/main.tf —
# because every policy below is scoped to real ARNs (the four Lambda
# functions, the ECS cluster + task definition family, the two ECS roles
# ecs:RunTask needs to pass) that didn't exist until Phase 2. Scoping to
# real resources from the start means there is never a "TODO: tighten this
# wildcard later" left in the project.
#
# Four permission groups, each with its own policy document so the "why" is
# easy to find later:
#   1. lambda_invoke   - InvokeFunction on exactly the four Lambda ARNs used
#                         by the state machine (validate/database/metadata/
#                         thumbnail) - no other Lambda in the account.
#   2. ecs_run_task     - RunTask scoped to the video-processor task
#                         definition family; DescribeTasks/StopTask (needed
#                         by the .sync integration to poll and, on timeout,
#                         cancel the task) plus the PassRole + EventBridge
#                         permissions that AWS's own docs require for the
#                         ecs:runTask.sync "Run a Job (.sync)" pattern.
#   3. sns_publish      - Publish scoped to exactly the Phase 4 notifications
#                         topic, used by the NotifySuccess/
#                         NotifyValidationFailure/NotifyProcessingFailure
#                         states.
#   4. logging          - Lets Step Functions deliver CloudWatch Logs for
#                         this state machine (Standard Workflow execution
#                         history logging - IAM here uses the log-delivery
#                         API, which AWS does not support scoping beyond
#                         resource "*"; see comment on that policy below).
# ---------------------------------------------------------------------------

data "aws_iam_policy_document" "step_functions_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["states.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "step_functions_execution" {
  name               = "${var.name_prefix}-step-functions-execution"
  assume_role_policy = data.aws_iam_policy_document.step_functions_assume_role.json
  tags               = var.tags
}

# =============================================================================
# 1. Invoke the four Lambda functions this state machine calls
# =============================================================================

data "aws_iam_policy_document" "lambda_invoke" {
  statement {
    sid     = "InvokePipelineLambdas"
    actions = ["lambda:InvokeFunction"]
    resources = [
      var.validate_function_arn,
      var.database_function_arn,
      var.metadata_function_arn,
      var.thumbnail_function_arn,
    ]
  }
}

resource "aws_iam_policy" "lambda_invoke" {
  name   = "${var.name_prefix}-sfn-lambda-invoke"
  policy = data.aws_iam_policy_document.lambda_invoke.json
}

resource "aws_iam_role_policy_attachment" "lambda_invoke" {
  role       = aws_iam_role.step_functions_execution.name
  policy_arn = aws_iam_policy.lambda_invoke.arn
}

# =============================================================================
# 2. Run the video-processor Fargate task (ecs:runTask.sync)
# =============================================================================

# ecs:RunTask itself IS scopable to a specific task definition family (all
# revisions, via the trailing ":*"). DescribeTasks/StopTask are needed by
# the .sync integration to poll for completion and, on TimeoutSeconds
# expiry, cancel a runaway task -- AWS does not support scoping either
# action to specific task ARNs (they don't exist yet when the policy is
# evaluated), so they're scoped as tightly as AWS allows: to this cluster,
# via a resource-tag-free ecs:cluster condition key.
data "aws_iam_policy_document" "ecs_run_task" {
  statement {
    sid       = "RunVideoProcessorTask"
    actions   = ["ecs:RunTask"]
    resources = ["arn:aws:ecs:*:*:task-definition/${var.ecs_task_definition_family}:*"]
  }

  statement {
    sid       = "TrackAndCancelTasksInThisCluster"
    actions   = ["ecs:DescribeTasks", "ecs:StopTask"]
    resources = ["*"]
    condition {
      test     = "ArnEquals"
      variable = "ecs:cluster"
      values   = [var.ecs_cluster_arn]
    }
  }

  # ecs:RunTask passes both the task role (application permissions) and the
  # task execution role (image pull + log delivery) to ECS on the state
  # machine's behalf. Without this, RunTask fails at the IAM layer with
  # "not authorized to perform: iam:PassRole" before ECS is even called.
  # The iam:PassedToService condition means this role can ONLY pass these
  # two ARNs to the ECS service, not to anything else.
  statement {
    sid     = "PassEcsRolesToEcs"
    actions = ["iam:PassRole"]
    resources = [
      var.ecs_task_role_arn,
      var.ecs_task_execution_role_arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  # The ecs:runTask.sync integration works by having Step Functions create
  # a managed EventBridge rule that watches for this task's completion
  # event, rather than polling the ECS API directly. This is AWS's own
  # documented permission requirement for that pattern, scoped to the
  # specific managed rule name AWS creates for it.
  statement {
    sid     = "ManageEcsTaskCompletionRule"
    actions = ["events:PutTargets", "events:PutRule", "events:DescribeRule"]
    resources = [
      "arn:aws:events:*:*:rule/StepFunctionsGetEventsForECSTaskRule",
    ]
  }
}

resource "aws_iam_policy" "ecs_run_task" {
  name   = "${var.name_prefix}-sfn-ecs-run-task"
  policy = data.aws_iam_policy_document.ecs_run_task.json
}

resource "aws_iam_role_policy_attachment" "ecs_run_task" {
  role       = aws_iam_role.step_functions_execution.name
  policy_arn = aws_iam_policy.ecs_run_task.arn
}

# =============================================================================
# 3. Publish notifications (Phase 4)
# =============================================================================

data "aws_iam_policy_document" "sns_publish" {
  statement {
    sid       = "PublishPipelineNotifications"
    actions   = ["sns:Publish"]
    resources = [var.sns_topic_arn]
  }
}

resource "aws_iam_policy" "sns_publish" {
  name   = "${var.name_prefix}-sfn-sns-publish"
  policy = data.aws_iam_policy_document.sns_publish.json
}

resource "aws_iam_role_policy_attachment" "sns_publish" {
  role       = aws_iam_role.step_functions_execution.name
  policy_arn = aws_iam_policy.sns_publish.arn
}

# =============================================================================
# 4. CloudWatch Logs delivery for the state machine's own execution history
# =============================================================================

# Step Functions' log delivery uses a distinct "log delivery" IAM API
# (logs:CreateLogDelivery etc.) rather than the ordinary
# logs:CreateLogStream/PutLogEvents actions Lambda/ECS use above. AWS's own
# documentation for this integration specifies resource "*" for every
# action in this statement -- these are account-level log-delivery-channel
# management calls, not per-log-group writes, so they cannot be scoped down
# to a single log group ARN the way modules/iam/main.tf scopes Lambda/ECS
# logging.
data "aws_iam_policy_document" "logging" {
  statement {
    sid = "StepFunctionsLogDelivery"
    actions = [
      "logs:CreateLogDelivery",
      "logs:GetLogDelivery",
      "logs:UpdateLogDelivery",
      "logs:DeleteLogDelivery",
      "logs:ListLogDeliveries",
      "logs:PutResourcePolicy",
      "logs:DescribeResourcePolicies",
      "logs:DescribeLogGroups",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "logging" {
  name   = "${var.name_prefix}-sfn-logging"
  policy = data.aws_iam_policy_document.logging.json
}

resource "aws_iam_role_policy_attachment" "logging" {
  role       = aws_iam_role.step_functions_execution.name
  policy_arn = aws_iam_policy.logging.arn
}

# =============================================================================
# The state machine itself
# =============================================================================

resource "aws_cloudwatch_log_group" "step_functions" {
  # The "/aws/vendedlogs/states/" prefix is an AWS convention (not a hard
  # requirement) for log groups that receive Step Functions' vended
  # execution-history logs, used here purely so the log group is easy to
  # find/recognize in the CloudWatch console.
  name              = "/aws/vendedlogs/states/${var.name_prefix}-video-pipeline"
  retention_in_days = var.log_retention_days
  tags              = var.tags
}

resource "aws_sfn_state_machine" "video_pipeline" {
  name     = "${var.name_prefix}-video-pipeline"
  role_arn = aws_iam_role.step_functions_execution.arn
  type     = "STANDARD"

  definition = var.definition

  # ALL + include_execution_data gives full input/output visibility per
  # state while learning/debugging. For a real production workload with
  # sensitive payloads you'd likely set include_execution_data = false
  # and/or level = "ERROR" to reduce both log volume/cost and the chance of
  # sensitive data landing in CloudWatch Logs.
  logging_configuration {
    log_destination        = "${aws_cloudwatch_log_group.step_functions.arn}:*"
    include_execution_data = true
    level                  = "ALL"
  }

  # X-Ray tracing is off by default -- it adds a small per-request cost and
  # isn't needed to understand this state machine's behavior (CloudWatch
  # Logs above plus the Step Functions console's own execution graph
  # already show exactly which state ran, with what input/output, and why
  # any Catch/Retry fired). Flip to true if you want request tracing across
  # the Lambda/ECS calls this state machine makes.
  tracing_configuration {
    enabled = false
  }

  tags = var.tags

  depends_on = [
    aws_iam_role_policy_attachment.lambda_invoke,
    aws_iam_role_policy_attachment.ecs_run_task,
    aws_iam_role_policy_attachment.sns_publish,
    aws_iam_role_policy_attachment.logging,
  ]
}
