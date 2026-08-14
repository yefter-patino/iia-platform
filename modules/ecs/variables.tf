# ---------------------------------------------------------------------------
# Inputs for the ECS module.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC the service runs in."
  type        = string
}

variable "private_subnet_ids" {
  description = "Private subnets for the Fargate task ENIs."
  type        = list(string)
}

variable "image_uri" {
  description = "Full ECR image URI including tag."
  type        = string
}

variable "desired_count" {
  description = "Number of tasks to run. 0 keeps the service defined but stops all billing -- this is the lab's off switch."
  type        = number
  default     = 0

  validation {
    condition     = var.desired_count >= 0 && var.desired_count <= 4
    error_message = "desired_count must be between 0 and 4 for this lab."
  }
}

variable "task_cpu" {
  description = "Fargate CPU units. 256 = 0.25 vCPU, the smallest Fargate offers."
  type        = string
  default     = "256"
}

variable "task_memory" {
  description = "Fargate memory in MiB. 512 is the minimum valid pairing with 256 CPU units."
  type        = string
  default     = "512"
}

variable "cpu_architecture" {
  description = "X86_64 or ARM64. Must match what the image was built for, or the task fails at runtime with an exec format error."
  type        = string
  default     = "ARM64"

  validation {
    condition     = contains(["X86_64", "ARM64"], var.cpu_architecture)
    error_message = "cpu_architecture must be X86_64 or ARM64."
  }
}

variable "enable_execute_command" {
  description = "Allow `aws ecs execute-command` to open a shell in the task. Requires ssmmessages permissions on the TASK role, which this module adds when enabled."
  type        = bool
  default     = true
}

variable "log_retention_days" {
  description = "CloudWatch log retention. Logs kept forever are a slow, quiet bill."
  type        = number
  default     = 14
}

variable "enable_container_insights" {
  description = "Container Insights gives per-task CPU and memory metrics, and costs extra per metric. Off by default for a lab."
  type        = bool
  default     = false
}

# --- Things the task needs access to ----------------------------------------

variable "raw_bucket_name" {
  type        = string
  description = "Raw bucket name, passed to the container as an env var."
}

variable "raw_bucket_arn" {
  type        = string
  description = "Raw bucket ARN, for the task policy."
}

variable "curated_bucket_name" {
  type        = string
  description = "Curated bucket name."
}

variable "curated_bucket_arn" {
  type        = string
  description = "Curated bucket ARN."
}

variable "athena_results_bucket_arn" {
  type        = string
  description = "Athena results bucket ARN. The task needs write access here even though the API is read-only."
}

variable "athena_workgroup_name" {
  type        = string
  description = "Athena workgroup name."
}

variable "athena_workgroup_arn" {
  type        = string
  description = "Athena workgroup ARN, so query permissions name one workgroup rather than all."
}

variable "glue_database_name" {
  type        = string
  description = "Glue catalog database."
}

variable "secret_name" {
  type        = string
  description = "Application secret name."
}

variable "secret_arn" {
  type        = string
  description = "Application secret ARN, for the task policy."
}

variable "kms_key_arn" {
  type        = string
  description = "KMS key that encrypts the secret."
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
