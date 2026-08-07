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
