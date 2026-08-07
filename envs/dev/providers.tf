# ---------------------------------------------------------------------------
# Provider and version pinning for the dev environment.
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

  # default_tags puts these on every resource this provider creates, so you
  # never have to remember to tag anything by hand.
  default_tags {
    tags = merge(var.common_tags, {
      Environment = var.environment
      ManagedBy   = "terraform"
    })
  }
}
