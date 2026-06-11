variable "project" {
  description = "프로젝트 이름(태그/네이밍 prefix)"
  type        = string
  default     = "myapp"
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2" # 서울
}

variable "azs" {
  description = "사용할 가용영역 2개 (ALB/멀티 AZ 대비)"
  type        = list(string)
  default     = ["ap-northeast-2a", "ap-northeast-2c"]
}

variable "vpc_cidr" {
  description = "VPC CIDR"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_cidrs" {
  description = "public 서브넷 CIDR (NAT/추후 ALB용)"
  type        = list(string)
  default     = ["10.0.0.0/24", "10.0.1.0/24"]
}

variable "private_subnet_cidrs" {
  description = "private 서브넷 CIDR (EC2/추후 RDS용)"
  type        = list(string)
  default     = ["10.0.10.0/24", "10.0.11.0/24"]
}

variable "key_name" {
  description = "EC2 키페어 이름(선택). SSM으로 접속하므로 비워도 됨"
  type        = string
  default     = ""
}

variable "github_org" {
  description = "EC2 부트스트랩에서 clone 할 GitHub 조직/사용자 (public 레포)"
  type        = string
  default     = "FISA06-final-project-TeamFisache"
}

variable "compose_version" {
  description = "설치할 docker compose v2 플러그인 버전"
  type        = string
  default     = "v2.29.7"
}

# EC2 인스턴스 정의. 여기만 고치면 인스턴스가 추가/삭제됨.
# 전부 private 서브넷에 배치. subnet_index(0/1)로 2개 AZ에 분산.
variable "instances" {
  description = "생성할 EC2 목록"
  type = map(object({
    instance_type = string
    subnet_index  = number # 0=AZ-a, 1=AZ-c
  }))
  default = {
    app = {
      instance_type = "t3.medium" # Spring Boot
      subnet_index  = 0
    }
    kafka = {
      instance_type = "t3.small" # Kafka 단일
      subnet_index  = 1
    }
    ai = {
      instance_type = "t3.small" # FastAPI 서버 (외부 LLM API 호출 프록시 — 경량). 무거워지면 t3.medium
      subnet_index  = 0
    }
    monitoring = {
      instance_type = "t3.medium" # Grafana+Prometheus+ELK (4GB로 시작, 빠듯하면 t3.large)
      subnet_index  = 1
    }
    # Jenkins 는 전용 IAM(배포 권한)이 필요해 jenkins.tf 에서 별도 관리.
    # Spring Batch 는 분리하지 않음 — app(Spring Boot) 안에서 스케줄링으로 실행.
  }
}

#############################################
# RDS PostgreSQL
#############################################
variable "enable_rds" {
  description = "RDS 생성 여부 (비용 제어용 on/off 스위치). 기본 on"
  type        = bool
  default     = true
}

variable "rds_engine_version" {
  description = "PostgreSQL major 버전 (해당 major 의 최신 minor 가 자동 선택됨)"
  type        = string
  default     = "16"
}

variable "rds_instance_class" {
  description = "RDS 인스턴스 타입 (dev: db.t3.micro, 운영: db.t3.medium 이상)"
  type        = string
  default     = "db.t3.micro"
}

variable "rds_allocated_storage" {
  description = "초기 스토리지(GB)"
  type        = number
  default     = 20
}

variable "rds_max_allocated_storage" {
  description = "스토리지 오토스케일 상한(GB)"
  type        = number
  default     = 100
}

variable "rds_db_name" {
  description = "초기 생성할 DB 이름"
  type        = string
  default     = "appdb"
}

variable "rds_username" {
  description = "마스터 사용자명"
  type        = string
  default     = "appuser"
}

variable "rds_multi_az" {
  description = "Multi-AZ 여부 (dev=false 로 비용 절감, 운영=true)"
  type        = bool
  default     = false
}

variable "rds_backup_retention" {
  description = "자동 백업 보관일 (0=백업 비활성)"
  type        = number
  default     = 1
}

variable "rds_deletion_protection" {
  description = "삭제 보호 (운영에서는 true 권장)"
  type        = bool
  default     = false
}

variable "rds_skip_final_snapshot" {
  description = "destroy 시 최종 스냅샷 생략 (dev=true)"
  type        = bool
  default     = true
}

#############################################
# Jenkins (CI/CD EC2)
#############################################
variable "enable_jenkins" {
  description = "Jenkins EC2 생성 여부 (비용 제어용 on/off 스위치). 기본 on"
  type        = bool
  default     = true
}

variable "jenkins_instance_type" {
  description = "Jenkins EC2 타입 (Jenkins + docker 빌드 감당 최소선이 t3.medium/4GB)"
  type        = string
  default     = "t3.medium"
}

variable "jenkins_subnet_index" {
  description = "Jenkins EC2를 둘 private 서브넷 (0=AZ-a, 1=AZ-c)"
  type        = number
  default     = 0
}
