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

variable "vpc_extra_tags" {
  description = "Extra tags for the VPC itself. Phase 4 needs for-use-with-amazon-emr-managed-policies here too: a private-subnet EMR cluster makes EMR create its own service VPC endpoint, and that permission is conditioned on the VPC's tags."
  type        = map(string)
  default     = {}
}

variable "private_subnet_extra_tags" {
  description = "Extra tags for the private subnets only. Phase 4 uses this for for-use-with-amazon-emr-managed-policies, which AmazonEMRServicePolicy_v2 requires on the resources EMR touches."
  type        = map(string)
  default     = {}
}

variable "enable_s3_gateway_endpoint" {
  description = "Route S3 traffic from the private subnets through a VPC gateway endpoint instead of the NAT Gateway. Free, and it removes per-GB NAT data charges for S3. No reason to turn this off."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags applied to every resource in this module."
  type        = map(string)
  default     = {}
}
