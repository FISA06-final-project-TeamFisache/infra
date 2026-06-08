#############################################
# SSM 접속용 IAM (SSH 키/bastion 불필요)
#  - 인스턴스에 이 역할을 붙이면 Session Manager로 접속 가능
#  - SSM은 인스턴스가 아웃바운드 443으로 AWS에 연결 → NAT 통해 동작
#############################################
data "aws_iam_policy_document" "ec2_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "ssm" {
  name               = "${var.project}-ssm-role"
  assume_role_policy = data.aws_iam_policy_document.ec2_assume.json
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.project}-ssm-profile"
  role = aws_iam_role.ssm.name
}

#############################################
# 프론트 배포용: EC2(app)에서 S3 업로드 + CloudFront 무효화 허용.
#  (로컬에 node가 없어 EC2에서 빌드/업로드하기 위함. 프론트 버킷/배포로 범위 제한)
#############################################
data "aws_iam_policy_document" "frontend_deploy" {
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

resource "aws_iam_role_policy" "frontend_deploy" {
  name   = "${var.project}-frontend-deploy"
  role   = aws_iam_role.ssm.id
  policy = data.aws_iam_policy_document.frontend_deploy.json
}
