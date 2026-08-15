# ---------------------------------------------------------------------------
# CloudWatch — Phase 4
#
# Two alarms plus one dashboard, deliberately narrow:
#
# Alarms only cover the two Step Functions signals that actually mean
# "something is broken and a human should look" -- ExecutionsFailed and
# ExecutionsTimedOut. Per-Lambda error alarms were considered and dropped:
# every Lambda failure the four pipeline functions can have already surfaces
# as a Step Functions ExecutionsFailed (Retry exhausted -> Catch -> the
# state machine's own Fail state), so a duplicate per-function alarm would
# just double-page on the same underlying incident without adding
# information the state machine's own outcome doesn't already carry.
#
# The dashboard intentionally has NO ECS/Fargate CPU/Memory widget. The
# video-processor task runs via ecs:RunTask (Phase 3), not an ECS Service --
# the AWS/ECS CloudWatch namespace's per-task-run CPU/Memory metrics require
# Container Insights, which bills per-metric on top of the task itself. For
# a learning project already showing per-resolution transcode status via
# DynamoDB (see docs/architecture.md) and full stdout/stderr in the ecs log
# group, that extra recurring cost isn't worth it -- a text widget below
# says so explicitly rather than silently omitting the row.
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "execution_failures" {
  alarm_name        = "${var.name_prefix}-sfn-executions-failed"
  alarm_description = "One or more video pipeline executions failed (either terminal Fail state)."

  namespace   = "AWS/States"
  metric_name = "ExecutionsFailed"
  dimensions = {
    StateMachineArn = var.state_machine_arn
  }

  statistic           = "Sum"
  period              = var.alarm_evaluation_period_seconds
  evaluation_periods  = 1
  threshold           = var.alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}

resource "aws_cloudwatch_metric_alarm" "execution_timeouts" {
  alarm_name        = "${var.name_prefix}-sfn-executions-timed-out"
  alarm_description = "A video pipeline execution hit a state's TimeoutSeconds ceiling (see docs/architecture.md's three-layer timeout model)."

  namespace   = "AWS/States"
  metric_name = "ExecutionsTimedOut"
  dimensions = {
    StateMachineArn = var.state_machine_arn
  }

  statistic           = "Sum"
  period              = var.alarm_evaluation_period_seconds
  evaluation_periods  = 1
  threshold           = var.alarm_threshold
  comparison_operator = "GreaterThanOrEqualToThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.sns_topic_arn]
  ok_actions    = [var.sns_topic_arn]

  tags = var.tags
}

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${var.name_prefix}-video-pipeline"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# ${var.name_prefix} video pipeline\nStep Functions execution health, Lambda invocations/errors, and DynamoDB capacity. **No ECS/Fargate CPU/Memory widget** -- see the comment at the top of terraform/modules/cloudwatch/main.tf for why (Container Insights cost tradeoff)."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions — executions"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionsSucceeded", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsFailed", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsTimedOut", "StateMachineArn", var.state_machine_arn],
            ["AWS/States", "ExecutionsAborted", "StateMachineArn", var.state_machine_arn],
          ]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Step Functions — execution time (ms)"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Average"
          period = 300
          metrics = [
            ["AWS/States", "ExecutionTime", "StateMachineArn", var.state_machine_arn],
          ]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "Lambda — invocations"
          view    = "timeSeries"
          region  = var.aws_region
          stat    = "Sum"
          period  = 300
          metrics = [for fn in var.lambda_function_names : ["AWS/Lambda", "Invocations", "FunctionName", fn]]
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title   = "Lambda — errors"
          view    = "timeSeries"
          region  = var.aws_region
          stat    = "Sum"
          period  = 300
          metrics = [for fn in var.lambda_function_names : ["AWS/Lambda", "Errors", "FunctionName", fn]]
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 14
        width  = 12
        height = 6
        properties = {
          title  = "DynamoDB — consumed capacity"
          view   = "timeSeries"
          region = var.aws_region
          stat   = "Sum"
          period = 300
          metrics = [
            ["AWS/DynamoDB", "ConsumedReadCapacityUnits", "TableName", var.dynamodb_table_name],
            ["AWS/DynamoDB", "ConsumedWriteCapacityUnits", "TableName", var.dynamodb_table_name],
          ]
        }
      },
    ]
  })
}
