# ---------------------------------------------------------------------------
# Inputs for the network module.
# A module is just a folder of Terraform that you can call more than once.
# Nothing in here knows which account or region it is running in -- that is
# the caller's job. That is what makes it reusable.
# ---------------------------------------------------------------------------

variable "name_prefix" {
  description = "Prefix for every resource name, e.g. yefter."
  type        = string
}

variable "environment" {
  description = "Environment name, e.g. dev. Becomes part of resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the whole VPC, e.g. 10.20.0.0/16."
  type        = string
}

variable "az_count" {
  description = "How many Availability Zones to spread subnets across."
  type        = number
  default     = 2

  validation {
    condition     = var.az_count >= 2 && var.az_count <= 3
    error_message = "az_count must be 2 or 3. Two is enough for this lab."
  }
}

variable "public_subnet_newbits" {
  description = "How many bits to add to the VPC CIDR when carving subnets. 8 turns a /16 into /24s."
  type        = number
  default     = 8
}

variable "enable_nat_gateway" {
  description = "Create a NAT Gateway so private subnets can reach the internet. This is the expensive part -- set to false when you are not using it."
  type        = bool
  default     = true
}

variable "single_nat_gateway" {
  description = "Use one NAT Gateway for all AZs instead of one per AZ. Cheaper, but a single point of failure. True for a lab, false in production."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
