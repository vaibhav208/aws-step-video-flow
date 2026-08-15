variable "name_prefix" {
  type = string
}

variable "aws_region" {
  description = "Used only to point dashboard widgets at the right region; alarms/metrics are region-scoped implicitly by the provider."
  type        = string
}

variable "state_machine_arn" {
  type = string
}

variable "sns_topic_arn" {
  description = "Alarm and OK actions both publish here -- an OK action (in addition to ALARM) means the same notification channel also tells you when an incident clears, not just when one starts."
  type        = string
}

variable "lambda_function_names" {
  description = "All Lambda function names to chart on the dashboard (the four pipeline functions plus the Phase 4 trigger function)."
  type        = list(string)
}

variable "dynamodb_table_name" {
  type = string
}

variable "alarm_evaluation_period_seconds" {
  description = "CloudWatch alarm period. 300s (5 min) balances alerting latency against not creating an alarm on a single noisy data point."
  type        = number
  default     = 300
}

variable "alarm_threshold" {
  description = "Sum of ExecutionsFailed / ExecutionsTimedOut within one evaluation period that triggers ALARM state. Default of 1 means 'alert on the first failure' -- appropriate for a learning project's low execution volume; raise this for a high-volume production workload where occasional failures are expected background noise."
  type        = number
  default     = 1
}

variable "tags" {
  type    = map(string)
  default = {}
}
