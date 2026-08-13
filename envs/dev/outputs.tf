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
