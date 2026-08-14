output "cluster_name" {
  description = "ECS cluster name."
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN."
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS service name."
  value       = aws_ecs_service.api.name
}

output "task_definition_arn" {
  description = "Task definition ARN, including revision."
  value       = aws_ecs_task_definition.api.arn
}

output "task_role_arn" {
  description = "Role the application process assumes. This is what boto3 in the container picks up."
  value       = aws_iam_role.task.arn
}

output "execution_role_arn" {
  description = "Role the ECS agent uses to pull images and write logs."
  value       = aws_iam_role.execution.arn
}

output "security_group_id" {
  description = "Security group attached to the task ENIs."
  value       = aws_security_group.service.id
}

output "log_group_name" {
  description = "CloudWatch log group for container output."
  value       = aws_cloudwatch_log_group.service.name
}
