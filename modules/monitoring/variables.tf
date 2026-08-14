variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "alert_email" {
  description = "Where alarms are emailed. AWS sends a confirmation link that must be clicked, or the subscription stays pending and alarms go nowhere."
  type        = string
  default     = ""
}

variable "raw_bucket_name" {
  description = "Raw bucket, for the storage widget."
  type        = string
}

variable "athena_workgroup_name" {
  description = "Athena workgroup, for the bytes-scanned widget."
  type        = string
}

variable "ecs_cluster_name" {
  description = "ECS cluster to watch. Empty disables the service alarm."
  type        = string
  default     = ""
}

variable "ecs_service_name" {
  description = "ECS service to watch."
  type        = string
  default     = ""
}

variable "log_group_name" {
  description = "Log group to scan for errors. Empty disables the error alarm."
  type        = string
  default     = ""
}

variable "error_threshold" {
  description = "Error log lines in a 5-minute window before alarming."
  type        = number
  default     = 0
}

variable "emr_idle_minutes" {
  description = "How long an EMR cluster may sit idle before alarming. A transient cluster should never reach this."
  type        = number
  default     = 15

  validation {
    condition     = var.emr_idle_minutes >= 5
    error_message = "Must be at least 5 minutes -- the metric is published every 5."
  }
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
