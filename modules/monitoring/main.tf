# ---------------------------------------------------------------------------
# MONITORING MODULE  (Phase 8)
#
# CloudWatch alarms, an SNS topic that emails you, and a dashboard.
#
# The design rule here: every alarm must correspond to something a human would
# actually do something about at 2am. An alarm nobody acts on trains people to
# ignore the channel it arrives on, which is worse than having no alarm.
#
# So there is no "CPU above 80%" alarm. On a 0.25 vCPU Fargate task, brief CPU
# saturation is normal and there is no action to take. What is here instead:
#
#   - the service has no running tasks       -> the API is down
#   - the container is logging errors        -> something is broken
#   - an EMR cluster has been alive too long -> money is leaking
#
# That last one is the important one for this project. Everything else in the
# lab fails cheaply; a forgotten EMR cluster does not.
#
# Cost: ~$0.10 per alarm per month, plus SNS email which is free. Dashboards
# are free up to three.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"
}

data "aws_region" "current" {}

# --- Where alarms go --------------------------------------------------------

resource "aws_sns_topic" "alerts" {
  name = "${local.name}-alerts"

  tags = merge(var.tags, {
    Name = "${local.name}-alerts"
  })
}

# AWS sends a confirmation email and the subscription stays PendingConfirmation
# until the link is clicked. Terraform reports success either way, so an
# unconfirmed subscription looks exactly like a working one right up until the
# first alarm goes nowhere.
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email == "" ? 0 : 1

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# --- The API is down --------------------------------------------------------

resource "aws_cloudwatch_metric_alarm" "service_down" {
  count = var.ecs_cluster_name == "" ? 0 : 1

  alarm_name        = "${local.name}-api-no-running-tasks"
  alarm_description = "The API service has no running tasks. Either it was scaled to zero on purpose, or it is crash-looping."

  namespace   = "ECS/ContainerInsights"
  metric_name = "RunningTaskCount"
  statistic   = "Average"
  period      = 60

  dimensions = {
    ClusterName = var.ecs_cluster_name
    ServiceName = var.ecs_service_name
  }

  comparison_operator = "LessThanThreshold"
  threshold           = 1
  evaluation_periods  = 3

  # `missing` rather than `breaching`: this lab scales the service to zero
  # deliberately, and ContainerInsights stops publishing when nothing runs.
  # Treating missing data as breaching would page you for saving money.
  treat_missing_data = "missing"

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, { Name = "${local.name}-api-no-running-tasks" })
}

# --- The container is logging errors ----------------------------------------
#
# A metric filter turns log lines into a number. This is how you alarm on
# something that is not already a metric.

resource "aws_cloudwatch_log_metric_filter" "errors" {
  count = var.log_group_name == "" ? 0 : 1

  name           = "${local.name}-api-errors"
  log_group_name = var.log_group_name

  # Matches ERROR, Traceback, and 5xx responses in uvicorn's access log.
  pattern = "?ERROR ?Traceback ?\" 500 \" ?\" 502 \" ?\" 503 \""

  metric_transformation {
    name      = "ApiErrorCount"
    namespace = "${var.name_prefix}/${var.environment}"
    value     = "1"

    # Without this, periods with no errors publish nothing rather than zero,
    # and the alarm sits in INSUFFICIENT_DATA instead of OK. A dashboard full
    # of grey is a dashboard nobody reads.
    default_value = 0
  }
}

resource "aws_cloudwatch_metric_alarm" "api_errors" {
  count = var.log_group_name == "" ? 0 : 1

  alarm_name        = "${local.name}-api-errors"
  alarm_description = "The API logged errors. Check the log group for the traceback."

  namespace   = "${var.name_prefix}/${var.environment}"
  metric_name = "ApiErrorCount"
  statistic   = "Sum"
  period      = 300

  comparison_operator = "GreaterThanThreshold"
  threshold           = var.error_threshold
  evaluation_periods  = 1

  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, { Name = "${local.name}-api-errors" })

  depends_on = [aws_cloudwatch_log_metric_filter.errors]
}

# --- A cluster has been running too long ------------------------------------
#
# The one that protects the wallet. EMR publishes IsIdle, and a transient
# cluster that finished its work but did not terminate will sit idle, billing.

resource "aws_cloudwatch_metric_alarm" "emr_idle" {
  alarm_name        = "${local.name}-emr-cluster-idle"
  alarm_description = "An EMR cluster has been idle for ${var.emr_idle_minutes} minutes. A transient cluster should have terminated itself -- this one is billing for nothing."

  namespace   = "AWS/ElasticMapReduce"
  metric_name = "IsIdle"
  statistic   = "Maximum"
  period      = 300

  comparison_operator = "GreaterThanOrEqualToThreshold"
  threshold           = 1
  evaluation_periods  = ceil(var.emr_idle_minutes / 5)

  # No clusters running means no data, which is the normal state here and
  # emphatically not a problem.
  treat_missing_data = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = merge(var.tags, { Name = "${local.name}-emr-cluster-idle" })
}

# --- Dashboard --------------------------------------------------------------

resource "aws_cloudwatch_dashboard" "main" {
  dashboard_name = "${local.name}-platform"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "text"
        x      = 0
        y      = 0
        width  = 24
        height = 2
        properties = {
          markdown = "# ${local.name} platform\nLake, API and cluster health. Alarms email ${var.alert_email == "" ? "(no address configured)" : var.alert_email}."
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Raw bucket size"
          region = data.aws_region.current.region
          view   = "timeSeries"
          metrics = [
            ["AWS/S3", "BucketSizeBytes", "BucketName", var.raw_bucket_name, "StorageType", "StandardStorage"],
          ]
          # S3 storage metrics are published once a day, so a shorter period
          # shows an empty graph and looks broken.
          period = 86400
          stat   = "Average"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 2
        width  = 12
        height = 6
        properties = {
          title  = "Athena bytes scanned (the money metric)"
          region = data.aws_region.current.region
          view   = "timeSeries"
          metrics = [
            ["AWS/Athena", "ProcessedBytes", "WorkGroup", var.athena_workgroup_name],
          ]
          period = 3600
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "API errors"
          region = data.aws_region.current.region
          view   = "timeSeries"
          metrics = [
            ["${var.name_prefix}/${var.environment}", "ApiErrorCount"],
          ]
          period = 300
          stat   = "Sum"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 8
        width  = 12
        height = 6
        properties = {
          title  = "EMR: is a cluster running?"
          region = data.aws_region.current.region
          view   = "timeSeries"
          metrics = [
            ["AWS/ElasticMapReduce", "IsIdle"],
          ]
          period = 300
          stat   = "Maximum"
        }
      },
    ]
  })
}
