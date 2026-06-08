#############################################
# ALB (public, 2 AZ) — CloudFront 의 동적 origin
#  - 브라우저는 CloudFront(HTTPS)로만 접근. ALB 는 CloudFront 뒤의 origin.
#  - default → backend(8080), ai 경로 → ai-server(8000) 로 path 라우팅.
#  - ALB→EC2 통신은 기존 internal SG(VPC 내부 전체 허용)로 이미 가능 → SG 추가 불필요.
#############################################

locals {
  # CloudFront 에서 "정적(S3)이 아니라 ALB origin 으로" 보낼 경로들.
  # 나머지 전부(/, /dashboard 등 SPA 라우트)는 S3 로 감.
  alb_path_patterns = [
    "/api/*", "/actuator/*",
    "/consultant/*", "/portfolio/*", "/mini_challenge/*",
    "/report", "/report/*", "/salary", "/salary/*", "/propose",
  ]

  # 위 ALB 경로 중에서도 backend(8080) 가 아니라 ai-server(8000) 로 보낼 경로.
  # (ALB listener rule 의 path-pattern 은 조건당 최대 5개라 두 규칙으로 분할)
  ai_path_patterns_a = ["/consultant/*", "/portfolio/*", "/mini_challenge/*", "/report", "/report/*"]
  ai_path_patterns_b = ["/salary", "/salary/*", "/propose"]
}

#############################################
# ALB 용 SG — 인터넷에서 80 만 받음 (CloudFront 가 호출).
#############################################
resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = "Public HTTP for ALB (fronted by CloudFront)"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "HTTP from internet (CloudFront)"
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-alb" }
}

#############################################
# ALB 본체 (public 서브넷 2 AZ)
#############################################
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  internal           = false
  security_groups    = [aws_security_group.alb.id]
  subnets            = aws_subnet.public[*].id

  tags = { Name = "${var.project}-alb" }
}

#############################################
# Target Group: backend (Spring Boot, 8080)
#  - health check: actuator (management.endpoints 에 health 노출됨)
#############################################
resource "aws_lb_target_group" "backend" {
  name        = "${var.project}-backend"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/actuator/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-backend" }
}

#############################################
# Target Group: ai-server (FastAPI, 8000)
#  - health check: GET /health
#############################################
resource "aws_lb_target_group" "ai" {
  name        = "${var.project}-ai"
  port        = 8000
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  health_check {
    path                = "/health"
    matcher             = "200"
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }

  tags = { Name = "${var.project}-ai" }
}

# 현재는 EC2 인스턴스를 직접 등록(추후 backend 오토스케일 전환 시 ASG 연결로 교체).
resource "aws_lb_target_group_attachment" "backend" {
  target_group_arn = aws_lb_target_group.backend.arn
  target_id        = aws_instance.this["app"].id
  port             = 8080
}

resource "aws_lb_target_group_attachment" "ai" {
  target_group_arn = aws_lb_target_group.ai.arn
  target_id        = aws_instance.this["ai"].id
  port             = 8000
}

#############################################
# Listener (HTTP 80) — default backend, ai 경로만 ai TG 로
#############################################
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.backend.arn
  }
}

resource "aws_lb_listener_rule" "ai_a" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai.arn
  }

  condition {
    path_pattern {
      values = local.ai_path_patterns_a
    }
  }
}

resource "aws_lb_listener_rule" "ai_b" {
  listener_arn = aws_lb_listener.http.arn
  priority     = 11

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.ai.arn
  }

  condition {
    path_pattern {
      values = local.ai_path_patterns_b
    }
  }
}
