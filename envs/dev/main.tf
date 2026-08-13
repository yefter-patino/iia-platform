# ---------------------------------------------------------------------------
# The dev environment.
#
# This file does almost nothing on its own. It just calls the modules and
# passes in the values for this environment. That separation is the point:
# a module says HOW to build a thing, this file says WHICH one to build.
# ---------------------------------------------------------------------------

# --- Phase 1: the network ---------------------------------------------------

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

# --- Phase 2: identity and secrets ------------------------------------------

module "iam" {
  source = "../../modules/iam"

  name_prefix = var.name_prefix
  environment = var.environment
  secret_name = var.secret_name

  # EC2 only for now. Phase 6 adds ecs-tasks.amazonaws.com so the FastAPI
  # task can read the same secret through the same role.
  trusted_services = var.trusted_services

  tags = var.common_tags
}

# --- Phase 3: the data lake -------------------------------------------------

module "datalake" {
  source = "../../modules/datalake"

  name_prefix = var.name_prefix
  environment = var.environment

  # Null = on-demand. Set a cron only when you have a reason for the crawler
  # to run without you asking it to.
  crawler_schedule = var.crawler_schedule

  athena_bytes_scanned_cutoff = var.athena_bytes_scanned_cutoff

  tags = var.common_tags
}
