variable "project_name" {
  description = <<-EOT
    Short name used as a prefix for all resource names, e.g. S3 bucket names,
    IAM role names, and the DynamoDB table name. Must be lowercase
    letters/numbers/hyphens only — S3 bucket names reject uppercase and most
    other characters, so this is validated below rather than failing deep
    into `terraform apply`.

    The project is branded "AWS-Step-video-Flow" (see README.md); this
    variable holds the lowercase slug ("aws-step-video-flow") that AWS
    resource names are actually built from.
  EOT
  type        = string
  default     = "aws-step-video-flow"

  validation {
    condition     = can(regex("^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$", var.project_name))
    error_message = "project_name must be lowercase letters, numbers, and hyphens only (S3 bucket naming rules), 1-63 chars, and can't start/end with a hyphen."
  }
}

variable "environment" {
  description = "Deployment environment name, e.g. dev, staging, prod. Used in resource naming and tagging."
  type        = string
  default     = "dev"
}

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
  default     = "us-east-1"
}

variable "owner" {
  description = "Person/team responsible for this stack. Used only for tagging."
  type        = string
  default     = "devops-learning"
}

# ---------------------------------------------------------------------------
# S3 (media bucket: uploads/, processed/, thumbnails/, metadata/)
# ---------------------------------------------------------------------------

variable "s3_force_destroy" {
  description = <<-EOT
    If true, `terraform destroy` will delete the bucket even if it still contains
    objects. Convenient for a learning project so you don't have to empty the
    bucket by hand before tearing the stack down. Set to false for anything you
    don't want accidentally wiped.
  EOT
  type        = bool
  default     = true
}

variable "s3_enable_versioning" {
  description = "Enable S3 object versioning on the media bucket (protects against accidental overwrite/delete)."
  type        = bool
  default     = true
}

variable "s3_noncurrent_version_expiration_days" {
  description = "Days after which noncurrent object versions are permanently expired (cost control once versioning is on)."
  type        = number
  default     = 30
}

variable "s3_abort_incomplete_multipart_days" {
  description = "Days after which incomplete multipart uploads are aborted and their storage reclaimed."
  type        = number
  default     = 7
}

variable "s3_enable_cors" {
  description = "Enable a CORS policy on the media bucket (needed later if the API issues browser-facing presigned upload URLs)."
  type        = bool
  default     = true
}

variable "s3_cors_allowed_origins" {
  description = "Allowed origins for the media bucket's CORS policy. Restrict this to your real frontend origin(s) outside of local learning/demo use."
  type        = list(string)
  default     = ["*"]
}

# ---------------------------------------------------------------------------
# DynamoDB
# ---------------------------------------------------------------------------

variable "dynamodb_enable_point_in_time_recovery" {
  description = "Enable point-in-time recovery on the jobs table. Off by default to keep the learning project free-tier friendly; PAY_PER_REQUEST billing already keeps steady-state cost near zero regardless."
  type        = bool
  default     = false
}

# ---------------------------------------------------------------------------
# Networking (Phase 2)
# ---------------------------------------------------------------------------

variable "vpc_cidr" {
  description = "CIDR block for the VPC created for the ECS Fargate video-processor task."
  type        = string
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to spread public subnets across."
  type        = number
  default     = 2
}

# ---------------------------------------------------------------------------
# ECS / Fargate (Phase 2)
# ---------------------------------------------------------------------------

variable "ecs_task_cpu" {
  description = "Fargate task-level vCPU units (1024 = 1 vCPU). FFmpeg transcoding is CPU-bound."
  type        = string
  default     = "1024"
}

variable "ecs_task_memory" {
  description = "Fargate task-level memory in MiB. Must be a valid combination for the chosen cpu."
  type        = string
  default     = "3072"
}

# ---------------------------------------------------------------------------
# Lambda (Phase 2)
# ---------------------------------------------------------------------------

variable "allowed_video_formats" {
  description = "Comma-separated list of file extensions the validate function accepts."
  type        = string
  default     = "mp4,mov,mkv,avi"
}

variable "max_file_size_bytes" {
  description = "Maximum accepted upload size, in bytes, enforced by the validate function."
  type        = number
  default     = 5368709120 # 5 GiB
}

# ---------------------------------------------------------------------------
# Observability (Phase 2+)
# ---------------------------------------------------------------------------

variable "log_retention_days" {
  description = "CloudWatch Logs retention for Lambda, ECS, and Step Functions log groups. Applied everywhere rather than left at the (cost-accumulating) default of 'never expire'."
  type        = number
  default     = 14
}

# ---------------------------------------------------------------------------
# Step Functions (Phase 3)
# ---------------------------------------------------------------------------

variable "ecs_runtask_stagger_seconds" {
  description = <<-EOT
    Seconds the Map state's Wait step pauses before each ecs:RunTask call.
    Spreads out RunTask calls when multiple resolutions transcode
    concurrently (MaxConcurrency in the Map state) so they don't all hit
    the ECS API in the same instant. Purely a request-pacing safeguard on
    top of the Task's own Retry policy for ECS throttling errors.
  EOT
  type        = number
  default     = 3
}

# ---------------------------------------------------------------------------
# SNS / EventBridge / CloudWatch (Phase 4)
# ---------------------------------------------------------------------------

variable "notification_email" {
  description = <<-EOT
    Optional email address subscribed to the Phase 4 SNS notifications topic
    (job success/failure + alarm state changes). Leave as the default "" to
    skip creating a subscription. If set, AWS emails a confirmation link
    that must be clicked before delivery starts.
  EOT
  type        = string
  default     = ""
}

variable "trigger_target_resolutions" {
  description = "Comma-separated resolutions requested by every automatically-triggered execution (S3 upload -> EventBridge -> trigger Lambda -> StartExecution). The manual start-execution path (step-functions/README.md) can still request different resolutions per call via its own input JSON."
  type        = string
  default     = "1080p,720p,480p"
}

variable "sfn_alarm_evaluation_period_seconds" {
  description = "CloudWatch alarm period for the ExecutionsFailed/ExecutionsTimedOut alarms."
  type        = number
  default     = 300
}

variable "sfn_alarm_threshold" {
  description = "Sum of ExecutionsFailed (or ExecutionsTimedOut) within one evaluation period that triggers ALARM state. Default 1 = alert on the first failure, appropriate for this project's low execution volume."
  type        = number
  default     = 1
}
