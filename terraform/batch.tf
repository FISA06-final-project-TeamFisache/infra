#############################################
# Spring Batch 전용 EC2 + EventBridge Scheduler 자동 start/stop
#
#  목적: 배치는 정해진 시간에만 돌면 되므로,
#        스케줄에 맞춰 EC2를 켰다(start) 끄는(stop) 방식으로 비용 절감.
#
#  사용: terraform.tfvars 에 enable_batch = true 설정 후 apply.
#  비활성(기본값)일 때는 아무 리소스도 생기지 않음(count = 0).
#############################################

locals {
  batch_count = var.enable_batch ? 1 : 0
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

#############################################
# 배치 EC2 (private, SSM 접속, 다른 인스턴스와 동일 SG)
#############################################
resource "aws_instance" "batch" {
  count = local.batch_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.batch_instance_type
  subnet_id              = aws_subnet.private[var.batch_subnet_index].id
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids = [aws_security_group.internal.id]
  key_name               = var.key_name != "" ? var.key_name : null

  root_block_device {
    volume_size = 20
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-batch" }
}

#############################################
# EventBridge Scheduler가 EC2를 start/stop 하도록 허용하는 IAM 역할
#############################################
data "aws_iam_policy_document" "scheduler_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "batch_scheduler" {
  count              = local.batch_count
  name               = "${var.project}-batch-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume.json
}

resource "aws_iam_role_policy" "batch_scheduler" {
  count = local.batch_count
  name  = "${var.project}-batch-startstop"
  role  = aws_iam_role.batch_scheduler[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect   = "Allow"
      Action   = ["ec2:StartInstances", "ec2:StopInstances"]
      Resource = "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.batch[0].id}"
    }]
  })
}

#############################################
# 스케줄: 시작 / 중지
#  - aws-sdk 유니버설 타깃으로 EC2 API 직접 호출
#  - 시간대는 var.schedule_timezone (기본 Asia/Seoul)
#############################################
resource "aws_scheduler_schedule" "batch_start" {
  count = local.batch_count
  name  = "${var.project}-batch-start"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = var.batch_start_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:startInstances"
    role_arn = aws_iam_role.batch_scheduler[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.batch[0].id] })
  }
}

resource "aws_scheduler_schedule" "batch_stop" {
  count = local.batch_count
  name  = "${var.project}-batch-stop"

  flexible_time_window { mode = "OFF" }
  schedule_expression          = var.batch_stop_cron
  schedule_expression_timezone = var.schedule_timezone

  target {
    arn      = "arn:aws:scheduler:::aws-sdk:ec2:stopInstances"
    role_arn = aws_iam_role.batch_scheduler[0].arn
    input    = jsonencode({ InstanceIds = [aws_instance.batch[0].id] })
  }
}
