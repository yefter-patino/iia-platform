output "state_bucket_name" {
  description = "Copy this into envs/dev/backend.hcl as the bucket value."
  value       = aws_s3_bucket.tfstate.id
}

output "aws_region" {
  description = "Region the state bucket lives in."
  value       = var.aws_region
}

output "account_id" {
  description = "The account these resources were created in."
  value       = data.aws_caller_identity.current.account_id
}
