# ---------------------------------------------------------------------------
# Inputs for the IAM / secrets module.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. yefter."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev. Becomes part of resource names."
  type        = string
}

variable "secret_name" {
  description = "Last path segment of the secret name. The full name becomes <name_prefix>/<environment>/<secret_name>."
  type        = string
  default     = "app"
}

variable "trusted_services" {
  description = "AWS service principals allowed to assume the secret-reader role. EC2 today; add ecs-tasks.amazonaws.com in Phase 6."
  type        = list(string)
  default     = ["ec2.amazonaws.com"]

  validation {
    condition     = length(var.trusted_services) > 0
    error_message = "At least one trusted service principal is required, or the role can never be assumed."
  }
}

variable "enable_key_rotation" {
  description = "Rotate the KMS key material annually. Leave on."
  type        = bool
  default     = true
}

variable "kms_deletion_window_in_days" {
  description = "Waiting period before a scheduled KMS key deletion completes. 7 is the minimum AWS allows."
  type        = number
  default     = 7

  validation {
    condition     = var.kms_deletion_window_in_days >= 7 && var.kms_deletion_window_in_days <= 30
    error_message = "AWS requires the KMS deletion window to be between 7 and 30 days."
  }
}

variable "secret_recovery_window_in_days" {
  description = "Days a deleted secret stays recoverable. 0 deletes immediately, which is convenient for a lab and dangerous anywhere else."
  type        = number
  default     = 7

  validation {
    condition     = var.secret_recovery_window_in_days == 0 || (var.secret_recovery_window_in_days >= 7 && var.secret_recovery_window_in_days <= 30)
    error_message = "Secret recovery window must be 0, or between 7 and 30 days."
  }
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
