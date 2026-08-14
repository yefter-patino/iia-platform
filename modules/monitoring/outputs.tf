output "sns_topic_arn" {
  description = "Topic alarms publish to."
  value       = aws_sns_topic.alerts.arn
}

output "subscription_pending" {
  description = "True if an email subscription exists but may still need confirming. AWS will not report the real state until the link is clicked."
  value       = var.alert_email != ""
}

output "dashboard_name" {
  description = "CloudWatch dashboard name."
  value       = aws_cloudwatch_dashboard.main.dashboard_name
}

output "alarm_names" {
  description = "Every alarm this module creates."
  value = compact([
    try(aws_cloudwatch_metric_alarm.service_down[0].alarm_name, ""),
    try(aws_cloudwatch_metric_alarm.api_errors[0].alarm_name, ""),
    aws_cloudwatch_metric_alarm.emr_idle.alarm_name,
  ])
}
