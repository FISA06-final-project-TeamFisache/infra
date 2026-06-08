# ⑤ ai EC2: ai-server (.env 구성 후 compose)
set -e
cd /opt/ai-server
cat > .env <<'EOF'
DB_URL=postgresql://appuser:__RDS_PW_ENC__@__RDS__:5432/appdb
REDIS_HOST=__KAFKA_IP__
REDIS_PORT=6379
KAFKA_BOOTSTRAP_SERVERS=__KAFKA_IP__:9092
OPENAI_API_KEY=__OPENAI__
TAVILY_API_KEY=__TAVILY__
LLM_MODEL=__LLM_MODEL__
LLM_TEMPERATURE=0.2
LOG_LEVEL=INFO
CORS_ALLOWED_ORIGINS=__CF__
EOF
docker network create wooriport-network 2>/dev/null || true
docker compose up -d --build
sleep 10
docker compose ps
echo "--- health ---"; curl -s localhost:8000/health || echo "ai not ready"
