# ---------------------------------------------------------------------------
# Inputs for the dev environment.
# ---------------------------------------------------------------------------

variable "aws_region" {
  description = "AWS region to deploy into."
  type        = string
}

variable "aws_profile" {
  description = "Name of the AWS CLI profile to use."
  type        = string
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

variable "common_tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Owner   = "yefter"
    Project = "yefter-iia-platform"
    Purpose = "personal-lab"
  }
}
