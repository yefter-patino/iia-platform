# ---------------------------------------------------------------------------
# Inputs for the dev environment.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "aws_profile" {
  description = "AWS CLI profile to use. Empty means fall back to the default credential chain, which is what CI needs."
  type        = string
  default     = ""
}

variable "name_prefix" {
  description = "Prefix for every resource name."
  type        = string
  default     = "yefter"
}

variable "environment" {
  description = "Environment name."
  type        = string
  default     = "dev"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
  default     = "10.20.0.0/16"
}

variable "az_count" {
  description = "Number of Availability Zones to use."
  type        = number
  default     = 2
}

variable "enable_nat_gateway" {
  description = "Set to false to destroy just the NAT Gateway and stop the hourly charge."
  type        = bool
  default     = true
}

variable "secret_name" {
  description = "Last path segment of the application secret. Full name becomes <name_prefix>/<environment>/<secret_name>."
  type        = string
  default     = "app"
}

variable "trusted_services" {
  description = "AWS service principals allowed to assume the secret-reader role."
  type        = list(string)
  default     = ["ec2.amazonaws.com"]
}

variable "crawler_schedule" {
  description = "Cron for the Glue crawler. Null means on-demand only, which is the cheap default."
  type        = string
  default     = null
}

variable "athena_bytes_scanned_cutoff" {
  description = "Cancel any Athena query scanning more than this many bytes. Default 1 GiB."
  type        = number
  default     = 1073741824
}

variable "api_image_uri" {
  description = "Full image URI to run. Empty means build it from the ECR repo URL and api_image_tag."
  type        = string
  default     = ""
}

variable "api_image_tag" {
  description = "Tag to deploy from the ECR repository. Immutable tags mean this is a real version, not a moving target."
  type        = string
  default     = "latest"
}

variable "api_desired_count" {
  description = "Tasks to run. 0 keeps the service defined and stops all Fargate billing."
  type        = number
  default     = 0
}

variable "api_cpu_architecture" {
  description = "Must match the image. ARM64 when built on Apple silicon without cross-compiling."
  type        = string
  default     = "ARM64"
}

variable "github_repository" {
  description = "owner/name of the repo allowed to assume the CI role. This is the OIDC security boundary."
  type        = string
  default     = "yefter-patino/iia-platform"
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID. GitHub's immutable sub claim embeds it."
  type        = string
  default     = "276095800"
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID."
  type        = string
  default     = "1329850140"
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. False when the account already has one -- only one per URL is allowed, and this account is shared."
  type        = bool
  default     = false
}

variable "existing_oidc_provider_arn" {
  description = "ARN of the existing GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = "arn:aws:iam::866934333672:oidc-provider/token.actions.githubusercontent.com"
}

variable "state_bucket_name" {
  description = "Terraform state bucket, so CI can be granted read access to it. Same value as in backend.hcl."
  type        = string
  default     = ""
}

variable "alert_email" {
  description = "Where CloudWatch alarms are emailed. AWS sends a confirmation link that must be clicked."
  type        = string
  default     = ""
}

variable "partner_account_id" {
  description = "Account allowed to assume the cross-account reader. Empty means a same-account simulation."
  type        = string
  default     = ""
}

variable "cross_account_external_id" {
  description = "ExternalId the caller must present. Defeats the confused-deputy problem."
  type        = string
  default     = "yefter-iia-lab"
}

variable "common_tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Owner   = "yefter"
    Project = "yefter-iia-platform"
    Purpose = "personal-lab"
  }
}
