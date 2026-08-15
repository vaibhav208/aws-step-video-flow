variable "name_prefix" {
  type = string
}

variable "account_id" {
  description = "Used to make the frontend hosting bucket's name globally unique, same pattern as modules/s3."
  type        = string
}

variable "media_bucket_name" {
  type = string
}

variable "media_bucket_arn" {
  description = "The web_api Lambda's presign permission (s3:PutObject) is scoped to uploads/* under this bucket."
  type        = string
}

variable "state_machine_arn" {
  description = "The web_api Lambda's only Step Functions permissions (DescribeExecution, GetExecutionHistory) are scoped to executions of this state machine."
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

variable "frontend_dir" {
  description = <<-EOT
    Path to the frontend/ directory containing index.html.tpl. Same
    cwd-relative-resolution caveat as src_dir above applies here too.
  EOT
  type        = string
  default     = "../frontend"
}

variable "web_api_timeout_seconds" {
  description = "GetExecutionHistory on a long, retried execution is the slowest call this function makes; 10s is generous margin over the observed case."
  type        = number
  default     = 10
}

variable "web_api_memory_mb" {
  type    = number
  default = 128
}

variable "presigned_url_expiry_seconds" {
  description = "How long the browser has to actually PUT the video file after requesting a presigned upload URL."
  type        = number
  default     = 300
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
