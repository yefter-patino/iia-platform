# ---------------------------------------------------------------------------
# IAM / SECRETS MODULE  (Phase 2)
#
# Three things, in the order they depend on each other:
#
#   1. a customer-managed KMS key  -> encrypts the secret
#   2. a Secrets Manager secret    -> holds the value (set out of band)
#   3. an IAM role + policy        -> can read THAT secret with THAT key
#
# The point of the phase is the third one. Anyone can attach
# SecretsManagerReadWrite and move on; the exercise is writing a policy that
# names one resource ARN and nothing else, so the blast radius of a leaked
# role is a single secret rather than every secret in the account.
#
# Deliberately NOT here: aws_iam_account_password_policy and friends. Those
# are account-wide settings, and this account has workloads that are not part
# of this lab. A phase that changes the login rules for unrelated users is a
# phase that has overstepped.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"

  secret_name = "${var.name_prefix}/${var.environment}/${var.secret_name}"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- KMS key ----------------------------------------------------------------
# Secrets Manager will happily use the AWS-managed key (aws/secretsmanager)
# for free. We make our own anyway, because the AWS-managed key cannot have
# its policy edited -- so you can never say "only this role may decrypt".
# That control is the whole reason to pay the $1/month.

# A key policy is not optional. A KMS key with no policy is unusable by
# anyone, including you. This statement hands administration to the account
# root, which is what lets IAM policies grant key access at all.
data "aws_iam_policy_document" "kms" {
  statement {
    sid    = "EnableAccountAdministration"
    effect = "Allow"

    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"]
    }

    actions   = ["kms:*"]
    resources = ["*"]
  }

  # Let Secrets Manager itself use the key on behalf of callers, but only
  # when the request actually originates from Secrets Manager in this
  # account -- not from someone who merely holds these permissions.
  statement {
    sid    = "AllowSecretsManagerUse"
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["secretsmanager.amazonaws.com"]
    }

    actions = [
      "kms:Decrypt",
      "kms:GenerateDataKey",
      "kms:DescribeKey",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "kms:CallerAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_kms_key" "secrets" {
  description = "Encrypts Secrets Manager secrets for ${local.name}"

  # Rotation swaps the backing key material once a year. Old material is kept
  # so previously encrypted data still decrypts -- rotation is not a
  # re-encryption, and nothing you have to do by hand.
  enable_key_rotation = var.enable_key_rotation

  # Deleting a KMS key is irreversible and takes anything it encrypted with
  # it. AWS enforces a waiting period; 7 days is the minimum, and it is the
  # right choice for a lab you may want to tear down.
  deletion_window_in_days = var.kms_deletion_window_in_days

  policy = data.aws_iam_policy_document.kms.json

  tags = merge(var.tags, {
    Name = "${local.name}-secrets-key"
  })
}

# The alias is the human-readable handle. Without it you are pasting UUIDs.
resource "aws_kms_alias" "secrets" {
  name          = "alias/${local.name}-secrets"
  target_key_id = aws_kms_key.secrets.key_id
}

# --- The secret -------------------------------------------------------------

resource "aws_secretsmanager_secret" "app" {
  name        = local.secret_name
  description = "Application secret for ${local.name}. Value is set outside Terraform."
  kms_key_id  = aws_kms_key.secrets.arn

  # Same reasoning as the KMS deletion window: let it be recoverable.
  recovery_window_in_days = var.secret_recovery_window_in_days

  tags = merge(var.tags, {
    Name = local.secret_name
  })
}

# NOTE: there is deliberately no aws_secretsmanager_secret_version here.
#
# Terraform would need the plaintext to create one, and everything Terraform
# is given ends up in the state file. The state file is encrypted in S3, but
# "encrypted at rest somewhere I can read" is not the same as "secret". So
# Terraform creates the empty container and the value is put in by hand:
#
#   aws secretsmanager put-secret-value \
#     --secret-id <name> --secret-string '{"key":"value"}'
#
# This is the standard split: Terraform owns the resource, not the contents.

# --- The least-privilege role ----------------------------------------------

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = var.trusted_services
    }
  }
}

resource "aws_iam_role" "secret_reader" {
  name        = "${local.name}-secret-reader"
  description = "May read exactly one secret and decrypt with exactly one key."

  assume_role_policy = data.aws_iam_policy_document.assume_role.json

  tags = merge(var.tags, {
    Name = "${local.name}-secret-reader"
  })
}

# This is the part worth reading twice.
#
# resources = [the one secret ARN]  -- not "*", not a prefix.
# The kms:Decrypt statement is scoped to the one key AND conditioned on the
# call arriving via Secrets Manager, so this role cannot use the key to
# decrypt anything else that happens to be encrypted with it.
data "aws_iam_policy_document" "secret_reader" {
  statement {
    sid    = "ReadOneSecret"
    effect = "Allow"

    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
    ]

    resources = [aws_secretsmanager_secret.app.arn]
  }

  statement {
    sid    = "DecryptWithOneKeyViaSecretsManager"
    effect = "Allow"

    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.secrets.arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "secret_reader" {
  name        = "${local.name}-secret-reader"
  description = "Least-privilege read of the ${local.name} application secret."
  policy      = data.aws_iam_policy_document.secret_reader.json

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "secret_reader" {
  role       = aws_iam_role.secret_reader.name
  policy_arn = aws_iam_policy.secret_reader.arn
}
