terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.5"
    }
  }

  # 초기에는 로컬 state로 시작.
  # 팀/협업 단계가 되면 아래 S3 + DynamoDB 백엔드로 전환 권장.
  # backend "s3" {
  #   bucket         = "your-tfstate-bucket"
  #   key            = "infra/terraform.tfstate"
  #   region         = "ap-northeast-2"
  #   dynamodb_table = "terraform-locks"
  #   encrypt        = true
  # }
}

provider "aws" {
  region = var.region

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
