output "role_arn" {
  description = "Set this as the AWS_ROLE_ARN repository variable in GitHub."
  value       = aws_iam_role.deploy.arn
}

output "role_name" {
  description = "Name of the GitHub Actions role."
  value       = aws_iam_role.deploy.name
}

output "oidc_provider_arn" {
  description = "ARN of the OIDC provider in use, whether created here or supplied."
  value       = local.provider_arn
}

output "trusted_subjects" {
  description = "Exactly which repo/ref combinations may assume the role. Worth reading back."
  value       = local.subjects
}
