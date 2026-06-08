# Phase 3 배포 런북 (AWS 연결 테스트)

> 목표: `terraform apply` 로 뜬 인프라 위에 5개 서비스를 올리고 브라우저로 E2E 연결 확인.
> 접속은 전부 **SSM**(공인 IP 없음). EC2는 부팅 시 docker/git/compose 설치 + 레포 clone 완료된 상태(user_data).
>
> ⚠️ 이 문서는 **뼈대 + 알려진 함정**까지. 일부 세부(compose 서브셋 동작, RDS 확장 등)는 띄워보며 조정.

## 0. 사전 준비 (로컬 PC)

```powershell
cd c:\itstudy\infra\terraform
$env:PATH = "$PWD;$PWD\.venv\Scripts;$env:PATH"   # terraform + aws
aws sts get-caller-identity                        # 자격증명 확인
# SSM 셸/포트포워딩 쓰려면 Session Manager plugin 필요
```

## 1. apply & outputs 확보

```powershell
terraform apply        # yes → ~10~15분 (RDS/CloudFront)
```

apply 후 **아래 값들을 메모**(이후 단계의 <PLACEHOLDER> 에 채움):

```powershell
terraform output instance_private_ips     # app / ai / kafka / monitoring 사설IP
terraform output rds_endpoint             # <RDS_ENDPOINT>
terraform output -raw rds_password        # <RDS_PASSWORD>
terraform output rds_database             # appdb
terraform output rds_username             # appuser
terraform output cloudfront_url           # <CF_URL>  (브라우저 접속 주소)
terraform output frontend_bucket          # <BUCKET>
terraform output cloudfront_distribution_id   # <DIST_ID>
```

| placeholder | 값 |
|---|---|
| `<APP_IP>` `<AI_IP>` `<KAFKA_IP>` `<MON_IP>` | instance_private_ips |
| `<RDS_ENDPOINT>` `<RDS_PASSWORD>` | RDS |
| `<CF_URL>` `<BUCKET>` `<DIST_ID>` | 웹 티어 |

> EC2 부트스트랩 완료 확인: SSM 접속 후 `cat /opt/BOOTSTRAP_DONE` 이 보이면 clone 끝.
> (부팅 직후 1~3분 필요. `instance_ids` 로 대상 확인 후 `aws ssm start-session --target <id>`)

---

## 2. SSM 접속 헬퍼

각 EC2 셸 접속:
```powershell
terraform output instance_ids
aws ssm start-session --target <instance-id>
sudo su - ec2-user      # docker 권한
```
> 셸 안에서 한글 깨지면 무시(명령엔 영향 없음). 아래 블록은 각 EC2 위에서 실행.

---

## 3. ② RDS 스키마·시드

**스키마**: backend 가 JPA `ddl-auto: update` 라 **첫 기동 시 자동 생성**됨 → 별도 schema 주입 불필요.
**시드(데이터)**: backend 레포 `sql/` + (필요시) 루트 시드. 아래는 **app EC2** 에서 실행.

```bash
# app EC2
sudo dnf install -y postgresql15   # psql 클라이언트
export PGPASSWORD='<RDS_PASSWORD>'
PSQL="psql -h <RDS_ENDPOINT> -U appuser -d appdb"

# (1) pgvector 확장 — ai-server 임베딩용. 안 쓰면 생략 가능.
$PSQL -c "CREATE EXTENSION IF NOT EXISTS vector;"

# (2) 연결 확인
$PSQL -c "\dt"   # 아직 비어있음(정상) → backend 기동 후 테이블 생김
```

> 시드는 **backend 기동(④)으로 테이블이 생긴 뒤** 넣는다. 순서: backend 기동 → 테이블 생성 확인 → 시드.
> backend 레포 시드 예: `/opt/backend/sql/dummy_full_flow_test.sql` 등. 무엇을 넣을지는 데모 시나리오에 맞게 선택(라이브 결정).
> 루트 시드(`erd_schema.sql`, `seed_*.sql`)는 레포에 없으니 필요하면 로컬에서 SSM 으로 복사하거나 backend `sql/` 로 대체.

---

## 4. ③ kafka EC2 — kafka + redis

infra compose 에서 **kafka, redis 만** 띄운다. **함정: advertised listener 를 kafka 사설IP로 override** 해야 다른 EC2(backend/ai/mock)에서 붙는다.

```bash
# kafka EC2
cd /opt/infra
# EXTERNAL 리스너를 <KAFKA_IP>:9092 로 advertise (기본은 localhost:9092 라 같은 호스트만 됨)
cat > docker-compose.override.yml <<'EOF'
services:
  kafka:
    environment:
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://kafka:29092,EXTERNAL://<KAFKA_IP>:9092
EOF
sed -i 's/<KAFKA_IP>/'"$(hostname -I | awk '{print $1}')"'/' docker-compose.override.yml

docker compose up -d kafka redis
docker compose ps
```

> `hostname -I` 로 사설IP 자동 치환. 확인: `<KAFKA_IP>` 가 terraform 의 kafka IP 와 같아야 함.
> kafka-ui 도 보고 싶으면 `docker compose up -d kafka-ui` (8081). 단 internal SG라 직접 접근은 SSM 포트포워딩 필요.

---

## 5. ④ monitoring EC2 — prometheus + grafana + ELK

```bash
# monitoring EC2
cd /opt/infra
# 함정: prometheus 타깃이 host.docker.internal → 사설IP로 교체
sed -i 's#host.docker.internal:8080#<APP_IP>:8080#' prometheus/prometheus.yml
# ai-server 메트릭도 스크랩하려면 타깃 추가(선택): <AI_IP>:8000 /metrics

docker compose up -d prometheus grafana elasticsearch logstash kibana
docker compose ps
```

> logstash 파이프라인이 kafka 를 읽는다면 `logstash/pipeline/logstash.conf` 의 bootstrap_servers 를 `<KAFKA_IP>:9092` 로 수정(라이브 확인).
> grafana(3000)/prometheus(9090)/kibana(5601) 확인은 SSM 포트포워딩:
> `aws ssm start-session --target <mon-id> --document-name AWS-StartPortForwardingSession --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'`

---

## 6. ⑤ ai EC2 — ai-server (FastAPI)

ai-server 는 Dockerfile + docker-compose.yaml(.env 사용). `/opt/ai-server/.env` 작성 후 기동.

```bash
# ai EC2
cd /opt/ai-server
cat > .env <<EOF
DB_URL=postgresql://appuser:<RDS_PASSWORD>@<RDS_ENDPOINT>:5432/appdb
REDIS_HOST=<KAFKA_IP>          # redis 를 kafka EC2에 같이 띄웠으므로
REDIS_PORT=6379
KAFKA_BOOTSTRAP_SERVERS=<KAFKA_IP>:9092
OPENAI_API_KEY=<OPENAI_KEY>
TAVILY_API_KEY=<TAVILY_KEY>   # 없으면 빈 값
LLM_MODEL=gpt-4o
LOG_LEVEL=INFO
CORS_ALLOWED_ORIGINS=<CF_URL>
EOF

docker compose up -d --build
docker compose logs -f fastapi   # 기동/DB연결 확인 (Ctrl+C)
curl -s localhost:8000/health
```

> ai-server 도 부팅 시 kafka producer 를 연다(main.py lifespan) → `KAFKA_BOOTSTRAP_SERVERS` 필수.

---

## 7. ⑥ app EC2 — backend + mock-server

### backend (Dockerfile, compose 없음 → build + run)
```bash
# app EC2
cd /opt/backend
docker build -t backend:local .          # gradle 빌드 포함, 수 분 소요
docker run -d --name backend -p 8080:8080 \
  -e SPRING_DATASOURCE_URL='jdbc:postgresql://<RDS_ENDPOINT>:5432/appdb' \
  -e DB_USERNAME='appuser' \
  -e DB_PASSWORD='<RDS_PASSWORD>' \
  -e REDIS_HOST='<KAFKA_IP>' \
  -e REDIS_PORT='6379' \
  -e KAFKA_BOOTSTRAP_SERVERS='<KAFKA_IP>:9092' \
  -e FLASK_ML_URL='http://<AI_IP>:8000' \
  -e JWT_SECRET='<JWT_SECRET>' \
  -e CORS_ALLOWED_ORIGINS='<CF_URL>' \
  backend:local
docker logs -f backend     # 기동 + DB/kafka 연결 확인
curl -s localhost:8080/actuator/health   # {"status":"UP"}
```

> 기동되면 RDS 에 테이블 생성됨 → 이때 **3절의 시드** 주입.

### mock-server (env 변수명이 다름! 주의)
```bash
# app EC2
cd /opt/mock-server
docker build -t mock:local .
docker run -d --name mock \
  -e KAFKA_BOOTSTRAP='<KAFKA_IP>:9092' \
  -e DB_HOST='<RDS_ENDPOINT>' \
  -e DB_PORT='5432' \
  -e DB_NAME='appdb' \
  -e DB_USER='appuser' \
  -e DB_PASSWORD='<RDS_PASSWORD>' \
  mock:local
docker logs -f mock
```

> ⚠️ mock 은 `KAFKA_BOOTSTRAP`(서버즈 아님) + `DB_HOST/DB_NAME/DB_USER` 사용.
> ⚠️ mock 은 시작 시 `assets` 테이블에서 CREDIT_CARD 자산을 1회 로드 → **카드 데이터(시드)와 연동이 먼저** 있어야 발행됨. 없으면 조용히 안 돈다(README 참고). 카드 연동 후 mock **재시작**.

---

## 8. ⑦ frontend — build → S3 → CloudFront

프론트는 EC2 아님. **로컬 PC**(또는 CI)에서 빌드해 S3 업로드.

```powershell
# 로컬 c:\itstudy\frontend
npm ci
npm run build               # .env.production(상대경로) 자동 적용 → dist/
aws s3 sync dist/ s3://<BUCKET>/ --delete
aws cloudfront create-invalidation --distribution-id <DIST_ID> --paths "/*"
```

---

## 9. ⑧ 검증

```powershell
# 인프라 레벨
cd c:\itstudy\infra\terraform
./verify.ps1 -Deep

# ALB 타깃 헬스 (배포 후 healthy 여야 함)
aws elbv2 describe-target-health --target-group-arn <backend-tg-arn>
```

브라우저:
1. `<CF_URL>` 접속 → 프론트 로드(SPA)
2. 로그인/대시보드 → `/api/*` 가 200 (CloudFront→ALB→backend)
3. mock 발행 → backend consume → 대시보드 **SSE 알림** 표시 (E2E 핵심)
4. grafana 에서 backend 메트릭 그래프 표시

## 10. 과금 중단

```powershell
terraform destroy     # 테스트 끝나면 즉시
```

---

## 부록: 서비스별 env 변수명 (헷갈림 주의)

| 서비스 | DB | redis | kafka | 기타 |
|---|---|---|---|---|
| backend | `SPRING_DATASOURCE_URL` / `DB_USERNAME` / `DB_PASSWORD` | `REDIS_HOST` `REDIS_PORT` | `KAFKA_BOOTSTRAP_SERVERS` | `FLASK_ML_URL` `JWT_SECRET` `CORS_ALLOWED_ORIGINS` |
| ai-server | `DB_URL` (한 줄 URL) | `REDIS_HOST` `REDIS_PORT` | `KAFKA_BOOTSTRAP_SERVERS` | `OPENAI_API_KEY` `TAVILY_API_KEY` `LLM_MODEL` `CORS_ALLOWED_ORIGINS` |
| mock-server | `DB_HOST` `DB_PORT` `DB_NAME` `DB_USER` `DB_PASSWORD` | - | `KAFKA_BOOTSTRAP` ⚠️ | - |

## 부록: 호스트 배치

| EC2 | 올리는 것 | 포트 |
|---|---|---|
| app | backend, mock-server | 8080 |
| ai | ai-server | 8000 |
| kafka | kafka, redis(, kafka-ui) | 9092, 6379 |
| monitoring | prometheus, grafana, ELK | 9090, 3000, 5601 |
| RDS | postgres | 5432 |
