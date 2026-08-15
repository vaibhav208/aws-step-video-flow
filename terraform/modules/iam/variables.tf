variable "name_prefix" {
  type = string
}

variable "s3_bucket_arn" {
  description = "ARN of the media bucket. Policies below scope S3 access to this bucket only."
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the VideoProcessingJobs table. Policies below scope DynamoDB access to this table (and its indexes) only."
  type        = string
}

variable "tags" {
  type    = map(string)
  default = {}
}
