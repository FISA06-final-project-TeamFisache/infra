# ③ kafka EC2: kafka + redis (advertised listener = 사설IP)
set -e
cd /opt/infra
cat > docker-compose.override.yml <<EOF
services:
  kafka:
    environment:
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://kafka:29092,EXTERNAL://__KAFKA_IP__:9092
EOF
docker compose up -d kafka redis
docker compose ps
