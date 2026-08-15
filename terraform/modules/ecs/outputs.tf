output "ecr_repository_url" {
  value = aws_ecr_repository.video_processor.repository_url
}

output "ecr_repository_arn" {
  value = aws_ecr_repository.video_processor.arn
}

output "ecr_repository_name" {
  value = aws_ecr_repository.video_processor.name
}

output "ecs_cluster_arn" {
  value = aws_ecs_cluster.main.arn
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.main.name
}

output "task_definition_arn" {
  description = "Full ARN (with revision). Step Functions' RunTask in Phase 3 should reference task_definition_family instead so it always picks up the latest revision."
  value       = aws_ecs_task_definition.video_processor.arn
}

output "task_definition_family" {
  value = aws_ecs_task_definition.video_processor.family
}

output "log_group_name" {
  value = aws_cloudwatch_log_group.video_processor.name
}
