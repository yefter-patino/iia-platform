# ---------------------------------------------------------------------------
# BOOTSTRAP  (run this once, first)
#
# Chicken-and-egg problem: we want Terraform state in S3, but the S3 bucket
# has to exist before Terraform can use it. So this one small stack keeps its
# state on your laptop (local state) and builds two things:
#
#   1. the S3 bucket that every other stack will store its state in
#   2. the AWS Budget that emails you before the lab costs real money
#
# Everything after this uses the remote bucket.
# ---------------------------------------------------------------------------

terraform {
  required_version = ">= 1.11"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile

  default_tags {
    tags = var.common_tags
  }
}

# Asks AWS "who am I?" so we can build a globally unique bucket name from the
# account ID instead of typing the account number into the code.
data "aws_caller_identity" "current" {}

locals {
  state_bucket_name = "${var.name_prefix}-tfstate-${data.aws_caller_identity.current.account_id}-${var.aws_region}"
}

# --- The state bucket -------------------------------------------------------

resource "aws_s3_bucket" "tfstate" {
  bucket = local.state_bucket_name

  tags = {
    Name = local.state_bucket_name
  }
}

# Versioning is not optional here. State locking and state recovery both
# depend on it. If you ever corrupt state, versioning is how you roll back.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# State files contain resource IDs and sometimes secrets. Never public.
resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- The safety net ---------------------------------------------------------

resource "aws_budgets_budget" "monthly" {
  name         = "${var.name_prefix}-lab-monthly-budget"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Fires on money already spent.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_actual_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_alert_email]
  }

  # Fires on where AWS thinks the month is heading. This is the one that
  # catches a NAT Gateway you forgot to destroy on day two.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_forecast_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_alert_email]
  }
}
