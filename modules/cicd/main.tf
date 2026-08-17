# ---------------------------------------------------------------------------
# CI/CD MODULE  (Phase 7)
#
# Lets GitHub Actions authenticate to AWS with **no stored credentials**.
#
# The old way was an IAM user with an access key pasted into repository
# secrets. That key is long-lived, works from anywhere on earth, and is only
# as safe as every person who can read the settings page. Rotating it means
# remembering it exists.
#
# OIDC replaces it with a trust relationship. GitHub mints a short-lived,
# signed token describing *which repository, which branch, which workflow* is
# running. AWS verifies the signature against GitHub's published keys and
# hands back credentials that expire in an hour. Nothing is stored anywhere.
#
# The condition block below is the entire security boundary. Get the `sub`
# claim wrong and you have not built a deployment role -- you have built a
# role that any GitHub repository in the world can assume.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"

  # GitHub now issues IMMUTABLE subject claims. The sub is no longer
  #
  #     repo:owner/name:pull_request
  #
  # but
  #
  #     repo:owner@<owner_id>/name@<repo_id>:pull_request
  #
  # Observed from a real run:
  #
  #     sub: repo:yefter-patino@276095800/iia-platform@1329850140:pull_request
  #
  # Practically every tutorial still shows the legacy form, and a trust policy
  # written that way fails with "Not authorized to perform
  # sts:AssumeRoleWithWebIdentity" -- an error that names neither the claim nor
  # the mismatch. The only way to see it is to decode the token GitHub issues.
  #
  # The numeric IDs are the better thing to pin anyway, and are why GitHub made
  # the change: names can be renamed and released. If someone deletes this
  # account and another user registers the same login, a policy trusting the
  # *name* would trust them. A policy trusting 276095800 would not.
  #
  # Both forms are accepted so the module works against GitHub Enterprise
  # instances that still emit the legacy claim. Either way it is pinned to
  # exactly this repository.
  repo_immutable = (
    var.github_owner_id != "" && var.github_repository_id != ""
    ? format(
      "%s@%s/%s@%s",
      split("/", var.github_repository)[0],
      var.github_owner_id,
      split("/", var.github_repository)[1],
      var.github_repository_id,
    )
    : ""
  )

  repo_forms = compact([var.github_repository, local.repo_immutable])

  subjects = concat(
    flatten([
      for form in local.repo_forms : [
        for branch in var.allowed_branches : "repo:${form}:ref:refs/heads/${branch}"
      ]
    ]),
    var.allow_pull_requests ? [for form in local.repo_forms : "repo:${form}:pull_request"] : [],
  )
}

data "aws_caller_identity" "current" {}

# --- The OIDC provider ------------------------------------------------------
#
# One per account. If another workload already registered GitHub as a
# provider, set create_oidc_provider = false and pass the existing ARN --
# creating a second one for the same URL fails, and this account has other
# tenants.

resource "aws_iam_openid_connect_provider" "github" {
  count = var.create_oidc_provider ? 1 : 0

  url             = "https://token.actions.githubusercontent.com"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = var.thumbprints

  tags = merge(var.tags, {
    Name = "${local.name}-github-oidc"
  })
}

locals {
  provider_arn = var.create_oidc_provider ? aws_iam_openid_connect_provider.github[0].arn : var.existing_oidc_provider_arn
}

# --- The role GitHub assumes ------------------------------------------------

data "aws_iam_policy_document" "assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [local.provider_arn]
    }

    # Audience. Without this, a token minted for a different audience would
    # still be accepted.
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Subject. This is the line that says *which* repository and ref.
    #
    # StringLike rather than StringEquals only because the subjects list may
    # contain a wildcard for environments. Never write this as
    # "repo:${var.github_repository}:*" and stop there -- and never, ever as
    # "*", which trusts every repository on GitHub.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = local.subjects
    }
  }
}

resource "aws_iam_role" "deploy" {
  name        = "${local.name}-github-actions"
  description = "Assumed by GitHub Actions via OIDC. No stored credentials."

  assume_role_policy = data.aws_iam_policy_document.assume.json

  # An hour is enough for a plan or a build; the default is longer than any
  # workflow here needs to hold credentials.
  max_session_duration = 3600

  tags = merge(var.tags, {
    Name = "${local.name}-github-actions"
  })
}

# --- What CI may do ---------------------------------------------------------
#
# Read-heavy on purpose. This role can plan, validate, and push an image. It
# cannot apply.
#
# `terraform plan` needs to read state and describe every resource, so a plan
# role is inherently broad in reads. Granting apply as well would mean a
# compromised workflow file could rewrite the account, and workflow files are
# edited in pull requests.

data "aws_iam_policy_document" "deploy" {
  statement {
    sid    = "ReadAndLockTerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:ListBucket",
      "s3:GetBucketLocation",
    ]
    resources = [var.state_bucket_arn, "${var.state_bucket_arn}/*"]
  }

  # Everything Terraform needs to build a plan. Describe/Get/List only.
  statement {
    sid    = "DescribeEverythingForPlan"
    effect = "Allow"
    actions = [
      "ec2:Describe*",
      "iam:Get*",
      "iam:List*",
      "s3:GetBucket*",
      "s3:GetLifecycleConfiguration",
      "s3:GetEncryptionConfiguration",
      "s3:ListAllMyBuckets",
      "glue:Get*",
      "athena:Get*",
      "athena:List*",
      "kms:Describe*",
      "kms:Get*",
      "kms:List*",
      "secretsmanager:Describe*",
      "secretsmanager:List*",
      # Explicitly NOT secretsmanager:Get* -- that wildcard includes
      # GetSecretValue, which would let any workflow run print the secret.
      # Terraform needs the resource policy to plan; it never needs the value.
      "secretsmanager:GetResourcePolicy",
      "elasticmapreduce:Describe*",
      "elasticmapreduce:List*",
      "ecs:Describe*",
      "ecs:List*",
      "ecr:Describe*",
      "ecr:List*",
      # Get* on ECR is all read actions -- repository policy, lifecycle
      # policy, layer download URLs. Nothing here reveals anything the plan
      # does not already need.
      "ecr:Get*",
      "logs:Describe*",
      "logs:ListTagsForResource",
      "cloudwatch:Describe*",
      "cloudwatch:Get*",
      "cloudwatch:List*",
      "sns:Get*",
      "sns:List*",
      "budgets:Describe*",
      "budgets:View*",
    ]
    resources = ["*"]
  }

  # Pushing an image. ecr:GetAuthorizationToken cannot be scoped to a
  # repository -- it is an account-level action -- which is why it is its own
  # statement rather than hidden in the list above.
  statement {
    sid       = "EcrLogin"
    effect    = "Allow"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid    = "PushImageToOneRepository"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:CompleteLayerUpload",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [var.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "deploy" {
  name   = "${local.name}-github-actions"
  role   = aws_iam_role.deploy.id
  policy = data.aws_iam_policy_document.deploy.json
}
