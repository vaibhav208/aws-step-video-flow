locals {
  # Short, consistent prefix used by every module for resource naming, e.g.
  # "video-pipeline-dev". Keeping this in one place means every module names
  # its resources the same way without duplicating the logic.
  name_prefix = "${var.project_name}-${var.environment}"

  common_tags = {
    Project     = var.project_name
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
  }
}

# ---------------------------------------------------------------------------
# Phase 1 modules — foundation resources with no compute dependencies yet.
# ---------------------------------------------------------------------------

module "s3" {
  source = "./modules/s3"

  name_prefix = local.name_prefix
  account_id  = data.aws_caller_identity.current.account_id

  force_destroy                      = var.s3_force_destroy
  enable_versioning                  = var.s3_enable_versioning
  noncurrent_version_expiration_days = var.s3_noncurrent_version_expiration_days
  abort_incomplete_multipart_days    = var.s3_abort_incomplete_multipart_days
  enable_cors                        = var.s3_enable_cors
  cors_allowed_origins               = var.s3_cors_allowed_origins

  tags = local.common_tags
}

module "dynamodb" {
  source = "./modules/dynamodb"

  table_name                    = "${local.name_prefix}-jobs"
  enable_point_in_time_recovery = var.dynamodb_enable_point_in_time_recovery

  tags = local.common_tags
}

module "iam" {
  source = "./modules/iam"

  name_prefix = local.name_prefix

  s3_bucket_arn      = module.s3.bucket_arn
  dynamodb_table_arn = module.dynamodb.table_arn

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 2 modules — networking + compute. ecs and lambda (its image-based
# functions) reference ECR repos that start out EMPTY, so the first-ever
# apply needs the two-step sequence in the README: create the repos, build
# and push images with scripts/build.sh, then apply again for the task
# definition / image-based Lambda functions to succeed.
# ---------------------------------------------------------------------------

module "networking" {
  source = "./modules/networking"

  name_prefix = local.name_prefix
  vpc_cidr    = var.vpc_cidr
  az_count    = var.az_count

  tags = local.common_tags
}

module "ecs" {
  source = "./modules/ecs"

  name_prefix = local.name_prefix

  ecs_task_role_arn           = module.iam.ecs_task_role_arn
  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn

  cpu                = var.ecs_task_cpu
  memory             = var.ecs_task_memory
  log_retention_days = var.log_retention_days

  task_env_defaults = {
    OUTPUT_BUCKET = module.s3.bucket_id
  }

  tags = local.common_tags
}

module "lambda" {
  source = "./modules/lambda"

  name_prefix = local.name_prefix

  lambda_execution_role_arn = module.iam.lambda_execution_role_arn
  media_bucket_name         = module.s3.bucket_id
  dynamodb_table_name       = module.dynamodb.table_name

  allowed_video_formats = var.allowed_video_formats
  max_file_size_bytes   = var.max_file_size_bytes
  log_retention_days    = var.log_retention_days

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 3 module — Step Functions orchestration. The ASL definition lives at
# ../step-functions/state-machine.asl.json.tpl (one directory up from this
# terraform/ root) so it's easy to find and read on its own, outside of any
# Terraform module; templatefile() here is what turns it into the real JSON
# the aws_sfn_state_machine resource gets, substituting in the real ARNs
# from the Phase 2 modules above.
# ---------------------------------------------------------------------------

module "step_functions" {
  source = "./modules/step-functions"

  name_prefix = local.name_prefix

  definition = templatefile("${path.module}/../step-functions/state-machine.asl.json.tpl", {
    validate_function_arn       = module.lambda.validate_function_arn
    database_function_arn       = module.lambda.database_function_arn
    metadata_function_arn       = module.lambda.metadata_function_arn
    thumbnail_function_arn      = module.lambda.thumbnail_function_arn
    ecs_cluster_arn             = module.ecs.ecs_cluster_arn
    ecs_task_definition_family  = module.ecs.task_definition_family
    ecs_task_security_group_id  = module.networking.ecs_task_security_group_id
    public_subnet_ids           = module.networking.public_subnet_ids
    ecs_runtask_stagger_seconds = var.ecs_runtask_stagger_seconds
    sns_topic_arn               = module.sns.topic_arn
  })

  validate_function_arn       = module.lambda.validate_function_arn
  database_function_arn       = module.lambda.database_function_arn
  metadata_function_arn       = module.lambda.metadata_function_arn
  thumbnail_function_arn      = module.lambda.thumbnail_function_arn
  ecs_cluster_arn             = module.ecs.ecs_cluster_arn
  ecs_task_definition_family  = module.ecs.task_definition_family
  ecs_task_role_arn           = module.iam.ecs_task_role_arn
  ecs_task_execution_role_arn = module.iam.ecs_task_execution_role_arn
  sns_topic_arn               = module.sns.topic_arn

  log_retention_days = var.log_retention_days

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 4 modules — notifications, auto-trigger, and observability on top of
# everything Phase 1-3 built. sns is created before step_functions (which
# needs its topic ARN); eventbridge and cloudwatch are created after
# step_functions (which need the state machine's ARN/name).
# ---------------------------------------------------------------------------

module "sns" {
  source = "./modules/sns"

  name_prefix        = local.name_prefix
  notification_email = var.notification_email

  tags = local.common_tags
}

module "eventbridge" {
  source = "./modules/eventbridge"

  name_prefix = local.name_prefix

  media_bucket_name  = module.s3.bucket_id
  media_bucket_arn   = module.s3.bucket_arn
  state_machine_arn  = module.step_functions.state_machine_arn
  target_resolutions = var.trigger_target_resolutions
  log_retention_days = var.log_retention_days

  tags = local.common_tags
}

module "cloudwatch" {
  source = "./modules/cloudwatch"

  name_prefix = local.name_prefix
  aws_region  = var.aws_region

  state_machine_arn = module.step_functions.state_machine_arn
  sns_topic_arn     = module.sns.topic_arn

  lambda_function_names = [
    module.lambda.validate_function_name,
    module.lambda.database_function_name,
    module.lambda.metadata_function_name,
    module.lambda.thumbnail_function_name,
    module.eventbridge.trigger_function_name,
  ]

  dynamodb_table_name = module.dynamodb.table_name

  alarm_evaluation_period_seconds = var.sfn_alarm_evaluation_period_seconds
  alarm_threshold                 = var.sfn_alarm_threshold

  tags = local.common_tags
}

# ---------------------------------------------------------------------------
# Phase 6 module — a small browser frontend + its API Gateway/Lambda
# backend, entirely optional and additive on top of everything above. Same
# "created last" reasoning as eventbridge: needs module.step_functions'
# state_machine_arn, which doesn't exist until Phase 3 has run. See
# terraform/modules/web/main.tf's header comment for the full picture.
# ---------------------------------------------------------------------------

module "web" {
  source = "./modules/web"

  name_prefix = local.name_prefix
  account_id  = data.aws_caller_identity.current.account_id

  media_bucket_name = module.s3.bucket_id
  media_bucket_arn  = module.s3.bucket_arn
  state_machine_arn = module.step_functions.state_machine_arn

  log_retention_days = var.log_retention_days

  tags = local.common_tags
}
