# ---------------------------------------------------------------------------
# EMR MODULE  (Phase 4)
#
# This module deliberately does NOT create a cluster.
#
# The cluster is *transient*: it starts, runs one Spark job, and terminates
# itself. Terraform is a tool for describing state that should persist, and a
# resource that deletes itself moments after creation fights that model --
# every subsequent plan would want to rebuild the cluster Terraform believes
# should exist. Wrapping a self-terminating cluster in `terraform apply` is a
# common mistake and it makes the state file lie.
#
# So the split is:
#
#   Terraform (here)   the durable things -- IAM roles, the instance profile,
#                      security groups, the log location. Free to keep.
#   scripts/run-emr-job.sh   launches the transient cluster with
#                      --auto-terminate, waits, reports, and is gone.
#
# Cost shape: nothing in this module bills. The cluster does, per
# instance-hour, from the moment it starts until it terminates -- including
# the ~7 minutes it spends bootstrapping before your code runs.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"

  # AmazonEMRServicePolicy_v2 scopes most of its EC2 permissions with a
  # condition requiring this tag on the resources EMR touches. Without it the
  # cluster fails during provisioning with an access-denied that names
  # ec2:RunInstances and explains nothing. This is the single most common way
  # a first EMR cluster fails on the v2 policy.
  emr_tag = {
    "for-use-with-amazon-emr-managed-policies" = "true"
  }
}

data "aws_caller_identity" "current" {}

# --- Service role -----------------------------------------------------------
# Assumed by the EMR service itself to provision instances on your behalf.

data "aws_iam_policy_document" "service_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["elasticmapreduce.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "service" {
  name               = "${local.name}-emr-service"
  description        = "Assumed by EMR to provision cluster infrastructure."
  assume_role_policy = data.aws_iam_policy_document.service_assume.json

  tags = merge(var.tags, local.emr_tag, {
    Name = "${local.name}-emr-service"
  })
}

# v2 rather than the legacy AmazonElasticMapReduceRole, which AWS marks as
# "on a deprecation path". The cost of v2 is the tagging convention above.
resource "aws_iam_role_policy_attachment" "service" {
  role       = aws_iam_role.service.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEMRServicePolicy_v2"
}

# AmazonEMRServicePolicy_v2 grants iam:PassRole, but hardcodes the role name:
#
#   "Sid": "PassRoleForEC2",
#   "Resource": "arn:aws:iam::*:role/EMR_EC2_DefaultRole"
#
# So it only works if your instance-profile role is literally called
# EMR_EC2_DefaultRole. Ours follows this repo's naming convention instead, and
# without the statement below the cluster dies during provisioning with
#
#   Service role <name> has insufficient EC2 permissions
#
# which does not mention PassRole, the role it failed to pass, or IAM at all.
# CloudTrail is where the real error lives: RunInstances ->
# Client.UnauthorizedOperation, "not authorized to perform: iam:PassRole".
#
# Renaming our role to EMR_EC2_DefaultRole would also work and is what most
# tutorials do. It is the wrong trade in an account shared with unrelated
# workloads: that name is generic enough to collide with someone else's EMR
# setup, and then two teams own one role.
data "aws_iam_policy_document" "service_pass_role" {
  statement {
    sid    = "PassTheClusterNodeRole"
    effect = "Allow"

    actions   = ["iam:PassRole"]
    resources = [aws_iam_role.ec2.arn]

    # Without this the role could be passed to any service, which is the
    # privilege-escalation shape PassRole is famous for.
    condition {
      test     = "StringLike"
      variable = "iam:PassedToService"
      values   = ["ec2.amazonaws.com*"]
    }
  }
}

resource "aws_iam_role_policy" "service_pass_role" {
  name   = "${local.name}-emr-service-passrole"
  role   = aws_iam_role.service.id
  policy = data.aws_iam_policy_document.service_pass_role.json
}

# --- EC2 instance role ------------------------------------------------------
# What the code running ON the cluster nodes can do. This is the one that
# needs access to your data, and the one worth scoping.

data "aws_iam_policy_document" "ec2_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ec2" {
  name               = "${local.name}-emr-ec2"
  description        = "Role assumed by the EMR cluster nodes. Reads raw, writes curated and logs."
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json

  tags = merge(var.tags, local.emr_tag, {
    Name = "${local.name}-emr-ec2"
  })
}

# Deliberately not AmazonElasticMapReduceforEC2Role: that managed policy
# grants s3:* on every bucket in the account, which in an account shared with
# unrelated workloads is far too much. This names the three buckets.
data "aws_iam_policy_document" "ec2" {
  statement {
    sid    = "ReadRawTelemetry"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    resources = ["${var.raw_bucket_arn}/*"]
  }

  statement {
    sid    = "WriteCuratedAndLogs"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:DeleteObject",
      "s3:AbortMultipartUpload",
    ]

    resources = [
      "${var.curated_bucket_arn}/*",
      "${var.logs_bucket_arn}/*",
    ]
  }

  # Spark lists prefixes constantly to discover partitions and to write its
  # output committer files.
  statement {
    sid    = "ListTheThreeBuckets"
    effect = "Allow"

    actions = [
      "s3:ListBucket",
      "s3:GetBucketLocation",
      "s3:ListBucketMultipartUploads",
    ]

    resources = [
      var.raw_bucket_arn,
      var.curated_bucket_arn,
      var.logs_bucket_arn,
    ]
  }

  # Reading table definitions from the Glue catalog, so Spark can use the
  # schema the Phase 3 crawler inferred instead of re-inferring it.
  statement {
    sid    = "ReadGlueCatalog"
    effect = "Allow"

    actions = [
      "glue:GetDatabase",
      "glue:GetDatabases",
      "glue:GetTable",
      "glue:GetTables",
      "glue:GetPartition",
      "glue:GetPartitions",
    ]

    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "ec2" {
  name   = "${local.name}-emr-ec2"
  role   = aws_iam_role.ec2.id
  policy = data.aws_iam_policy_document.ec2.json
}

# Session Manager on the cluster nodes, same reasoning as Phase 2: a shell on
# a failing node without opening SSH.
resource "aws_iam_role_policy_attachment" "ec2_ssm" {
  count = var.enable_ssm_access ? 1 : 0

  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-emr-ec2"
  role = aws_iam_role.ec2.name

  tags = merge(var.tags, local.emr_tag, {
    Name = "${local.name}-emr-ec2"
  })
}

# --- Security groups --------------------------------------------------------
#
# EMR will happily create its own security groups, but they will not carry the
# tag that AmazonEMRServicePolicy_v2 requires, and the cluster fails. So we
# create them, tagged, and hand them over.
#
# EMR writes the INGRESS rules into these itself -- the inter-node traffic and
# the 8443 path from the service access group. Terraform must not fight it,
# hence ignore_changes on ingress.
#
# EGRESS is ours, and this is the trap:
#
# When you create a security group through the AWS API it comes with a default
# allow-all egress rule. Terraform's aws_security_group manages the egress list
# as a whole, so a resource with no egress blocks does not mean "leave the
# default alone" -- it means "there should be no egress rules", and Terraform
# revokes the default.
#
# EMR never adds egress rules, because normally it does not have to. The
# result is a cluster whose nodes cannot reach anything: it provisions, starts
# bootstrapping, and hangs in STARTING / "Configuring cluster software" until
# it times out, billing the whole time. There is no error message, because
# from EMR's point of view nothing failed yet.
#
# Cost of learning this the slow way: about eleven cents.

resource "aws_security_group" "master" {
  name        = "${local.name}-emr-master"
  description = "EMR master node. Rules are managed by EMR itself."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, local.emr_tag, {
    Name = "${local.name}-emr-master"
  })

  # EMR adds and removes rules here. Without this, every plan shows drift as
  # Terraform tries to remove the rules EMR just added.
  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

# Outbound for the master node: package repositories, the EMR service
# endpoints, and S3 (which takes the gateway endpoint rather than the NAT).
resource "aws_vpc_security_group_egress_rule" "master_all_out" {
  security_group_id = aws_security_group.master.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound. Without this the cluster hangs in STARTING with no error."
}

resource "aws_security_group" "core" {
  name        = "${local.name}-emr-core"
  description = "EMR core/task nodes. Rules are managed by EMR itself."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, local.emr_tag, {
    Name = "${local.name}-emr-core"
  })

  lifecycle {
    ignore_changes = [ingress, egress]
  }
}

resource "aws_vpc_security_group_egress_rule" "core_all_out" {
  security_group_id = aws_security_group.core.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound. Without this the cluster hangs in STARTING with no error."
}

# Required only for clusters in PRIVATE subnets. It is how the EMR service
# reaches the cluster to manage it.
#
# Unlike the two groups above, EMR does NOT populate this one. It *validates*
# it and refuses to launch if the rules are missing:
#
#   VALIDATION_ERROR: ServiceAccessSecurityGroup is missing ingress rule
#   from EmrManagedMasterSecurityGroup on port 9443
#
# The rules are therefore explicit below. This is the asymmetry to remember:
# EMR manages the master and core groups, and you manage this one.
resource "aws_security_group" "service_access" {
  name        = "${local.name}-emr-service-access"
  description = "Service access group, required for EMR clusters in private subnets."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, local.emr_tag, {
    Name = "${local.name}-emr-service-access"
  })
}

# Inbound: the master node reaches the service access group on 9443.
resource "aws_vpc_security_group_ingress_rule" "service_access_from_master" {
  security_group_id            = aws_security_group.service_access.id
  referenced_security_group_id = aws_security_group.master.id
  ip_protocol                  = "tcp"
  from_port                    = 9443
  to_port                      = 9443
  description                  = "EMR master to service access, required for private-subnet clusters"
}

# Outbound: the service access group reaches the cluster nodes on 8443.
resource "aws_vpc_security_group_egress_rule" "service_access_to_master" {
  security_group_id            = aws_security_group.service_access.id
  referenced_security_group_id = aws_security_group.master.id
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  description                  = "Service access to EMR master"
}

resource "aws_vpc_security_group_egress_rule" "service_access_to_core" {
  security_group_id            = aws_security_group.service_access.id
  referenced_security_group_id = aws_security_group.core.id
  ip_protocol                  = "tcp"
  from_port                    = 8443
  to_port                      = 8443
  description                  = "Service access to EMR core and task nodes"
}
