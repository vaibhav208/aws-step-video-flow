variable "name_prefix" {
  type = string
}

variable "ecs_task_role_arn" {
  description = "Phase 1 IAM role assumed by the running container (application permissions)."
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "Phase 1 IAM role assumed by the ECS agent to pull the image and ship logs."
  type        = string
}

variable "cpu" {
  description = "Fargate task-level vCPU units (1024 = 1 vCPU). FFmpeg transcoding is CPU-bound, so this is sized higher than a typical microservice task."
  type        = string
  default     = "1024"
}

variable "memory" {
  description = "Fargate task-level memory in MiB. Must be a value valid for the chosen cpu (see AWS Fargate task size table)."
  type        = string
  default     = "3072"
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "container_image" {
  description = <<-EOT
    Full image URI (including tag) the task definition should run. Defaults
    to "<created ECR repo>:latest", which won't exist until you've run
    `scripts/build.sh image` at least once. Terraform will happily create a
    task definition pointing at an image that doesn't exist yet — it just
    means no task will successfully start until you've pushed one.
  EOT
  type        = string
  default     = null
}

variable "task_env_defaults" {
  description = "Default environment variables baked into the task definition. Step Functions overrides these per Map iteration in Phase 3 (job_id, source_key, resolution, etc.); these are just sane defaults for standalone `docker run`/manual `RunTask` testing in Phase 2."
  type        = map(string)
  default     = {}
}

variable "tags" {
  type    = map(string)
  default = {}
}
