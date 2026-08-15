variable "name_prefix" {
  type = string
}

variable "notification_email" {
  description = <<-EOT
    Optional email address to subscribe to the notifications topic. Leave as
    the default "" to create the topic with no subscription (still usable —
    e.g. subscribe an SQS queue or another endpoint by hand, or add a
    subscription resource later). If set, AWS emails a confirmation link to
    this address that must be clicked before delivery starts; Terraform
    cannot complete that step for you.
  EOT
  type        = string
  default     = ""
}

variable "tags" {
  type    = map(string)
  default = {}
}
