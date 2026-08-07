# ---------------------------------------------------------------------------
# Inputs for the bootstrap stack.
# Every value below is supplied at run time (terraform.tfvars) so that no
# account ID, region, email address or bucket name is written into the code.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region where the state bucket is created."
  type        = string
}

variable "aws_profile" {
  description = "Name of the AWS CLI profile to use (from ~/.aws/credentials)."
  type        = string
}

variable "name_prefix" {
  description = "Prefix put in front of every resource name. Keep this as yefter."
  type        = string
  default     = "yefter"
}

variable "budget_alert_email" {
  description = "Email address that receives the AWS budget alerts."
  type        = string
}

variable "monthly_budget_usd" {
  description = "Monthly spend limit in US dollars. The lab safety net."
  type        = number
  default     = 10
}

variable "budget_actual_threshold_percent" {
  description = "Send an alert once actual spend passes this percent of the budget."
  type        = number
  default     = 50
}

variable "budget_forecast_threshold_percent" {
  description = "Send an alert once forecast spend passes this percent of the budget."
  type        = number
  default     = 100
}

variable "common_tags" {
  description = "Tags applied to every resource this stack creates."
  type        = map(string)
  default = {
    Owner   = "yefter"
    Project = "yefter-iia-platform"
    Purpose = "personal-lab"
  }
}
