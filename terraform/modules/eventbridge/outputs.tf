output "trigger_function_arn" {
  value = aws_lambda_function.trigger.arn
}

output "trigger_function_name" {
  value = aws_lambda_function.trigger.function_name
}

output "event_rule_arn" {
  value = aws_cloudwatch_event_rule.s3_upload.arn
}

output "event_rule_name" {
  value = aws_cloudwatch_event_rule.s3_upload.name
}
