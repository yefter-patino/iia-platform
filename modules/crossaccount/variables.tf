variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "trusted_account_id" {
  description = "Account ID allowed to assume the role. Empty means this account, which makes it a same-account simulation of the cross-account pattern."
  type        = string
  default     = ""

  validation {
    condition     = var.trusted_account_id == "" || can(regex("^[0-9]{12}$", var.trusted_account_id))
    error_message = "Must be empty or a 12-digit AWS account ID."
  }
}

variable "external_id" {
  description = "Shared value the caller must present. Defeats the confused-deputy problem. Not a password -- it disambiguates who asked."
  type        = string
  default     = ""
}

variable "require_mfa" {
  description = "Require the assuming principal to have authenticated with MFA. Off by default because automation cannot present a token."
  type        = bool
  default     = false
}

variable "max_session_duration" {
  description = "Seconds a session lasts. Shorter means a leaked token is worth less."
  type        = number
  default     = 3600

  validation {
    condition     = var.max_session_duration >= 900 && var.max_session_duration <= 43200
    error_message = "AWS allows between 900 and 43200 seconds."
  }
}

variable "curated_bucket_arn" {
  description = "The one bucket the remote reader may read."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
