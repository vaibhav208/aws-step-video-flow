output "aws_account_id" {
  description = "AWS account ID Terraform is deploying into (sanity check)."
  value       = data.aws_caller_identity.current.account_id
}

output "aws_region" {
  value = var.aws_region
}

# --- S3 ---------------------------------------------------------------

output "media_bucket_name" {
  description = "Name of the S3 bucket holding uploads/, processed/, thumbnails/, metadata/."
  value       = module.s3.bucket_id
}

output "media_bucket_arn" {
  value = module.s3.bucket_arn
}

# --- DynamoDB -----------------------------------------------------------

output "dynamodb_table_name" {
  description = "Name of the VideoProcessingJobs table."
  value       = module.dynamodb.table_name
}

output "dynamodb_table_arn" {
  value = module.dynamodb.table_arn
}

output "dynamodb_status_index_name" {
  description = "GSI used to query jobs by status (e.g. all PROCESSING or FAILED jobs)."
  value       = module.dynamodb.status_index_name
}

# --- IAM ------------------------------------------------------------------

output "lambda_execution_role_arn" {
  description = "Role Phase 2 Lambda functions will assume."
  value       = module.iam.lambda_execution_role_arn
}

output "ecs_task_role_arn" {
  description = "Role the Phase 2 ECS Fargate video-processor container will assume (application permissions: S3 + logs)."
  value       = module.iam.ecs_task_role_arn
}

output "ecs_task_execution_role_arn" {
  description = "Role ECS itself assumes to pull the container image from ECR and ship logs to CloudWatch (infrastructure permissions, distinct from the task role)."
  value       = module.iam.ecs_task_execution_role_arn
}

# --- Networking (Phase 2) --------------------------------------------------

output "vpc_id" {
  value = module.networking.vpc_id
}

output "public_subnet_ids" {
  description = "Consumed by Phase 3's Step Functions RunTask NetworkConfiguration, not by anything in Phase 2 itself."
  value       = module.networking.public_subnet_ids
}

output "ecs_task_security_group_id" {
  value = module.networking.ecs_task_security_group_id
}

# --- ECS / ECR (Phase 2) ----------------------------------------------------

output "ecr_video_processor_repository_url" {
  description = "Push the video-processor image here with `scripts/build.sh image`."
  value       = module.ecs.ecr_repository_url
}

output "ecs_cluster_name" {
  value = module.ecs.ecs_cluster_name
}

output "ecs_task_definition_family" {
  description = "Reference this (not the versioned ARN) from Step Functions in Phase 3 so RunTask always picks up the latest revision."
  value       = module.ecs.task_definition_family
}

output "ecs_log_group_name" {
  value = module.ecs.log_group_name
}

# --- Lambda (Phase 2) -------------------------------------------------------

output "validate_function_name" {
  value = module.lambda.validate_function_name
}
output "validate_function_arn" {
  value = module.lambda.validate_function_arn
}

output "database_function_name" {
  value = module.lambda.database_function_name
}
output "database_function_arn" {
  value = module.lambda.database_function_arn
}

output "metadata_function_name" {
  value = module.lambda.metadata_function_name
}
output "metadata_function_arn" {
  value = module.lambda.metadata_function_arn
}

output "thumbnail_function_name" {
  value = module.lambda.thumbnail_function_name
}
output "thumbnail_function_arn" {
  value = module.lambda.thumbnail_function_arn
}

output "ecr_lambda_ffmpeg_repository_url" {
  description = "Push the shared metadata/thumbnail image here with `scripts/build.sh lambda-image`."
  value       = module.lambda.lambda_ffmpeg_ecr_repository_url
}

# --- Step Functions (Phase 3) -----------------------------------------------

output "state_machine_arn" {
  description = "Pass this to `aws stepfunctions start-execution` to run the pipeline. See step-functions/README.md for a full example."
  value       = module.step_functions.state_machine_arn
}

output "state_machine_name" {
  value = module.step_functions.state_machine_name
}

output "step_functions_execution_role_arn" {
  value = module.step_functions.step_functions_execution_role_arn
}

output "step_functions_log_group_name" {
  value = module.step_functions.step_functions_log_group_name
}

# --- SNS (Phase 4) -----------------------------------------------------------

output "sns_topic_arn" {
  description = "Subscribe additional endpoints here, or check step-functions/README.md for how job success/failure notifications flow into this topic."
  value       = module.sns.topic_arn
}

output "sns_topic_name" {
  value = module.sns.topic_name
}

# --- EventBridge (Phase 4) ---------------------------------------------------

output "eventbridge_rule_name" {
  description = "Matches S3 Object Created events under uploads/ in the media bucket and invokes the trigger function below."
  value       = module.eventbridge.event_rule_name
}

output "trigger_function_name" {
  description = "Parses the S3 event and calls stepfunctions:StartExecution -- upload a file to test the fully-automatic path instead of the manual one in step-functions/README.md."
  value       = module.eventbridge.trigger_function_name
}

# --- CloudWatch (Phase 4) ----------------------------------------------------

output "cloudwatch_dashboard_name" {
  value = module.cloudwatch.dashboard_name
}

output "cloudwatch_dashboard_url" {
  description = "Direct link to the dashboard in the AWS console."
  value       = "https://${var.aws_region}.console.aws.amazon.com/cloudwatch/home?region=${var.aws_region}#dashboards:name=${module.cloudwatch.dashboard_name}"
}
