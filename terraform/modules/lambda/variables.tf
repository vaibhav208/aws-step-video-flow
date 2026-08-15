variable "name_prefix" {
  type = string
}

variable "lambda_execution_role_arn" {
  description = "Phase 1 IAM role every function in this module assumes."
  type        = string
}

variable "media_bucket_name" {
  type = string
}

variable "dynamodb_table_name" {
  type = string
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

variable "ffmpeg_image_uri" {
  description = <<-EOT
    Full image URI (with tag) for the shared metadata/thumbnail container
    image. Defaults to "<the ECR repo this module creates>:latest", which
    won't exist until `scripts/build.sh lambda-image` has been run at least
    once — see the two-step apply sequence in the root README's Phase 2
    section.
  EOT
  type        = string
  default     = null
}

variable "allowed_video_formats" {
  type    = string
  default = "mp4,mov,mkv,avi"
}

variable "max_file_size_bytes" {
  type    = number
  default = 5368709120 # 5 GiB
}

# --- Per-function timeout/memory ------------------------------------------
#
# Explained in docs/architecture.md, but briefly: these are sized to what
# each function actually does. validate/database do a single S3 HeadObject
# or DynamoDB call — a few hundred ms, generous margin at 10s. metadata
# reads container headers over a presigned URL — fast, but network-bound,
# so more margin than validate. thumbnail decodes real video frames —
# the most CPU/memory-hungry of the four, hence the higher memory (more
# memory also means a bigger vCPU allocation on Lambda, which speeds up the
# ffmpeg decode).

variable "validate_timeout_seconds" {
  type    = number
  default = 10
}
variable "validate_memory_mb" {
  type    = number
  default = 128
}

variable "database_timeout_seconds" {
  type    = number
  default = 10
}
variable "database_memory_mb" {
  type    = number
  default = 128
}

variable "metadata_timeout_seconds" {
  type    = number
  default = 30
}
variable "metadata_memory_mb" {
  type    = number
  default = 512
}

variable "thumbnail_timeout_seconds" {
  type    = number
  default = 30
}
variable "thumbnail_memory_mb" {
  type    = number
  default = 1024
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
