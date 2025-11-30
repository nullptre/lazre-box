terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.0"
    }
  }
}

provider "aws" {
  region = "eu-central-1"
}

#####################
# Variables
#####################

variable "project_prefix" {
  description = "Prefix for all resources for this Lazre deployment."
  type        = string
  default     = "remont_pl_lazre"
}

variable "efs_root_directory" {
  description = "Root directory on the EFS file system for this deployment (per-instance logical root)."
  type        = string
  default     = "/remont_pl_data"
}

variable "bot_desired_count" {
  description = "How many bot tasks the ECS service should keep running (0 for initial setup, 1 for normal operation)."
  type        = number
  default     = 0
}

variable "helper_ssh_key_name" {
  description = "EC2 key pair name used for SSH access to the EFS helper instance (must exist in eu-central-1)."
  type        = string
}

variable "helper_ssh_cidr" {
  description = "CIDR allowed to SSH into the EFS helper EC2 instance (e.g. your current public IP/32)."
  type        = string
  default     = "83.24.12.45/32"
}

#####################
# Networking (default VPC)
#####################

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "default" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
}

resource "aws_security_group" "tasks" {
  name        = "${var.project_prefix}-tasks-sg"
  description = "Security group for Lazre ECS tasks"
  vpc_id      = data.aws_vpc.default.id

  # Outbound to internet (Telegram, OpenAI, web)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-tasks-sg"
  }
}

resource "aws_security_group" "efs" {
  name        = "${var.project_prefix}-efs-sg"
  description = "Security group for Lazre EFS"
  vpc_id      = data.aws_vpc.default.id

  # Allow NFS from ECS tasks
  ingress {
    from_port       = 2049
    to_port         = 2049
    protocol        = "tcp"
    security_groups = [aws_security_group.tasks.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-efs-sg"
  }
}

resource "aws_security_group" "helper_ssh" {
  name        = "${var.project_prefix}-helper-ssh-sg"
  description = "Security group for SSH access to EFS helper EC2 instance"
  vpc_id      = data.aws_vpc.default.id

  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.helper_ssh_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.project_prefix}-helper-ssh-sg"
  }
}

#####################
# EFS for /var/lib/lazre
#####################

resource "aws_efs_file_system" "this" {
  creation_token = "${var.project_prefix}-efs"
  encrypted      = true

  # Optional: move cold data to Infrequent Access after 30 days
  lifecycle_policy {
    transition_to_ia = "AFTER_30_DAYS"
  }

  tags = {
    Name = "${var.project_prefix}-efs"
  }
}

resource "aws_efs_mount_target" "this" {
  for_each       = toset(data.aws_subnets.default.ids)
  file_system_id = aws_efs_file_system.this.id
  subnet_id      = each.key
  security_groups = [
    aws_security_group.efs.id
  ]
}

# NOTE:
# After this stack is applied, you must manually put your `.env` file
# and `config_*.json` files into the EFS directory for this instance:
#   <EFS root>${var.efs_root_directory}/.env
#   <EFS root>${var.efs_root_directory}/config/...
# The containers will mount this directory at /var/lib/lazre.

#####################
# ECS Cluster
#####################

resource "aws_ecs_cluster" "this" {
  name = "${var.project_prefix}-cluster"
}

#####################
# IAM Roles
#####################

data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "ecs_task_execution" {
  name               = "${var.project_prefix}-task-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
}

resource "aws_iam_role_policy_attachment" "ecs_task_execution" {
  role       = aws_iam_role.ecs_task_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "ecs_task" {
  name               = "${var.project_prefix}-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json
  # No extra AWS permissions needed for now (bot/indexer use external APIs only).
}

#####################
# CloudWatch Logs
#####################
# NOTE: CloudWatch Logs are not completely free; they are usually very cheap
# for low-volume logs, but there may be a small monthly cost.

resource "aws_cloudwatch_log_group" "bot" {
  name              = "/${var.project_prefix}/cloud-watch-logs/bot"
  retention_in_days = 30
}

resource "aws_cloudwatch_log_group" "indexer" {
  name              = "/${var.project_prefix}/cloud-watch-logs/indexer"
  retention_in_days = 30
}

#####################
# Helper EC2 instance for managing EFS contents
#####################

data "aws_ami" "amazon_linux_2" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["amzn2-ami-hvm-*-x86_64-gp2"]
  }

  filter {
    name   = "root-device-type"
    values = ["ebs"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

resource "aws_instance" "efs_helper" {
  ami           = data.aws_ami.amazon_linux_2.id
  instance_type = "t3.micro"

  subnet_id = element(data.aws_subnets.default.ids, 0)

  vpc_security_group_ids = [
    aws_security_group.tasks.id,
    aws_security_group.helper_ssh.id,
  ]

  key_name = var.helper_ssh_key_name

  root_block_device {
    volume_size           = 8
    volume_type           = "gp3"
    delete_on_termination = true
  }

  instance_initiated_shutdown_behavior = "stop"

  user_data = <<-EOF
              #!/bin/bash
              set -euo pipefail

              # NOTE:
              # This script does NOT use the AWS CLI or require explicit AWS credentials.
              # The EFS mount works purely because:
              #   - The instance is in the same VPC/subnets as the EFS mount targets, and
              #   - Security groups allow NFS (port 2049) between the instance and EFS.
              # Access is controlled by networking, not IAM credentials.

              yum update -y || true
              yum install -y amazon-efs-utils nfs-utils

              MOUNT_POINT="/mnt/efs"
              INSTANCE_ROOT_DIR="${var.efs_root_directory}"

              mkdir -p "${MOUNT_POINT}"

              # Mount EFS (encrypted over TLS). This will not delete any existing data.
              mount -t efs -o tls ${aws_efs_file_system.this.id}:/ "${MOUNT_POINT}"

              # Ensure the per-instance root directory and config subdirectory exist.
              # If they already exist, mkdir -p will not delete or overwrite them.
              mkdir -p "${MOUNT_POINT}${INSTANCE_ROOT_DIR}/config"

              # Make the directory writable by the default ec2-user.
              chown -R ec2-user:ec2-user "${MOUNT_POINT}${INSTANCE_ROOT_DIR}" || true
              EOF

  tags = {
    Name = "${var.project_prefix}-efs-helper"
  }
}

#####################
# ECS Task Definitions
#####################

# Shared EFS volume block
locals {
  lazre_volume = {
    name = "lazre_data"

    efs_volume_configuration = {
      file_system_id     = aws_efs_file_system.this.id
      transit_encryption = "ENABLED"
      root_directory     = var.efs_root_directory
    }
  }
}

# Bot task (always on, small)
resource "aws_ecs_task_definition" "bot" {
  family                   = "${var.project_prefix}-bot"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "512"    # 0.5 vCPU
  memory                   = "1024"   # 1 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  volume {
    name = local.lazre_volume.name

    efs_volume_configuration {
      file_system_id     = local.lazre_volume.efs_volume_configuration.file_system_id
      transit_encryption = local.lazre_volume.efs_volume_configuration.transit_encryption
      root_directory     = local.lazre_volume.efs_volume_configuration.root_directory
    }
  }

  container_definitions = jsonencode([
    {
      name      = "bot"
      image     = "ghcr.io/nullptre/lazre-box:latest"
      essential = true

      # Default entrypoint/command of the image runs the Telegram bot.

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.bot.name
          awslogs-region        = "eu-central-1"
          awslogs-stream-prefix = "bot"
        }
      }

      mountPoints = [
        {
          sourceVolume  = local.lazre_volume.name
          containerPath = "/var/lib/lazre"
          readOnly      = false
        }
      ]

      # Environment variables (OPENAI_API_KEY, TELEGRAM_BOT_TOKEN, etc.)
      # are expected to be loaded from /var/lib/lazre/.env on EFS by the app.
    }
  ])
}

# Indexer task (on demand, big)
resource "aws_ecs_task_definition" "indexer" {
  family                   = "${var.project_prefix}-indexer"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "4096"    # 4 vCPU
  memory                   = "16384"   # 16 GB
  execution_role_arn       = aws_iam_role.ecs_task_execution.arn
  task_role_arn            = aws_iam_role.ecs_task.arn

  volume {
    name = local.lazre_volume.name

    efs_volume_configuration {
      file_system_id     = local.lazre_volume.efs_volume_configuration.file_system_id
      transit_encryption = local.lazre_volume.efs_volume_configuration.transit_encryption
      root_directory     = local.lazre_volume.efs_volume_configuration.root_directory
    }
  }

  container_definitions = jsonencode([
    {
      name      = "indexer"
      image     = "ghcr.io/nullptre/lazre-box:latest"
      essential = true

      # Run the standalone indexing script via dedicated startup script.
      command = ["/app/start_indexing.sh"]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.indexer.name
          awslogs-region        = "eu-central-1"
          awslogs-stream-prefix = "indexer"
        }
      }

      mountPoints = [
        {
          sourceVolume  = local.lazre_volume.name
          containerPath = "/var/lib/lazre"
          readOnly      = false
        }
      ]
    }
  ])
}

#####################
# ECS Service (Bot)
#####################

resource "aws_ecs_service" "bot" {
  name            = "${var.project_prefix}-bot"
  cluster         = aws_ecs_cluster.this.id
  task_definition = aws_ecs_task_definition.bot.arn
  desired_count   = var.bot_desired_count
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.default.ids
    security_groups = [aws_security_group.tasks.id]
    assign_public_ip = true
  }

  depends_on = [aws_efs_mount_target.this]
}

#####################
# EventBridge -> ECS (Indexer schedule)
#####################

data "aws_iam_policy_document" "events_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource "aws_iam_role" "events_to_ecs" {
  name               = "${var.project_prefix}-events-to-ecs-role"
  assume_role_policy = data.aws_iam_policy_document.events_assume_role.json
}

data "aws_iam_policy_document" "events_to_ecs" {
  statement {
    effect = "Allow"
    actions = [
      "ecs:RunTask",
    ]
    resources = [
      aws_ecs_task_definition.indexer.arn,
      "${aws_ecs_task_definition.indexer.arn}:*",
    ]
  }

  statement {
    effect = "Allow"
    actions = [
      "iam:PassRole",
    ]
    resources = [
      aws_iam_role.ecs_task_execution.arn,
      aws_iam_role.ecs_task.arn,
    ]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "events_to_ecs" {
  name   = "${var.project_prefix}-events-to-ecs-policy"
  role   = aws_iam_role.events_to_ecs.id
  policy = data.aws_iam_policy_document.events_to_ecs.json
}

resource "aws_cloudwatch_event_rule" "indexer_schedule" {
  name        = "${var.project_prefix}-indexer-schedule"
  description = "Run Lazre indexing on Sunday and Wednesday at 03:00 UTC"
  # cron(0 3 ? * SUN,WED *)
  schedule_expression = "cron(0 3 ? * SUN,WED *)"
}

resource "aws_cloudwatch_event_target" "indexer_to_ecs" {
  rule      = aws_cloudwatch_event_rule.indexer_schedule.name
  target_id = "${var.project_prefix}-indexer"
  arn       = aws_ecs_cluster.this.arn
  role_arn  = aws_iam_role.events_to_ecs.arn

  ecs_target {
    launch_type         = "FARGATE"
    task_definition_arn = aws_ecs_task_definition.indexer.arn
    platform_version    = "1.4.0"

    network_configuration {
      subnets         = data.aws_subnets.default.ids
      security_groups = [aws_security_group.tasks.id]
      assign_public_ip = "ENABLED"
    }
  }
}

#####################
# Outputs
#####################

output "ecs_cluster_name" {
  value = aws_ecs_cluster.this.name
}

output "efs_id" {
  value = aws_efs_file_system.this.id
}

output "project_prefix" {
  value = var.project_prefix
}


