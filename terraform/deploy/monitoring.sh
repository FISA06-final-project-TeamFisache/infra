# ④ monitoring EC2: prometheus + grafana + ELK (타깃/소스 사설IP로 수정)
set -e
cd /opt/infra
sed -i "s#host.docker.internal:8080#__APP_IP__:8080#" prometheus/prometheus.yml
sed -i "s#kafka:29092#__KAFKA_IP__:9092#" logstash/pipeline/logstash.conf
docker compose up -d prometheus grafana elasticsearch logstash kibana
sleep 5
docker compose ps
