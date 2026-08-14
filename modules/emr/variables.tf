# ---------------------------------------------------------------------------
# Inputs for the EMR module.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. yefter."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev."
  type        = string
}

variable "vpc_id" {
  description = "VPC the cluster will run in."
  type        = string
}

variable "raw_bucket_arn" {
  description = "ARN of the raw bucket the job reads."
  type        = string
}

variable "curated_bucket_arn" {
  description = "ARN of the curated bucket the job writes Parquet into."
  type        = string
}

variable "logs_bucket_arn" {
  description = "ARN of the bucket EMR writes cluster logs to. Usually the curated or a dedicated logs bucket."
  type        = string
}

variable "enable_ssm_access" {
  description = "Allow Session Manager onto the cluster nodes for debugging a failing job."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
