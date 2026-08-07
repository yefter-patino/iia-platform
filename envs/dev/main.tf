# ---------------------------------------------------------------------------
# PHASE 1 -- the dev environment.
#
# This file does almost nothing on its own. It just calls the network module
# and passes in the values for this environment. That separation is the point:
# the module says HOW to build a network, this file says WHICH one to build.
# ---------------------------------------------------------------------------

module "network" {
  source = "../../modules/network"

  name_prefix        = var.name_prefix
  environment        = var.environment
  vpc_cidr           = var.vpc_cidr
  az_count           = var.az_count
  enable_nat_gateway = var.enable_nat_gateway

  # One NAT for the whole VPC. In production you would set this to false so
  # each AZ has its own and a single AZ failure cannot cut off the others.
  single_nat_gateway = true

  tags = var.common_tags
}
