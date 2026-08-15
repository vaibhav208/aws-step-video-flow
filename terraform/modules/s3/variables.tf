variable "name_prefix" {
  description = "Prefix used to build the bucket name, e.g. video-pipeline-dev."
  type        = string
}

variable "account_id" {
  description = "AWS account ID, appended to the bucket name so it is globally unique without a random suffix."
  type        = string
}

variable "force_destroy" {
  type    = bool
  default = false
}

variable "enable_versioning" {
  type    = bool
  default = true
}

variable "noncurrent_version_expiration_days" {
  type    = number
  default = 30
}

variable "abort_incomplete_multipart_days" {
  type    = number
  default = 7
}

variable "enable_cors" {
  type    = bool
  default = true
}

variable "cors_allowed_origins" {
  type    = list(string)
  default = ["*"]
}

variable "tags" {
  type    = map(string)
  default = {}
}
