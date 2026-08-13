# ---------------------------------------------------------------------------
# Outputs are the module's public interface. Later phases attach the role to
# an instance profile (Phase 6) or read the secret name from a task
# definition, instead of looking any of it up in the console.
# ---------------------------------------------------------------------------

output "kms_key_arn" {
  description = "ARN of the customer-managed key that encrypts the secret."
  value       = aws_kms_key.secrets.arn
}

output "kms_key_alias" {
  description = "Human-readable alias for the KMS key."
  value       = aws_kms_alias.secrets.name
}

output "secret_arn" {
  description = "ARN of the application secret."
  value       = aws_secretsmanager_secret.app.arn
}

output "secret_name" {
  description = "Full name of the secret. This is what you pass to put-secret-value."
  value       = aws_secretsmanager_secret.app.name
}

output "secret_reader_role_arn" {
  description = "ARN of the role that may read the secret."
  value       = aws_iam_role.secret_reader.arn
}

output "secret_reader_role_name" {
  description = "Name of the secret-reader role. Phase 6 attaches this to an ECS task definition."
  value       = aws_iam_role.secret_reader.name
}

output "secret_reader_policy_arn" {
  description = "ARN of the least-privilege policy, so later phases can attach it to other roles."
  value       = aws_iam_policy.secret_reader.arn
}

output "instance_profile_name" {
  description = "Instance profile to attach when launching an EC2 instance. Null if ec2.amazonaws.com is not a trusted principal."
  value       = try(aws_iam_instance_profile.secret_reader[0].name, null)
}

output "instance_profile_arn" {
  description = "ARN of the instance profile. Null if ec2.amazonaws.com is not a trusted principal."
  value       = try(aws_iam_instance_profile.secret_reader[0].arn, null)
}
