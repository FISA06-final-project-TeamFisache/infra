#############################################
# Security Groups
#  internal : VPC 내부 통신 전체 허용
#             (EC2 ↔ Kafka ↔ AI ↔ monitoring scrape)
#             RDS 접속은 EC2 가 internal SG 멤버이므로 rds SG(5432) 인그레스로 허용됨
#             (rds SG 정의는 rds.tf)
#  접속(SSH)은 SSM Session Manager로 → 인터넷 인바운드 규칙 불필요.
#  아웃바운드는 전체 허용 → NAT/SSM/패키지설치/외부 API 동작.
#############################################
resource "aws_security_group" "internal" {
  name        = "${var.project}-internal"
  description = "Internal VPC traffic only; egress all (NAT/SSM)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "VPC internal"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-internal" }
}

#############################################
# (추후) ALB용 SG — 외부 80/443 받는 ALB에 붙임.
# ALB 도입 시 주석 해제하고, app EC2 internal SG에
# "ALB SG로부터의 8080 허용" 규칙을 추가.
#############################################
# resource "aws_security_group" "alb" {
#   name        = "${var.project}-alb"
#   description = "Public HTTP/HTTPS for ALB"
#   vpc_id      = aws_vpc.main.id
#
#   ingress {
#     from_port   = 80
#     to_port     = 80
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   ingress {
#     from_port   = 443
#     to_port     = 443
#     protocol    = "tcp"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   egress {
#     from_port   = 0
#     to_port     = 0
#     protocol    = "-1"
#     cidr_blocks = ["0.0.0.0/0"]
#   }
#   tags = { Name = "${var.project}-alb" }
# }
