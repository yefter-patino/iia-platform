# ---------------------------------------------------------------------------
# DATA LAKE MODULE  (Phase 3)
#
#   S3 raw      -> synthetic network telemetry lands here, untouched
#   S3 curated  -> whatever a job writes back out, Parquet later
#   Glue        -> a catalog database plus a crawler that infers the schema
#   Athena      -> SQL over the raw files, results into their own bucket
#
# The shape to understand: S3 holds the bytes, the Glue Data Catalog holds the
# *schema*, and Athena is a query engine that owns neither. Nothing is loaded
# into a database. The crawler reads a sample of the files, writes a table
# definition into the catalog, and from then on Athena can read the same files
# as if they were a table. That indirection is what "data lake" means in
# practice, and it is why the same files can be read by Athena today and Spark
# in Phase 4 without moving them.
#
# Cost shape, because this is the first phase that can leak money quietly:
#
#   S3 storage           pennies at lab volume
#   Glue Data Catalog    free under a million objects
#   Glue crawler         ~$0.44/DPU-hour, 2 DPU minimum, 10-minute minimum
#                        billing -> roughly $0.15 per run
#   Athena               $5 per TB scanned, minimum 10 MB per query
#
# Nothing here bills while idle. The two ways to get a surprise are a crawler
# on a schedule that nobody remembers, and a query that scans far more than
# expected. Both are addressed below: the crawler has no schedule by default,
# and the Athena workgroup enforces a per-query scan ceiling.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"

  # Bucket names are globally unique across all of AWS, so the account ID and
  # region go in the name. Same trick the bootstrap state bucket uses.
  suffix = "${data.aws_caller_identity.current.account_id}-${data.aws_region.current.region}"

  raw_bucket     = "${local.name}-raw-${local.suffix}"
  curated_bucket = "${local.name}-curated-${local.suffix}"
  results_bucket = "${local.name}-athena-results-${local.suffix}"

  # Where the crawler looks. Keeping the telemetry under one prefix means the
  # crawler is pointed at a subtree rather than the whole bucket, so adding a
  # second dataset later does not confuse the first table.
  telemetry_prefix = "telemetry/"

  # Where the Phase 4 PySpark job writes its Parquet output.
  anomalies_prefix = "anomalies/"
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

# --- Buckets ----------------------------------------------------------------

resource "aws_s3_bucket" "raw" {
  bucket = local.raw_bucket

  # Raw data is the one thing you cannot regenerate. Refuse to destroy it with
  # objects inside unless someone opts in explicitly.
  force_destroy = var.force_destroy_data_buckets

  tags = merge(var.tags, {
    Name = local.raw_bucket
    Tier = "raw"
  })
}

resource "aws_s3_bucket" "curated" {
  bucket        = local.curated_bucket
  force_destroy = var.force_destroy_data_buckets

  tags = merge(var.tags, {
    Name = local.curated_bucket
    Tier = "curated"
  })
}

# Query results are derived data -- regenerating them costs one re-run. This
# bucket is force_destroy unconditionally, because otherwise `terraform
# destroy` fails on the result files Athena leaves behind and you end up
# emptying it by hand every time.
resource "aws_s3_bucket" "results" {
  bucket        = local.results_bucket
  force_destroy = true

  tags = merge(var.tags, {
    Name = local.results_bucket
    Tier = "athena-results"
  })
}

locals {
  all_buckets = {
    raw     = aws_s3_bucket.raw.id
    curated = aws_s3_bucket.curated.id
    results = aws_s3_bucket.results.id
  }
}

resource "aws_s3_bucket_public_access_block" "this" {
  for_each = local.all_buckets

  bucket = each.value

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "this" {
  for_each = local.all_buckets

  bucket = each.value

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }

    # S3 Bucket Keys cut KMS request costs when a KMS key is used. Harmless
    # with AES256 and correct if this is ever switched to aws:kms.
    bucket_key_enabled = true
  }
}

# Versioning on the data buckets only. Versioning query results would keep
# every superseded result file forever, for nothing.
resource "aws_s3_bucket_versioning" "data" {
  for_each = {
    raw     = aws_s3_bucket.raw.id
    curated = aws_s3_bucket.curated.id
  }

  bucket = each.value

  versioning_configuration {
    status = "Enabled"
  }
}

# Athena writes a result file for every query, including the ones you ran by
# accident. Without expiry this bucket grows forever.
resource "aws_s3_bucket_lifecycle_configuration" "results" {
  bucket = aws_s3_bucket.results.id

  rule {
    id     = "expire-query-results"
    status = "Enabled"

    filter {}

    expiration {
      days = var.athena_results_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Old versions of raw objects are a safety net, not an archive. Expire the
# non-current ones so versioning cannot quietly become the storage bill.
resource "aws_s3_bucket_lifecycle_configuration" "data" {
  for_each = {
    raw     = aws_s3_bucket.raw.id
    curated = aws_s3_bucket.curated.id
  }

  bucket = each.value

  rule {
    id     = "expire-noncurrent-versions"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = var.noncurrent_version_retention_days
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  depends_on = [aws_s3_bucket_versioning.data]
}

# --- Glue catalog -----------------------------------------------------------

resource "aws_glue_catalog_database" "this" {
  name        = replace("${local.name}_lake", "-", "_")
  description = "Data catalog for the ${local.name} lake. Holds schemas, not data."
}

# --- Glue crawler role ------------------------------------------------------

data "aws_iam_policy_document" "glue_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["glue.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "crawler" {
  name               = "${local.name}-glue-crawler"
  description        = "Assumed by the Glue crawler to read the raw bucket and write table definitions."
  assume_role_policy = data.aws_iam_policy_document.glue_assume.json

  tags = merge(var.tags, {
    Name = "${local.name}-glue-crawler"
  })
}

# AWSGlueServiceRole covers the catalog and logging side. It does NOT grant
# access to your data -- AWS cannot know which buckets are yours. The S3 half
# is the inline policy below, and scoping it is the point.
resource "aws_iam_role_policy_attachment" "crawler_service" {
  role       = aws_iam_role.crawler.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole"
}

data "aws_iam_policy_document" "crawler_s3" {
  statement {
    sid    = "ReadRawTelemetryOnly"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    # The telemetry prefix, not the whole bucket.
    resources = ["${aws_s3_bucket.raw.arn}/${local.telemetry_prefix}*"]
  }

  # The Phase 4 job's Parquet output, so the anomalies become a queryable
  # table rather than files only Spark can read.
  statement {
    sid    = "ReadCuratedAnomalies"
    effect = "Allow"

    actions = [
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]

    resources = ["${aws_s3_bucket.curated.arn}/${local.anomalies_prefix}*"]
  }

  statement {
    sid    = "ListCuratedUnderAnomaliesPrefix"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.curated.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        local.anomalies_prefix,
        "${local.anomalies_prefix}*",
      ]
    }
  }

  # Listing is granted on the bucket itself -- s3:ListBucket is a bucket-level
  # action, so it cannot be scoped with an object ARN. The prefix condition is
  # what narrows it.
  statement {
    sid    = "ListRawBucketUnderTelemetryPrefix"
    effect = "Allow"

    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.raw.arn]

    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values = [
        local.telemetry_prefix,
        "${local.telemetry_prefix}*",
      ]
    }
  }
}

resource "aws_iam_role_policy" "crawler_s3" {
  name   = "${local.name}-glue-crawler-s3"
  role   = aws_iam_role.crawler.id
  policy = data.aws_iam_policy_document.crawler_s3.json
}

# --- The crawler ------------------------------------------------------------

resource "aws_glue_crawler" "telemetry" {
  name          = "${local.name}-telemetry"
  description   = "Infers the schema of the synthetic telemetry in the raw bucket."
  role          = aws_iam_role.crawler.arn
  database_name = aws_glue_catalog_database.this.name

  s3_target {
    path = "s3://${aws_s3_bucket.raw.id}/${local.telemetry_prefix}"
  }

  # schedule = null means on-demand only.
  #
  # This is the single most important cost decision in the phase. A crawler on
  # an hourly cron costs a few dollars a month forever and nobody notices,
  # because the money is spread thin. Run it when the schema changes:
  #
  #   aws glue start-crawler --name <name>
  schedule = var.crawler_schedule

  # LOG rather than DELETE_FROM_DATABASE: if the data disappears, say so in the
  # log and leave the table definition alone. Deleting schemas automatically
  # because a bucket looked empty for a moment is not a behaviour worth having.
  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = merge(var.tags, {
    Name = "${local.name}-telemetry"
  })
}

# --- Athena -----------------------------------------------------------------

resource "aws_athena_workgroup" "this" {
  name        = "${local.name}-wg"
  description = "Workgroup for the ${local.name} lake. Enforces result location and a per-query scan ceiling."

  configuration {
    # enforce_workgroup_configuration means a client cannot override these.
    # Without it, the scan ceiling below is a suggestion.
    enforce_workgroup_configuration    = true
    publish_cloudwatch_metrics_enabled = true

    # The guardrail. Athena bills $5/TB scanned; a query that forgets a
    # partition filter can scan the entire lake. This cancels any query that
    # would scan more than the limit, before it bills for it.
    bytes_scanned_cutoff_per_query = var.athena_bytes_scanned_cutoff

    result_configuration {
      output_location = "s3://${aws_s3_bucket.results.id}/query-results/"

      encryption_configuration {
        encryption_option = "SSE_S3"
      }
    }
  }

  # Without force_destroy, destroying a workgroup that has query history fails.
  force_destroy = true

  tags = merge(var.tags, {
    Name = "${local.name}-wg"
  })
}

# A second crawler over the Phase 4 output. Without it the anomalies are
# Parquet files that only Spark can read; with it they are a table, and the
# API and CLI can answer "what were the worst flows" in SQL.
resource "aws_glue_crawler" "anomalies" {
  name          = "${local.name}-anomalies"
  description   = "Infers the schema of the Phase 4 PySpark output in the curated bucket."
  role          = aws_iam_role.crawler.arn
  database_name = aws_glue_catalog_database.this.name

  s3_target {
    path = "s3://${aws_s3_bucket.curated.id}/${local.anomalies_prefix}"
  }

  schedule = var.crawler_schedule

  schema_change_policy {
    delete_behavior = "LOG"
    update_behavior = "UPDATE_IN_DATABASE"
  }

  tags = merge(var.tags, {
    Name = "${local.name}-anomalies"
  })
}
