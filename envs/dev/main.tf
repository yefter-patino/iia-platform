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

  # AmazonEMRServicePolicy_v2 conditions its EC2 permissions on this tag being
  # present on the resources EMR touches: the subnets and security groups it
  # launches into, and the VPC itself -- a private-subnet cluster makes EMR
  # create its own service VPC endpoint, and that check reads the VPC's tags.
  # Miss the VPC and the cluster dies with "Service role has insufficient EC2
  # permissions", which names neither the resource nor the tag.
  vpc_extra_tags = {
    "for-use-with-amazon-emr-managed-policies" = "true"
  }

  private_subnet_extra_tags = {
    "for-use-with-amazon-emr-managed-policies" = "true"
  }

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

# --- Phase 4: EMR ------------------------------------------------------------
#
# Durable pieces only. The cluster itself is transient and is launched by
# scripts/run-emr-job.sh, because a self-terminating resource does not belong
# in Terraform state.

module "emr" {
  source = "../../modules/emr"

  name_prefix = var.name_prefix
  environment = var.environment
  vpc_id      = module.network.vpc_id

  raw_bucket_arn     = module.datalake.raw_bucket_arn
  curated_bucket_arn = module.datalake.curated_bucket_arn

  # Cluster logs go to the curated bucket under emr-logs/ rather than to a
  # fourth bucket that would exist only to hold them.
  logs_bucket_arn = module.datalake.curated_bucket_arn

  tags = var.common_tags
}

# --- Phase 6: the service ---------------------------------------------------

module "ecr" {
  source = "../../modules/ecr"

  name_prefix = var.name_prefix
  environment = var.environment

  tags = var.common_tags
}

module "ecs" {
  source = "../../modules/ecs"

  name_prefix        = var.name_prefix
  environment        = var.environment
  vpc_id             = module.network.vpc_id
  private_subnet_ids = module.network.private_subnet_ids

  image_uri = var.api_image_uri != "" ? var.api_image_uri : "${module.ecr.repository_url}:${var.api_image_tag}"

  # 0 means defined but not running, and not billing. scripts/deploy-api.sh
  # scales it up after pushing an image.
  desired_count    = var.api_desired_count
  cpu_architecture = var.api_cpu_architecture

  raw_bucket_name           = module.datalake.raw_bucket_name
  raw_bucket_arn            = module.datalake.raw_bucket_arn
  curated_bucket_name       = module.datalake.curated_bucket_name
  curated_bucket_arn        = module.datalake.curated_bucket_arn
  athena_results_bucket_arn = module.datalake.athena_results_bucket_arn
  athena_workgroup_name     = module.datalake.athena_workgroup_name
  athena_workgroup_arn      = module.datalake.athena_workgroup_arn
  glue_database_name        = module.datalake.glue_database_name

  secret_name = module.iam.secret_name
  secret_arn  = module.iam.secret_arn
  kms_key_arn = module.iam.kms_key_arn

  tags = var.common_tags
}

# --- Phase 7: CI -------------------------------------------------------------

module "cicd" {
  source = "../../modules/cicd"

  name_prefix          = var.name_prefix
  environment          = var.environment
  github_repository    = var.github_repository
  github_owner_id      = var.github_owner_id
  github_repository_id = var.github_repository_id

  # This account already had GitHub registered as an OIDC provider by an
  # unrelated workload, and only one per URL can exist. Reuse it rather than
  # trying to own it -- creating it here would fail, and importing it would
  # mean this lab could destroy something another tenant depends on.
  create_oidc_provider       = var.create_oidc_provider
  existing_oidc_provider_arn = var.existing_oidc_provider_arn

  state_bucket_arn   = "arn:aws:s3:::${var.state_bucket_name}"
  ecr_repository_arn = module.ecr.repository_arn

  tags = var.common_tags
}

# --- Phase 8: monitoring -----------------------------------------------------

module "monitoring" {
  source = "../../modules/monitoring"

  name_prefix = var.name_prefix
  environment = var.environment
  alert_email = var.alert_email

  raw_bucket_name       = module.datalake.raw_bucket_name
  athena_workgroup_name = module.datalake.athena_workgroup_name

  ecs_cluster_name = module.ecs.cluster_name
  ecs_service_name = module.ecs.service_name
  log_group_name   = module.ecs.log_group_name

  tags = var.common_tags
}

# --- Phase 9 (second half): cross-account pattern ----------------------------
#
# trusted_account_id is empty, so both halves land in this account. The
# mechanism is identical to the real thing; only the account ID differs.

module "crossaccount" {
  source = "../../modules/crossaccount"

  name_prefix        = var.name_prefix
  environment        = var.environment
  trusted_account_id = var.partner_account_id
  external_id        = var.cross_account_external_id

  curated_bucket_arn = module.datalake.curated_bucket_arn

  tags = var.common_tags
}
