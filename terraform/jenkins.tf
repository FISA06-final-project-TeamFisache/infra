#############################################
# Jenkins (CI/CD) EC2 — private, SSM 포트포워딩으로만 접근
#  - enable_jenkins 플래그로 on/off (비용 제어). 기본 on.
#  - private 서브넷이라 GitHub webhook 수신 불가 → SCM 폴링 또는 수동 빌드.
#  - 전용 IAM: 다른 EC2에 SSM send-command(배포) + 프론트 S3 업로드 + CloudFront 무효화
#    → redeploy.ps1 이 로컬에서 하던 일을 파이프라인으로 옮길 수 있음 (deploy/*.sh 재사용).
#############################################

locals {
  jenkins_count = var.enable_jenkins ? 1 : 0
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

resource "aws_instance" "jenkins" {
  count = local.jenkins_count

  ami                    = data.aws_ami.al2023.id
  instance_type          = var.jenkins_instance_type
  subnet_id              = aws_subnet.private[var.jenkins_subnet_index].id
  iam_instance_profile   = aws_iam_instance_profile.jenkins[0].name
  vpc_security_group_ids = [aws_security_group.internal.id]
  key_name               = var.key_name != "" ? var.key_name : null

  user_data = templatefile("${path.module}/bootstrap.sh.tftpl", {
    role            = "jenkins"
    github_org      = var.github_org
    compose_version = var.compose_version
  })

  root_block_device {
    volume_size = 30 # 빌드 캐시/도커 이미지 여유분 (다른 EC2보다 크게)
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-jenkins" }
}

#############################################
# Jenkins 전용 IAM
#  - 공용 ssm 역할에 배포 권한을 주면 모든 EC2가 갖게 되므로 분리.
#  - SSM core(접속) + send-command(타 EC2 배포) + S3/CloudFront(프론트 배포)
#############################################
resource "aws_iam_role" "jenkins" {
  count              = local.jenkins_count
  name               = "${var.project}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "jenkins_ssm_core" {
  count      = local.jenkins_count
  role       = aws_iam_role.jenkins[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "jenkins_deploy" {
  statement {
    sid     = "SendCommand"
    actions = ["ssm:SendCommand"]
    resources = [
      "arn:aws:ssm:${data.aws_region.current.name}::document/AWS-RunShellScript",
      "arn:aws:ec2:${data.aws_region.current.name}:${data.aws_caller_identity.current.account_id}:instance/*",
    ]
  }
  statement {
    sid = "ReadCommandResult"
    actions = [
      "ssm:GetCommandInvocation",
      "ssm:ListCommands",
      "ssm:ListCommandInvocations",
      "ssm:DescribeInstanceInformation",
    ]
    resources = ["*"]
  }
  statement {
    sid       = "DescribeInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }
  statement {
    sid       = "S3Frontend"
    actions   = ["s3:ListBucket", "s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = [aws_s3_bucket.frontend.arn, "${aws_s3_bucket.frontend.arn}/*"]
  }
  statement {
    sid       = "CloudFrontInvalidate"
    actions   = ["cloudfront:CreateInvalidation", "cloudfront:GetInvalidation"]
    resources = [aws_cloudfront_distribution.main.arn]
  }
}

resource "aws_iam_role_policy" "jenkins_deploy" {
  count  = local.jenkins_count
  name   = "${var.project}-jenkins-deploy"
  role   = aws_iam_role.jenkins[0].id
  policy = data.aws_iam_policy_document.jenkins_deploy.json
}

resource "aws_iam_instance_profile" "jenkins" {
  count = local.jenkins_count
  name  = "${var.project}-jenkins-profile"
  role  = aws_iam_role.jenkins[0].name
}
