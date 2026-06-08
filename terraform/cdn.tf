#############################################
# S3 (프론트 정적) + CloudFront (단일 진입점, 무료 HTTPS)
#  - 브라우저 → CloudFront → default: S3(정적) / API·ai 경로: ALB origin
#  - 같은 origin 이라 CORS·mixed-content 없음.
#  - S3 는 비공개. CloudFront OAC 로만 읽음.
#  - 정적 산출물(vite build) 업로드는 Phase 3 에서 s3 sync.
#############################################

# 버킷 이름 전역 유일성 확보용 suffix
resource "random_id" "frontend_bucket" {
  byte_length = 4
}

resource "aws_s3_bucket" "frontend" {
  bucket        = "${var.project}-frontend-${random_id.frontend_bucket.hex}"
  force_destroy = true # destroy 시 객체 남아있어도 버킷 삭제(프론트 정적이라 안전)
  tags          = { Name = "${var.project}-frontend" }
}

# 전체 비공개 (CloudFront OAC 로만 접근)
resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

#############################################
# CloudFront
#############################################
resource "aws_cloudfront_origin_access_control" "s3" {
  name                              = "${var.project}-s3-oac"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# AWS 관리형 정책 ID (고정값)
locals {
  cf_cache_optimized  = "658327ea-f89d-4fab-a63d-7e88639e58f6" # CachingOptimized (정적용)
  cf_cache_disabled   = "4135ea2d-6df8-44a3-9df3-4b5a84be39ad" # CachingDisabled (API용)
  cf_orig_all_no_host = "b689b0a8-53d0-40ab-baf2-68738e2966ac" # AllViewerExceptHostHeader
  cf_s3_origin_id     = "s3-frontend"
  cf_alb_origin_id    = "alb-api"
}

resource "aws_cloudfront_distribution" "main" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_200" # 서울 포함
  comment             = "${var.project} frontend + api"

  # ── origin 1: S3 (정적) ──
  origin {
    origin_id                = local.cf_s3_origin_id
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_access_control_id = aws_cloudfront_origin_access_control.s3.id
  }

  # ── origin 2: ALB (동적 API/ai) ──
  origin {
    origin_id   = local.cf_alb_origin_id
    domain_name = aws_lb.main.dns_name

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "http-only" # CloudFront→ALB 는 HTTP
      origin_ssl_protocols   = ["TLSv1.2"]
      origin_read_timeout    = 60 # SSE(알림) 대비 최대치. 그래도 CloudFront 한계로 장기연결은 주기적 재연결됨.
    }
  }

  # ── default: 프론트 정적(S3) ──
  default_cache_behavior {
    target_origin_id       = local.cf_s3_origin_id
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD", "OPTIONS"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = local.cf_cache_optimized
  }

  # ── API/ai 경로 → ALB origin (캐시 끔, 전부 forward) ──
  dynamic "ordered_cache_behavior" {
    for_each = toset(local.alb_path_patterns)
    content {
      path_pattern             = ordered_cache_behavior.value
      target_origin_id         = local.cf_alb_origin_id
      viewer_protocol_policy   = "redirect-to-https"
      allowed_methods          = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
      cached_methods           = ["GET", "HEAD"]
      cache_policy_id          = local.cf_cache_disabled
      origin_request_policy_id = local.cf_orig_all_no_host
    }
  }

  # SPA fallback: S3 에 없는 경로(클라 라우팅)는 index.html 로
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }
  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # *.cloudfront.net 무료 HTTPS
  }

  tags = { Name = "${var.project}-cdn" }
}

#############################################
# S3 버킷 정책: 이 CloudFront 배포의 OAC 만 GetObject 허용
#############################################
data "aws_iam_policy_document" "frontend_s3" {
  statement {
    sid       = "AllowCloudFrontOAC"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.frontend.arn}/*"]

    principals {
      type        = "Service"
      identifiers = ["cloudfront.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "AWS:SourceArn"
      values   = [aws_cloudfront_distribution.main.arn]
    }
  }
}

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  policy = data.aws_iam_policy_document.frontend_s3.json
}
