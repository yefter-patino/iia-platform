# ---------------------------------------------------------------------------
# Outputs are the module's public interface. Phases 3 through 9 read these
# instead of looking IDs up in the console.
# ---------------------------------------------------------------------------

output "vpc_id" {
  description = "ID of the VPC."
  value       = aws_vpc.this.id
}

output "vpc_cidr" {
  description = "CIDR block of the VPC."
  value       = aws_vpc.this.cidr_block
}

output "public_subnet_ids" {
  description = "IDs of the public subnets, in AZ order."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "IDs of the private subnets, in AZ order."
  value       = aws_subnet.private[*].id
}

output "availability_zones" {
  description = "Availability Zones the subnets were placed in."
  value       = local.azs
}

output "private_route_table_ids" {
  description = "Private route table IDs. Phase 9 attaches the S3 gateway endpoint to these."
  value       = aws_route_table.private[*].id
}

output "private_workload_security_group_id" {
  description = "Security group for private workloads."
  value       = aws_security_group.private_workload.id
}

output "public_ingress_security_group_id" {
  description = "Security group for public-facing resources."
  value       = aws_security_group.public_ingress.id
}

output "nat_gateway_public_ips" {
  description = "Public IPs of the NAT Gateways. Empty when NAT is disabled."
  value       = aws_eip.nat[*].public_ip
}
