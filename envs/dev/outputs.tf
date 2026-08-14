# Later phases read these with `terraform output` or a remote state data source.

output "vpc_id" {
  description = "ID of the dev VPC."
  value       = module.network.vpc_id
}

output "public_subnet_ids" {
  description = "Public subnet IDs."
  value       = module.network.public_subnet_ids
}

output "private_subnet_ids" {
  description = "Private subnet IDs."
  value       = module.network.private_subnet_ids
}

output "private_route_table_ids" {
  description = "Private route table IDs."
  value       = module.network.private_route_table_ids
}

output "private_workload_security_group_id" {
  description = "Security group for private workloads."
  value       = module.network.private_workload_security_group_id
}

output "availability_zones" {
  description = "AZs in use."
  value       = module.network.availability_zones
}

# --- Phase 2 ----------------------------------------------------------------

output "secret_name" {
  description = "Name of the application secret. Pass this to put-secret-value."
  value       = module.iam.secret_name
}

output "secret_arn" {
  description = "ARN of the application secret."
  value       = module.iam.secret_arn
}

output "kms_key_alias" {
  description = "Alias of the customer-managed key encrypting the secret."
  value       = module.iam.kms_key_alias
}

output "secret_reader_role_arn" {
  description = "Role that may read the secret. Phase 6 attaches this to the ECS task."
  value       = module.iam.secret_reader_role_arn
}

output "instance_profile_name" {
  description = "Pass this to `aws ec2 run-instances --iam-instance-profile` to get an SSM-reachable test instance."
  value       = module.iam.instance_profile_name
}

# --- Phase 3 ----------------------------------------------------------------

output "raw_bucket_name" {
  description = "Bucket where synthetic telemetry lands."
  value       = module.datalake.raw_bucket_name
}

output "curated_bucket_name" {
  description = "Bucket for processed output."
  value       = module.datalake.curated_bucket_name
}

output "telemetry_s3_uri" {
  description = "Upload telemetry under this URI -- it is what the crawler scans."
  value       = module.datalake.telemetry_s3_uri
}

output "glue_database_name" {
  description = "Glue catalog database."
  value       = module.datalake.glue_database_name
}

output "glue_crawler_name" {
  description = "Run with: aws glue start-crawler --name <this>"
  value       = module.datalake.glue_crawler_name
}

output "athena_workgroup_name" {
  description = "Pass with --work-group so the scan ceiling applies."
  value       = module.datalake.athena_workgroup_name
}

# --- Phase 4 ----------------------------------------------------------------
# scripts/run-emr-job.sh reads these to build the create-cluster call.

output "emr_service_role_name" {
  description = "EMR service role, passed as --service-role."
  value       = module.emr.service_role_name
}

output "emr_instance_profile_name" {
  description = "Instance profile for the cluster nodes."
  value       = module.emr.instance_profile_name
}

output "emr_master_security_group_id" {
  description = "Master node security group."
  value       = module.emr.master_security_group_id
}

output "emr_core_security_group_id" {
  description = "Core/task node security group."
  value       = module.emr.core_security_group_id
}

output "emr_service_access_security_group_id" {
  description = "Service access group, required for private-subnet clusters."
  value       = module.emr.service_access_security_group_id
}
