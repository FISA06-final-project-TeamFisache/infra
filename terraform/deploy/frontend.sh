# ⑦ app EC2: frontend 빌드 → S3 업로드 → CloudFront 무효화
set -e
export AWS_DEFAULT_REGION=ap-northeast-2

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
ls /opt/frontend/dist

echo "=== s3 sync ==="
aws s3 sync /opt/frontend/dist "s3://__BUCKET__" --delete

echo "=== cloudfront invalidation ==="
aws cloudfront create-invalidation --distribution-id __DISTID__ --paths "/*" \
  --query "Invalidation.Status" --output text

echo "FRONTEND_DONE"
