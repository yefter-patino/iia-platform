# ---------------------------------------------------------------------------
# Inputs for the data lake module.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. yefter."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev. Becomes part of resource names."
  type        = string
}

variable "crawler_schedule" {
  description = "Cron expression for the Glue crawler, e.g. cron(0 6 * * ? *). Null means on-demand only, which is the cheap default -- a forgotten scheduled crawler is the main way this phase leaks money."
  type        = string
  default     = null

  validation {
    condition     = var.crawler_schedule == null || can(regex("^cron\\(.+\\)$", var.crawler_schedule))
    error_message = "crawler_schedule must be null or a Glue cron expression like cron(0 6 * * ? *)."
  }
}

variable "athena_bytes_scanned_cutoff" {
  description = "Cancel any Athena query that would scan more than this many bytes. Default 1 GiB, which at lab volume is generous and still stops a runaway scan."
  type        = number
  default     = 1073741824

  validation {
    condition     = var.athena_bytes_scanned_cutoff >= 10485760
    error_message = "Athena requires the per-query scan limit to be at least 10 MB (10485760 bytes)."
  }
}

variable "athena_results_retention_days" {
  description = "Days before Athena query result files are deleted. They are regenerable by re-running the query."
  type        = number
  default     = 30

  validation {
    condition     = var.athena_results_retention_days >= 1
    error_message = "Retention must be at least 1 day."
  }
}

variable "noncurrent_version_retention_days" {
  description = "Days to keep superseded object versions in the raw and curated buckets before expiring them."
  type        = number
  default     = 30

  validation {
    condition     = var.noncurrent_version_retention_days >= 1
    error_message = "Retention must be at least 1 day."
  }
}

variable "force_destroy_data_buckets" {
  description = "Allow `terraform destroy` to delete the raw and curated buckets while they still hold objects. Off by default: raw data is the one thing in this project that cannot be regenerated."
  type        = bool
  default     = false
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
