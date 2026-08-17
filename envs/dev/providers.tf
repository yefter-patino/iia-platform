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
  region = var.aws_region

  # null, not "", when no profile is given.
  #
  # A hardcoded profile makes this configuration unusable anywhere that is not
  # a laptop. CI has no ~/.aws/credentials at all -- the OIDC action puts
  # short-lived credentials in environment variables -- so naming a profile
  # sends the provider looking for a file that does not exist. Falling back to
  # null lets the standard credential chain do its job: env vars in CI, the
  # named profile locally.
  profile = var.aws_profile != "" ? var.aws_profile : null

  # default_tags puts these on every resource this provider creates, so you
  # never have to remember to tag anything by hand.
  default_tags {
    tags = merge(var.common_tags, {
      Environment = var.environment
      ManagedBy   = "terraform"
    })
  }
}
