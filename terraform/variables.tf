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
      instance_type = "t3.medium" # AI 서버 (CPU only, GPU 미사용)
      subnet_index  = 0
    }
    monitoring = {
      instance_type = "t3.medium" # Grafana+Prometheus+ELK (4GB로 시작, 빠듯하면 t3.large)
      subnet_index  = 1
    }
    # Spring Batch는 start/stop 스케줄이 필요해 batch.tf에서 별도 관리.
    # enable_batch = true 로 켬.
  }
}

#############################################
# Spring Batch (EC2 start/stop + EventBridge Scheduler)
#############################################
variable "enable_batch" {
  description = "배치 EC2 + 스케줄러 생성 여부 (분리 시 true)"
  type        = bool
  default     = false
}

variable "batch_instance_type" {
  description = "배치 EC2 타입"
  type        = string
  default     = "t3.small"
}

variable "batch_subnet_index" {
  description = "배치 EC2를 둘 private 서브넷 (0=AZ-a, 1=AZ-c)"
  type        = number
  default     = 0
}

variable "schedule_timezone" {
  description = "스케줄 시간대"
  type        = string
  default     = "Asia/Seoul"
}

variable "batch_start_cron" {
  description = "배치 EC2 시작 시각 (cron). 기본: 매일 01:50 KST"
  type        = string
  default     = "cron(50 1 * * ? *)"
}

variable "batch_stop_cron" {
  description = "배치 EC2 중지 시각 (cron). 기본: 매일 03:00 KST"
  type        = string
  default     = "cron(0 3 * * ? *)"
}
