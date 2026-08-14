output "remote_reader_role_arn" {
  description = "Role ARN the partner account assumes."
  value       = aws_iam_role.remote_reader.arn
}

output "caller_policy_arn" {
  description = "Policy to attach in the CALLING account, granting sts:AssumeRole on the role above."
  value       = aws_iam_policy.caller.arn
}

output "is_same_account_simulation" {
  description = "True when no separate trusted account was supplied, meaning both halves live in one account."
  value       = var.trusted_account_id == ""
}

output "assume_command" {
  description = "Ready-to-run command demonstrating the handshake."
  value = format(
    "aws sts assume-role --role-arn %s --role-session-name demo%s",
    aws_iam_role.remote_reader.arn,
    var.external_id == "" ? "" : " --external-id ${var.external_id}",
  )
}
