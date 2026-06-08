# ⑥ app EC2: backend (env-file + secret 마운트 + 빌드/기동)
set -e
cd /opt/backend
cat > /opt/backend.env <<'EOF'
SPRING_DATASOURCE_URL=jdbc:postgresql://__RDS__:5432/appdb
DB_USERNAME=appuser
DB_PASSWORD=__RDS_PW__
REDIS_HOST=__KAFKA_IP__
REDIS_PORT=6379
KAFKA_BOOTSTRAP_SERVERS=__KAFKA_IP__:9092
FLASK_ML_URL=http://__AI_IP__:8000
CORS_ALLOWED_ORIGINS=__CF__
EOF
mkdir -p /opt/backend-secret
echo "__SECRET_B64__" | base64 -d > /opt/backend-secret/application-secret.yml
ok=0
for i in 1 2 3; do
  echo "=== backend build attempt $i ==="
  if docker build -t backend:local . > /tmp/bbuild.log 2>&1; then ok=1; break; fi
  echo "build failed; tail:"; tail -8 /tmp/bbuild.log; sleep 10
done
[ "$ok" = 1 ] || { echo "BUILD_FAILED"; tail -30 /tmp/bbuild.log; exit 1; }
docker rm -f backend 2>/dev/null || true
docker run -d --name backend -p 8080:8080 \
  --env-file /opt/backend.env \
  -v /opt/backend-secret/application-secret.yml:/app/config/application-secret.yml:ro \
  --restart unless-stopped backend:local
sleep 35
docker ps --filter name=backend
echo "--- health ---"; curl -s localhost:8080/actuator/health || echo "not ready yet"
