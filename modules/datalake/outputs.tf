# ---------------------------------------------------------------------------
# Outputs. Phase 4 reads the bucket names for the PySpark job, Phase 5's CLI
# reads the database and workgroup names, and Phase 9 attaches the S3 gateway
# endpoint so this traffic stops going out through the NAT.
# ---------------------------------------------------------------------------

output "raw_bucket_name" {
  description = "Bucket where synthetic telemetry lands."
  value       = aws_s3_bucket.raw.id
}

output "raw_bucket_arn" {
  description = "ARN of the raw bucket."
  value       = aws_s3_bucket.raw.arn
}

output "curated_bucket_name" {
  description = "Bucket for processed output. Phase 4 writes Parquet here."
  value       = aws_s3_bucket.curated.id
}

output "curated_bucket_arn" {
  description = "ARN of the curated bucket."
  value       = aws_s3_bucket.curated.arn
}

output "athena_results_bucket_name" {
  description = "Bucket holding Athena query results."
  value       = aws_s3_bucket.results.id
}

output "telemetry_s3_uri" {
  description = "Full s3:// URI the crawler scans. Upload telemetry under here."
  value       = "s3://${aws_s3_bucket.raw.id}/${local.telemetry_prefix}"
}

output "glue_database_name" {
  description = "Glue catalog database holding the inferred table schemas."
  value       = aws_glue_catalog_database.this.name
}

output "glue_crawler_name" {
  description = "Crawler name. Run it with: aws glue start-crawler --name <this>"
  value       = aws_glue_crawler.telemetry.name
}

output "glue_crawler_role_arn" {
  description = "Role the crawler assumes."
  value       = aws_iam_role.crawler.arn
}

output "athena_workgroup_name" {
  description = "Athena workgroup. Pass with --work-group so the scan ceiling applies."
  value       = aws_athena_workgroup.this.name
}

output "athena_workgroup_arn" {
  description = "Workgroup ARN, so query permissions can name one workgroup instead of all of them."
  value       = aws_athena_workgroup.this.arn
}

output "athena_results_bucket_arn" {
  description = "ARN of the Athena results bucket."
  value       = aws_s3_bucket.results.arn
}

output "anomalies_crawler_name" {
  description = "Crawler over the Phase 4 Parquet output. Run after each EMR job."
  value       = aws_glue_crawler.anomalies.name
}

output "anomalies_s3_uri" {
  description = "Where the Phase 4 job writes its results."
  value       = "s3://${aws_s3_bucket.curated.id}/${local.anomalies_prefix}"
}
