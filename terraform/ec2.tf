#############################################
# AMI: 최신 Amazon Linux 2023 (x86_64, SSM 에이전트 기본 탑재)
#############################################
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-x86_64"]
  }
}

#############################################
# EC2 인스턴스 (전부 private 서브넷, 2 AZ 분산)
#  - 공인 IP 없음 / 접속은 SSM
#  - 아웃바운드는 NAT 경유
#############################################
resource "aws_instance" "this" {
  for_each = var.instances

  ami                    = data.aws_ami.al2023.id
  instance_type          = each.value.instance_type
  subnet_id              = aws_subnet.private[each.value.subnet_index].id
  iam_instance_profile   = aws_iam_instance_profile.ssm.name
  vpc_security_group_ids  = [aws_security_group.internal.id]
  key_name               = var.key_name != "" ? var.key_name : null

  root_block_device {
    volume_size = 20    # GB
    volume_type = "gp3"
  }

  tags = { Name = "${var.project}-${each.key}" }
}
