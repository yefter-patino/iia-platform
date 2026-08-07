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

variable "common_tags" {
  description = "Tags applied to every resource."
  type        = map(string)
  default = {
    Owner   = "yefter"
    Project = "yefter-iia-platform"
    Purpose = "personal-lab"
  }
}
