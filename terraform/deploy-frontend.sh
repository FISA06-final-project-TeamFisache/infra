#!/bin/bash
# app EC2에서 frontend 빌드 → S3 업로드 → CloudFront 무효화
set -e
export AWS_DEFAULT_REGION=ap-northeast-2

echo "=== aws cli check ==="
if ! command -v aws >/dev/null 2>&1; then
  echo "installing aws cli v2..."
  cd /tmp
  curl -s "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o awscliv2.zip
  dnf install -y unzip >/dev/null 2>&1 || true
  unzip -q awscliv2.zip
  ./aws/install >/dev/null 2>&1 || ./aws/install --update
fi
aws --version
aws sts get-caller-identity --output text

echo "=== clone frontend (dev) ==="
rm -rf /opt/frontend
git clone -q -b dev https://github.com/FISA06-final-project-TeamFisache/frontend.git /opt/frontend

echo "=== build via docker node ==="
docker run --rm -v /opt/frontend:/work -w /work node:20 \
  sh -c "npm ci --no-audit --no-fund && npm run build" 2>&1 | tail -25

echo "=== dist ==="
ls /opt/frontend/dist

echo "=== s3 sync ==="
aws s3 sync /opt/frontend/dist "s3://myapp-frontend-5d0aa3c5" --delete

echo "=== cloudfront invalidation ==="
aws cloudfront create-invalidation --distribution-id E3IC0FQ4UH76G1 --paths "/*" \
  --query "Invalidation.Status" --output text

echo "FRONTEND_DONE"
