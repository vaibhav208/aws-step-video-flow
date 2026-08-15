variable "name_prefix" {
  type = string
}

variable "media_bucket_name" {
  description = "Used to scope the EventBridge rule's event pattern to this bucket only."
  type        = string
}

variable "media_bucket_arn" {
  description = "The trigger Lambda's HeadObject permission (used to read a per-upload resolution choice set by web_api's /presign, see src/lambda/trigger/handler.py) is scoped to uploads/* under this bucket."
  type        = string
}

variable "state_machine_arn" {
  description = "The trigger Lambda's only AWS permission (states:StartExecution) is scoped to exactly this ARN."
  type        = string
}

variable "src_dir" {
  description = <<-EOT
    Path to src/lambda. NOT relative to this module's own directory --
    Terraform (via the archive provider) resolves plain relative-path
    strings like this one against the process's current working directory
    at invocation time, not against path.module. Every documented command
    in this project runs terraform from inside terraform/ (`cd terraform
    && terraform apply`), so this default is relative to THAT directory:
    one level up (terraform/ -> project root) then into src/lambda. If you
    ever invoke terraform from a different working directory (e.g. via
    `terraform -chdir=terraform ...` from the project root), override this
    variable accordingly -- it will NOT auto-adjust.
  EOT
  type        = string
  default     = "../src/lambda"
}

variable "target_resolutions" {
  description = "Comma-separated resolutions requested for every auto-triggered execution (the manual start-execution path in step-functions/README.md can request different resolutions per call; this is the default for real S3 uploads)."
  type        = string
  default     = "1080p,720p,480p"
}

variable "trigger_timeout_seconds" {
  description = "This function does one StartExecution API call and returns -- fast, but a little slack over the observed p99 for that single SDK call."
  type        = number
  default     = 10
}

variable "trigger_memory_mb" {
  type    = number
  default = 128
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
