# ---------------------------------------------------------------------------
# CROSS-ACCOUNT ASSUME-ROLE  (Phase 9, second half)
#
# HONEST LABEL: this is built inside ONE account, because the lab does not
# have a second one. The mechanism is identical either way -- what changes is
# only which account ID appears in the trust policy. Every property below
# (the two-sided trust, the ExternalId, the session tagging) behaves exactly
# as it would across an account boundary.
#
# What is NOT proven by a same-account build: that the trusting account's
# administrator cannot see or influence the trusted side. In one account, the
# same person owns both halves.
#
# ---------------------------------------------------------------------------
#
# The thing worth internalising: cross-account access needs agreement from
# BOTH sides, and neither can grant it alone.
#
#   Account B (here: the "remote" role) says in its TRUST POLICY:
#       "principals from account A may assume me"
#   Account A says in an IDENTITY POLICY:
#       "my principals may call sts:AssumeRole on that role in B"
#
# Miss either half and you get AccessDenied. This is why it is not a
# privilege-escalation path: B's admin cannot unilaterally hand out access to
# A's identities, and A's admin cannot grant themselves a role in B.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"

  # In a real setup this is the OTHER account's ID. Here it is our own, which
  # is exactly the substitution that makes this a simulation.
  trusting_account_id = var.trusted_account_id != "" ? var.trusted_account_id : data.aws_caller_identity.current.account_id
}

data "aws_caller_identity" "current" {}

# --- Side B: the role being assumed -----------------------------------------

data "aws_iam_policy_document" "trust" {
  statement {
    sid     = "AllowPartnerAccountToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    # In production this is the partner's account root, or better, the exact
    # role ARN. Naming the account root means "any principal in that account
    # that also has AssumeRole permission" -- the second half of the handshake
    # is what keeps that safe.
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.trusting_account_id}:root"]
    }

    # ExternalId defeats the "confused deputy" problem.
    #
    # The scenario: you are a SaaS vendor with a role in your account that can
    # assume customer roles. Customer X and customer Y both trust you. Without
    # an ExternalId, X can guess Y's role ARN and ask you to assume it -- and
    # you, the deputy, are confused into acting for X against Y's account.
    # The shared secret means X cannot make that call on Y's behalf.
    #
    # It is not a password: it is not secret from the parties involved, and it
    # is not a substitute for the trust policy. It disambiguates *who asked*.
    dynamic "condition" {
      for_each = var.external_id == "" ? [] : [1]

      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.external_id]
      }
    }

    # Require the caller to have authenticated with MFA if asked to. Off by
    # default because a CI pipeline cannot present an MFA token.
    dynamic "condition" {
      for_each = var.require_mfa ? [1] : []

      content {
        test     = "Bool"
        variable = "aws:MultiFactorAuthPresent"
        values   = ["true"]
      }
    }
  }
}

resource "aws_iam_role" "remote_reader" {
  name        = "${local.name}-remote-lake-reader"
  description = "Assumed from the partner account to read the lake. Same-account simulation in this lab."

  assume_role_policy = data.aws_iam_policy_document.trust.json

  # Short sessions. An hour of borrowed credentials is plenty, and the shorter
  # the window the less a leaked session token is worth.
  max_session_duration = var.max_session_duration

  tags = merge(var.tags, {
    Name = "${local.name}-remote-lake-reader"
  })
}

# Read-only, and narrow. A role reachable from another account should be the
# most tightly scoped thing in the account, not the least.
data "aws_iam_policy_document" "remote_reader" {
  statement {
    sid       = "ReadCuratedResultsOnly"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.curated_bucket_arn, "${var.curated_bucket_arn}/*"]
  }

  statement {
    sid    = "ReadCatalogMetadata"
    effect = "Allow"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases",
      "glue:GetTable", "glue:GetTables",
      "glue:GetPartition", "glue:GetPartitions",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "remote_reader" {
  name   = "${local.name}-remote-lake-reader"
  role   = aws_iam_role.remote_reader.id
  policy = data.aws_iam_policy_document.remote_reader.json
}

# --- Side A: permission to make the call ------------------------------------
#
# The other half of the handshake. In a real two-account setup this policy
# lives in the OTHER account and is attached to whoever needs to cross over.
# It is created here so the simulation can actually be executed end to end.

data "aws_iam_policy_document" "caller" {
  statement {
    sid       = "MayAssumeTheRemoteReader"
    effect    = "Allow"
    actions   = ["sts:AssumeRole"]
    resources = [aws_iam_role.remote_reader.arn]
  }
}

resource "aws_iam_policy" "caller" {
  name        = "${local.name}-may-assume-remote-reader"
  description = "Attach in the CALLING account. Grants sts:AssumeRole on the remote reader role."
  policy      = data.aws_iam_policy_document.caller.json

  tags = merge(var.tags, {
    Name = "${local.name}-may-assume-remote-reader"
  })
}
