#############################################
# RDS PostgreSQL (private, 2 AZ 서브넷 그룹)
#  - enable_rds 플래그로 on/off (비용 제어). 기본 true.
#    false 로 apply 하면 EC2/네트워크는 그대로 두고 RDS 만 사라짐.
#  - private 서브넷에만 배치 / publicly_accessible = false (외부 접근 차단)
#  - 전용 SG: 5432 를 internal SG 에서만 허용 (EC2 들만 접속)
#  - 마스터 비밀번호는 random_password 로 생성
#    → `terraform output -raw rds_password` 로 확인 (state 는 로컬/gitignore)
#  - multi_az 는 비용 때문에 기본 false(dev). 운영 전환 시 true 로만 바꾸면 됨
#    (서브넷 그룹이 이미 2 AZ 라 재생성 없이 전환 가능)
#############################################

locals {
  rds_count = var.enable_rds ? 1 : 0
}

# 지정한 major 의 최신 minor PostgreSQL 버전을 자동 선택 (버전 not-found 회피)
data "aws_rds_engine_version" "postgres" {
  engine  = "postgres"
  version = var.rds_engine_version
  latest  = true
}

resource "random_password" "rds" {
  count   = local.rds_count
  length  = 20
  special = true
  # RDS 가 금지하는 문자(/ @ " 공백) 는 제외
  override_special = "!#%^&*()-_=+[]{}"
}

resource "aws_db_subnet_group" "main" {
  count      = local.rds_count
  name       = "${var.project}-db-subnet"
  subnet_ids = aws_subnet.private[*].id
  tags       = { Name = "${var.project}-db-subnet" }
}

resource "aws_security_group" "rds" {
  count       = local.rds_count
  name        = "${var.project}-rds"
  description = "Postgres 5432 from internal SG only"
  vpc_id      = aws_vpc.main.id

  ingress {
    description     = "Postgres from VPC internal SG"
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.internal.id]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = { Name = "${var.project}-rds" }
}

resource "aws_db_instance" "main" {
  count          = local.rds_count
  identifier     = "${var.project}-postgres"
  engine         = "postgres"
  engine_version = data.aws_rds_engine_version.postgres.version
  instance_class = var.rds_instance_class

  allocated_storage     = var.rds_allocated_storage
  max_allocated_storage = var.rds_max_allocated_storage # 스토리지 오토스케일 상한
  storage_type          = "gp3"
  storage_encrypted     = true

  db_name  = var.rds_db_name
  username = var.rds_username
  password = random_password.rds[0].result
  port     = 5432

  db_subnet_group_name   = aws_db_subnet_group.main[0].name
  vpc_security_group_ids = [aws_security_group.rds[0].id]
  multi_az               = var.rds_multi_az
  publicly_accessible    = false

  auto_minor_version_upgrade = true
  backup_retention_period    = var.rds_backup_retention
  deletion_protection        = var.rds_deletion_protection
  skip_final_snapshot        = var.rds_skip_final_snapshot
  apply_immediately          = true

  tags = { Name = "${var.project}-postgres" }
}
