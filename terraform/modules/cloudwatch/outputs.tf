output "dashboard_name" {
  value = aws_cloudwatch_dashboard.main.dashboard_name
}

output "execution_failures_alarm_arn" {
  value = aws_cloudwatch_metric_alarm.execution_failures.arn
}

output "execution_timeouts_alarm_arn" {
  value = aws_cloudwatch_metric_alarm.execution_timeouts.arn
}
