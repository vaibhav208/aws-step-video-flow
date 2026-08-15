output "state_machine_arn" {
  value = aws_sfn_state_machine.video_pipeline.arn
}

output "state_machine_name" {
  value = aws_sfn_state_machine.video_pipeline.name
}

output "step_functions_execution_role_arn" {
  value = aws_iam_role.step_functions_execution.arn
}

output "step_functions_execution_role_name" {
  value = aws_iam_role.step_functions_execution.name
}

output "step_functions_log_group_name" {
  value = aws_cloudwatch_log_group.step_functions.name
}
