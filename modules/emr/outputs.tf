# ---------------------------------------------------------------------------
# Outputs. scripts/run-emr-job.sh reads all of these to build the
# create-cluster call, which is why the module can avoid creating a cluster
# while still owning every durable piece one needs.
# ---------------------------------------------------------------------------

output "service_role_name" {
  description = "EMR service role name. Passed as --service-role."
  value       = aws_iam_role.service.name
}

output "instance_profile_name" {
  description = "Instance profile for the cluster nodes. Passed as InstanceProfile in --ec2-attributes."
  value       = aws_iam_instance_profile.ec2.name
}

output "ec2_role_arn" {
  description = "ARN of the role the cluster nodes assume."
  value       = aws_iam_role.ec2.arn
}

output "master_security_group_id" {
  description = "Security group for the master node."
  value       = aws_security_group.master.id
}

output "core_security_group_id" {
  description = "Security group for the core and task nodes."
  value       = aws_security_group.core.id
}

output "service_access_security_group_id" {
  description = "Service access group, required for clusters in private subnets."
  value       = aws_security_group.service_access.id
}
