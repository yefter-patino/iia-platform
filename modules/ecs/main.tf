# ---------------------------------------------------------------------------
# ECS MODULE  (Phase 6)
#
# Runs the FastAPI container on Fargate, in the private subnets, with no
# credentials anywhere in the image.
#
# The two-role split below is the part worth understanding, because it is the
# most commonly conflated pair in ECS:
#
#   execution role  belongs to the ECS AGENT, not your code. Used before the
#                   container starts: pull the image from ECR, create the log
#                   group, fetch secrets injected as environment variables.
#   task role       belongs to YOUR PROCESS. What boto3 inside the container
#                   picks up. This is the one that reads S3 and Athena.
#
# Giving the execution role your application's permissions is the usual
# mistake. It works, which is why it survives, but it means every image pull
# happens with your data permissions attached.
#
# Cost: Fargate bills per vCPU-second and GB-second while a task runs. 0.25
# vCPU / 0.5 GB is about $0.012/hour, roughly $9/month if left running. The
# desired_count variable is the off switch -- set it to 0 and the service
# stays defined but nothing runs and nothing bills.
# ---------------------------------------------------------------------------

locals {
  name = "${var.name_prefix}-${var.environment}"
}

data "aws_region" "current" {}

# --- Log group --------------------------------------------------------------
# Created here rather than left to ECS so it has a retention policy. A log
# group created implicitly keeps logs forever and bills for the privilege.

resource "aws_cloudwatch_log_group" "service" {
  name              = "/ecs/${local.name}-api"
  retention_in_days = var.log_retention_days

  tags = merge(var.tags, {
    Name = "/ecs/${local.name}-api"
  })
}

# --- Execution role (the agent) ---------------------------------------------

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  name               = "${local.name}-ecs-execution"
  description        = "Used by the ECS agent to pull images and write logs. Not by the application."
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = merge(var.tags, { Name = "${local.name}-ecs-execution" })
}

resource "aws_iam_role_policy_attachment" "execution" {
  role       = aws_iam_role.execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# --- Task role (the application) --------------------------------------------

resource "aws_iam_role" "task" {
  name               = "${local.name}-ecs-task"
  description        = "Assumed by the application process. This is what boto3 inside the container uses."
  assume_role_policy = data.aws_iam_policy_document.ecs_assume.json

  tags = merge(var.tags, { Name = "${local.name}-ecs-task" })
}

data "aws_iam_policy_document" "task" {
  statement {
    sid       = "ReadLakeBuckets"
    effect    = "Allow"
    actions   = ["s3:GetObject", "s3:ListBucket"]
    resources = [var.raw_bucket_arn, "${var.raw_bucket_arn}/*", var.curated_bucket_arn, "${var.curated_bucket_arn}/*"]
  }

  # Athena writes every result to the results bucket, so a read-only API still
  # needs write access there. Surprising until you remember the query engine
  # persists results before returning them.
  statement {
    sid    = "AthenaResults"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:ListBucket",
      "s3:GetBucketLocation", "s3:AbortMultipartUpload",
    ]
    resources = [var.athena_results_bucket_arn, "${var.athena_results_bucket_arn}/*"]
  }

  statement {
    sid    = "RunAthenaQueries"
    effect = "Allow"
    actions = [
      "athena:StartQueryExecution",
      "athena:GetQueryExecution",
      "athena:GetQueryResults",
      "athena:StopQueryExecution",
    ]
    resources = [var.athena_workgroup_arn]
  }

  statement {
    sid    = "ReadCatalog"
    effect = "Allow"
    actions = [
      "glue:GetDatabase", "glue:GetDatabases",
      "glue:GetTable", "glue:GetTables",
      "glue:GetPartition", "glue:GetPartitions",
    ]
    resources = ["*"]
  }

  statement {
    sid       = "ReadTheOneSecret"
    effect    = "Allow"
    actions   = ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret"]
    resources = [var.secret_arn]
  }

  statement {
    sid       = "DecryptWithTheSecretsKey"
    effect    = "Allow"
    actions   = ["kms:Decrypt"]
    resources = [var.kms_key_arn]

    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${data.aws_region.current.region}.amazonaws.com"]
    }
  }

  # ECS Exec. Setting enable_execute_command on the service is only half of
  # it -- the TASK role (not the execution role) needs these, because the SSM
  # agent runs inside your container and uses your identity. Without them the
  # service starts fine and `aws ecs execute-command` fails with
  # "TargetNotConnectedException", which reads like a networking problem and
  # is not one.
  dynamic "statement" {
    for_each = var.enable_execute_command ? [1] : []

    content {
      sid    = "EcsExecSessionManagerChannels"
      effect = "Allow"

      actions = [
        "ssmmessages:CreateControlChannel",
        "ssmmessages:CreateDataChannel",
        "ssmmessages:OpenControlChannel",
        "ssmmessages:OpenDataChannel",
      ]

      resources = ["*"]
    }
  }
}

resource "aws_iam_role_policy" "task" {
  name   = "${local.name}-ecs-task"
  role   = aws_iam_role.task.id
  policy = data.aws_iam_policy_document.task.json
}

# --- Security group ---------------------------------------------------------

resource "aws_security_group" "service" {
  name        = "${local.name}-ecs-service"
  description = "FastAPI task. Outbound only -- nothing on the internet reaches it."
  vpc_id      = var.vpc_id

  tags = merge(var.tags, { Name = "${local.name}-ecs-service" })
}

# No inbound rules at all. There is no load balancer in this phase: an ALB is
# ~$16/month, which is more than everything else in this project combined.
# The service is reached with `aws ecs execute-command` or by adding an ALB
# when something actually needs to call it from outside.
resource "aws_vpc_security_group_egress_rule" "service_all_out" {
  security_group_id = aws_security_group.service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Outbound to ECR, S3, Athena, Secrets Manager"
}

# --- Cluster, task definition, service --------------------------------------

resource "aws_ecs_cluster" "this" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = var.enable_container_insights ? "enabled" : "disabled"
  }

  tags = merge(var.tags, { Name = "${local.name}-cluster" })
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.name}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.task_cpu
  memory                   = var.task_memory

  execution_role_arn = aws_iam_role.execution.arn
  task_role_arn      = aws_iam_role.task.arn

  runtime_platform {
    operating_system_family = "LINUX"
    # The image is built on an arm64 Mac. Saying so explicitly avoids the
    # "exec format error" that appears at runtime rather than at deploy time.
    cpu_architecture = var.cpu_architecture
  }

  container_definitions = jsonencode([
    {
      name      = "api"
      image     = var.image_uri
      essential = true

      portMappings = [{ containerPort = 8000, protocol = "tcp" }]

      environment = [
        { name = "AWS_REGION", value = data.aws_region.current.region },
        { name = "RAW_BUCKET", value = var.raw_bucket_name },
        { name = "CURATED_BUCKET", value = var.curated_bucket_name },
        { name = "GLUE_DATABASE", value = var.glue_database_name },
        { name = "ATHENA_WORKGROUP", value = var.athena_workgroup_name },
        { name = "SECRET_NAME", value = var.secret_name },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.service.name
          "awslogs-region"        = data.aws_region.current.region
          "awslogs-stream-prefix" = "api"
        }
      }

      healthCheck = {
        command     = ["CMD-SHELL", "python -c \"import urllib.request;urllib.request.urlopen('http://localhost:8000/healthz')\" || exit 1"]
        interval    = 30
        timeout     = 5
        retries     = 3
        startPeriod = 30
      }
    }
  ])

  tags = merge(var.tags, { Name = "${local.name}-api" })
}

resource "aws_ecs_service" "api" {
  name            = "${local.name}-api"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.api.arn
  launch_type     = "FARGATE"

  # 0 means the service exists but nothing runs and nothing bills. This is the
  # off switch, and it is a variable so turning the lab off is a one-line
  # change rather than a destroy.
  desired_count = var.desired_count

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = [aws_security_group.service.id]
    assign_public_ip = false
  }

  # Lets `aws ecs execute-command` open a shell in the task, which is how you
  # reach a service that has no load balancer and no inbound rules.
  enable_execute_command = var.enable_execute_command

  tags = merge(var.tags, { Name = "${local.name}-api" })
}
