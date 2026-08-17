variable "name_prefix" {
  description = "Prefix for resource names."
  type        = string
}

variable "environment" {
  description = "Environment name."
  type        = string
}

variable "github_repository" {
  description = "owner/name of the repository allowed to assume the role. This is the security boundary -- it must be exact."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Must be owner/name, e.g. yefter-patino/iia-platform."
  }
}

variable "github_owner_id" {
  description = "Numeric GitHub owner ID, from `gh api repos/OWNER/REPO --jq .owner.id`. Required for the immutable sub claim GitHub now issues."
  type        = string
  default     = ""
}

variable "github_repository_id" {
  description = "Numeric GitHub repository ID, from `gh api repos/OWNER/REPO --jq .id`."
  type        = string
  default     = ""
}

variable "allowed_branches" {
  description = "Branches whose workflow runs may assume the role."
  type        = list(string)
  default     = ["main"]
}

variable "allow_pull_requests" {
  description = "Let pull request runs assume the role, which is what makes plan-on-PR work. Safe only because this role cannot apply."
  type        = bool
  default     = true
}

variable "create_oidc_provider" {
  description = "Create the GitHub OIDC provider. Only one per account can exist for a given URL, so set false if another workload already registered it."
  type        = bool
  default     = true
}

variable "existing_oidc_provider_arn" {
  description = "ARN of an already-registered GitHub OIDC provider, used when create_oidc_provider is false."
  type        = string
  default     = ""
}

variable "thumbprints" {
  description = "Certificate thumbprints for GitHub's OIDC endpoint. AWS now verifies against its own trust store for this provider, so these are largely vestigial, but the API still requires a value."
  type        = list(string)
  default     = ["6938fd4d98bab03faadb97b34396831e3780aea1"]
}

variable "state_bucket_arn" {
  description = "Terraform state bucket, so CI can read state to plan."
  type        = string
}

variable "ecr_repository_arn" {
  description = "The one ECR repository CI may push to."
  type        = string
}

variable "tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default     = {}
}
