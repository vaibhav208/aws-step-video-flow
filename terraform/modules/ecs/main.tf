# ---------------------------------------------------------------------------
# ECS / Fargate — Phase 2
#
# Creates: an ECR repository for the video-processor image, an ECS cluster,
# a CloudWatch log group, and a Fargate TASK DEFINITION for the FFmpeg
# transcoder. Deliberately no `aws_ecs_service` — this task is invoked
# on-demand by Step Functions' ecs:runTask.sync integration once per Map
# iteration (Phase 3), not run continuously as a long-lived service. A
# service is for "always have N of these running"; a batch job triggered by
# a workflow is exactly what ecs:RunTask (directly, or via Step Functions)
# is for.
# ---------------------------------------------------------------------------

resource "aws_ecr_repository" "video_processor" {
  name                 = "${var.name_prefix}-video-processor"
  image_tag_mutability = "MUTABLE"
  force_delete         = true # learning project: allow `terraform destroy` to remove a non-empty repo

  image_scanning_configuration {
    scan_on_push = true
  }

  tags = var.tags
}

# Cost control: without a lifecycle policy, every image you ever push stays
# in ECR (storage cost) forever. Keep the last 5 tagged images for
# rollback, and expire untagged images (left behind by `docker push` retags
# / failed pushes) after 3 days.
resource "aws_ecr_lifecycle_policy" "video_processor" {
  repository = aws_ecr_repository.video_processor.name

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

resource "aws_ecs_cluster" "main" {
  name = "${var.name_prefix}-cluster"

  # Container Insights adds per-task/cluster CloudWatch metrics beyond the
  # basics, at extra CloudWatch cost. Left off by default for a learning
  # project; flip to "enabled" if you want richer dashboards while you're
  # actively using the stack.
  setting {
    name  = "containerInsights"
    value = "disabled"
  }

  tags = var.tags
}

resource "aws_cloudwatch_log_group" "video_processor" {
  name              = "/ecs/${var.name_prefix}-video-processor"
  retention_in_days = var.log_retention_days

  tags = var.tags
}

locals {
  container_image = coalesce(var.container_image, "${aws_ecr_repository.video_processor.repository_url}:latest")

  container_environment = [
    for k, v in var.task_env_defaults : { name = k, value = v }
  ]
}

resource "aws_ecs_task_definition" "video_processor" {
  family                   = "${var.name_prefix}-video-processor"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.ecs_task_execution_role_arn
  task_role_arn            = var.ecs_task_role_arn

  # Step Functions' ecs:runTask.sync integration (Phase 3) passes real
  # job_id / source_bucket / source_key / resolution / output_bucket values
  # per Map iteration via `overrides.containerOverrides[].environment`, so
  # this container definition only needs placeholder/default env vars for
  # standalone testing right now (see README "Testing Phase 2 independently").
  container_definitions = jsonencode([
    {
      name      = "video-processor"
      image     = local.container_image
      essential = true

      environment = local.container_environment

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.video_processor.name
          "awslogs-region"        = data.aws_region.current.name
          "awslogs-stream-prefix" = "video-processor"
        }
      }
    }
  ])

  tags = var.tags
}

data "aws_region" "current" {}
