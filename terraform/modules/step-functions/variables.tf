variable "name_prefix" {
  type = string
}

variable "definition" {
  description = "Fully-rendered Amazon States Language JSON (the output of templatefile() over step-functions/state-machine.asl.json.tpl, done in the root module where all the cross-module ARNs are already assembled)."
  type        = string
}

# --- Values the IAM policies below are scoped to ---------------------------

variable "validate_function_arn" {
  type = string
}

variable "database_function_arn" {
  type = string
}

variable "metadata_function_arn" {
  type = string
}

variable "thumbnail_function_arn" {
  type = string
}

variable "ecs_cluster_arn" {
  type = string
}

variable "ecs_task_definition_family" {
  description = "Used to scope the ecs:RunTask IAM permission to this task definition family (all revisions), not to ECS task definitions in general."
  type        = string
}

variable "ecs_task_role_arn" {
  description = "The role ecs:RunTask will pass to the running container. Step Functions' own execution role needs iam:PassRole permission for this ARN, or RunTask fails with an AccessDenied error at the IAM layer before ECS ever sees the request."
  type        = string
}

variable "ecs_task_execution_role_arn" {
  description = "The role ecs:RunTask will pass to the ECS agent (image pull + log delivery). Same iam:PassRole requirement as ecs_task_role_arn above."
  type        = string
}

variable "sns_topic_arn" {
  description = "Phase 4: the NotifySuccess/NotifyValidationFailure/NotifyProcessingFailure states in the ASL definition publish here. Scopes the sns:Publish IAM permission to exactly this topic."
  type        = string
}

variable "log_retention_days" {
  type    = number
  default = 14
}

variable "tags" {
  type    = map(string)
  default = {}
}
