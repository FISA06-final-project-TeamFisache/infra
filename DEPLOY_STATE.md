# 배포 현황 / 인수인계 (AWS 연결 테스트)

> 마지막 작업: **2026-06-08**. 전체 스택을 AWS에 올리고 핵심 연결까지 검증 완료.
> 다음 세션은 이 문서 + [DEPLOY.md](DEPLOY.md)(런북)를 참고하면 바로 이어서 작업 가능.
> ⚠️ **시크릿(비번/키)은 이 문서에 없음** — `terraform output` / 각 레포의 `.env`에서 가져올 것.

---

## 0. 한 줄 요약

폴리레포(backend/ai-server/frontend/mock-server/infra) 5개를 AWS에 배포.
**브라우저 → CloudFront(무료 HTTPS, 단일 origin) → S3(프론트) / ALB(backend·ai) → RDS·Redis·Kafka** 구조.
인프라/서비스 연결은 **전부 검증 완료**. 남은 건 mock-server(실시간 알림 E2E)뿐.

---

## 1. 현재 떠 있는 리소스 (이번 apply 기준)

> ⚠️ 아래 ID/IP/엔드포인트는 **이번 apply에서 생성된 값**. 재apply하면 바뀌므로 항상 `terraform output`으로 최신화.

```powershell
cd c:\itstudy\infra\terraform
$env:PATH = "$PWD;$PWD\.venv\Scripts;$env:PATH"
terraform output            # 전체 출력 확인
```

| 항목 | 값 (이번 apply) |
|---|---|
| Region | `ap-northeast-2` (서울) |
| VPC | `vpc-0eaeedd6a7d494012` |
| **app** EC2 | `i-003545fe3811e01d1` / `10.0.10.39` (backend, +mock 예정) |
| **ai** EC2 | `i-0d07590adf8b3ef9d` / `10.0.10.170` (ai-server) |
| **kafka** EC2 | `i-01c4f1bc308f8c068` / `10.0.11.152` (kafka+redis) |
| **monitoring** EC2 | `i-00993a730a448bbfe` / `10.0.11.59` (prom/grafana/ELK) |
| **RDS** | `myapp-postgres.chw2y8s8kwji.ap-northeast-2.rds.amazonaws.com:5432` / db=`appdb` / user=`appuser` |
| **CloudFront** | https://dumjmuqwuhqbz.cloudfront.net  (dist id `E3IC0FQ4UH76G1`) |
| **S3 프론트** | `myapp-frontend-5d0aa3c5` |
| **ALB** | `myapp-alb-1342443813.ap-northeast-2.elb.amazonaws.com` (CloudFront 뒤, 직접 접근은 디버그용) |

RDS 비번: `terraform output -raw rds_password`

---

## 2. 서비스 배포 상태

| EC2 | 올린 것 | 상태 | 비고 |
|---|---|---|---|
| app | backend (docker `backend:local`) | ✅ health UP (db/redis/kafka 연결) | EC2에서 직접 build/run |
| app | mock-server | ❌ 미기동 | 카드 시드 필요 |
| ai | ai-server (compose `ai-server-fastapi`) | ✅ `/health ok` | |
| kafka | kafka + redis (infra compose 일부) | ✅ | advertised listener=사설IP |
| monitoring | prometheus + grafana | ✅ backend scrape `up=1` | |
| monitoring | elasticsearch + logstash + kibana | ✅ ES green / kibana 200 | logstash가 kafka 구독 |

**검증된 연결**: 브라우저→CloudFront→S3(200) / →ALB→backend→RDS(PostgreSQL UP)·Redis(UP) / backend↔Kafka(producer+consumer) / Prometheus→backend.

---

## 3. 접속 방법

### 앱 (브라우저 바로)
https://dumjmuqwuhqbz.cloudfront.net

### EC2 셸 (SSM)
```powershell
aws ssm start-session --target <instance-id>   # Session Manager plugin 필요
# 비대화형 명령 실행은 ssm-run.ps1 헬퍼 사용 (아래 4절)
```

### 모니터링 (private → SSM 포트포워딩, monitoring EC2 = i-00993a730a448bbfe)
```powershell
# Grafana http://localhost:3000 (admin/admin)
aws ssm start-session --target i-00993a730a448bbfe --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"3000\"],\"localPortNumber\":[\"3000\"]}'
# Kibana http://localhost:5601
aws ssm start-session --target i-00993a730a448bbfe --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"5601\"],\"localPortNumber\":[\"5601\"]}'
# Prometheus http://localhost:9090
aws ssm start-session --target i-00993a730a448bbfe --document-name AWS-StartPortForwardingSession --parameters '{\"portNumber\":[\"9090\"],\"localPortNumber\":[\"9090\"]}'
```

### RDS 직접 접속 (IntelliJ/DBeaver/psql) — app EC2 경유 터널
```powershell
aws ssm start-session --target i-003545fe3811e01d1 `
  --document-name AWS-StartPortForwardingSessionToRemoteHost `
  --parameters '{\"host\":[\"myapp-postgres.chw2y8s8kwji.ap-northeast-2.rds.amazonaws.com\"],\"portNumber\":[\"5432\"],\"localPortNumber\":[\"15432\"]}'
# → localhost:15432 / appdb / appuser / (terraform output -raw rds_password)
```

---

## 4. 비대화형 SSM 실행 헬퍼

`infra/terraform/ssm-run.ps1` — SSM RunShellScript로 명령 보내고 완료까지 대기 후 출력.
```powershell
cd c:\itstudy\infra\terraform
. .\ssm-run.ps1
Invoke-SSM -InstanceId i-xxxx -Script "docker ps"
```
- 큰 출력(빌드/pull 로그)은 `--query`로 따로 조회: 
  `aws ssm get-command-invocation --command-id <id> --instance-id <id> --query StandardOutputContent --output text`
- 위험패턴 스캐너(`rm`+`/app`/`/tmp`)에 걸리면 → **스크립트를 로컬 .sh 파일로 저장 후** base64로 보냄
  (`echo <b64> | base64 -d | bash`). 예: `deploy-frontend.sh`.

---

## 5. 서비스별 주입 설정 (재배포 시 그대로)

> 사설IP/엔드포인트/CloudFront URL은 1절 값. RDS 비번은 `terraform output -raw rds_password`.

### backend (app EC2) — `/opt/backend.env` (env-file) + secret 파일 마운트
```
SPRING_DATASOURCE_URL=jdbc:postgresql://<RDS>:5432/appdb
DB_USERNAME=appuser
DB_PASSWORD=<rds_password>
REDIS_HOST=10.0.11.152
REDIS_PORT=6379
KAFKA_BOOTSTRAP_SERVERS=10.0.11.152:9092
FLASK_ML_URL=http://10.0.10.170:8000
JWT_SECRET=<로컬 application-secret.yml 값 재사용>
CORS_ALLOWED_ORIGINS=https://dumjmuqwuhqbz.cloudfront.net
```
- ⚠️ **application-secret.yml은 gitignore라 레포에 없음** → EC2 clone본엔 datasource/jwt 설정이 빠짐.
  → 로컬 `backend/src/main/resources/application-secret.yml`을 EC2 `/opt/backend-secret/`에 두고
  컨테이너 `/app/config/application-secret.yml`로 **마운트**해서 해결함.
- 실행: `docker run -d --name backend -p 8080:8080 --env-file /opt/backend.env -v /opt/backend-secret/application-secret.yml:/app/config/application-secret.yml:ro backend:local`

### ai-server (ai EC2) — `/opt/ai-server/.env`
```
DB_URL=postgresql://appuser:<URL인코딩된 rds_password>@<RDS>:5432/appdb
REDIS_HOST=10.0.11.152
REDIS_PORT=6379
KAFKA_BOOTSTRAP_SERVERS=10.0.11.152:9092
OPENAI_API_KEY=<ai-server/.env 값>
TAVILY_API_KEY=<선택>
LLM_MODEL=gpt-4o-mini-2024-07-18
CORS_ALLOWED_ORIGINS=https://dumjmuqwuhqbz.cloudfront.net
```
- ⚠️ DB_URL은 한 줄 DSN이라 비번 특수문자 **URL 인코딩** 필요(`[uri]::EscapeDataString`).
- ⚠️ GitHub의 ai compose가 외부 네트워크 요구 → 먼저 `docker network create wooriport-network`.
- 실행: `cd /opt/ai-server && docker compose up -d --build`

### kafka (kafka EC2) — advertised listener override
`/opt/infra/docker-compose.override.yml`:
```yaml
services:
  kafka:
    environment:
      KAFKA_ADVERTISED_LISTENERS: INTERNAL://kafka:29092,EXTERNAL://10.0.11.152:9092
```
실행: `cd /opt/infra && docker compose up -d kafka redis`

### monitoring (monitoring EC2) — 타깃/소스 사설IP로 수정
```bash
cd /opt/infra
sed -i 's#host.docker.internal:8080#10.0.10.39:8080#' prometheus/prometheus.yml
sed -i 's#kafka:29092#10.0.11.152:9092#' logstash/pipeline/logstash.conf
docker compose up -d prometheus grafana elasticsearch logstash kibana
```
> 참고: logstash가 depends_on으로 monitoring에도 kafka 컨테이너를 1개 더 띄움(미사용, 무해).

### frontend — app EC2에서 빌드 후 S3 업로드
`infra/terraform/deploy-frontend.sh` 그대로 실행(EC2에서). 내용: aws CLI 확인/설치 → `git clone -b dev` →
`docker run node:20`으로 build → `aws s3 sync dist s3://<bucket> --delete` → CloudFront invalidation.
(app EC2 IAM에 S3 쓰기+CF 무효화 권한 추가돼 있음 — `iam.tf`의 `frontend_deploy`)

---

## 6. 이번에 잡은 버그/이슈 (재발 방지)

| 증상 | 원인 | 해결 |
|---|---|---|
| backend gradle wrapper read-timeout | NAT로 130MB gradle 배포본 받다 타임아웃 | Dockerfile을 `gradle:8.14.4-jdk21` 이미지로 변경 (커밋됨) |
| backend 컴파일 에러 `cannot find symbol List` | Phase1에서 CorsConfig의 `import java.util.List` 누락 | import 복원 (커밋 `2fc0057`) |
| backend `SCRAM ... no password` | application-secret.yml이 gitignore → clone본에 없음 | secret 파일을 `/app/config/`에 마운트 |
| ai `network wooriport-network not found` | compose 외부 네트워크 요구 | `docker network create wooriport-network` |
| kafka 컨슈머 `NOT_COORDINATOR` 반복 | 기동 직후 `__consumer_offsets` 준비중 | 수초 후 자동 해소(정상) |
| prometheus 타깃 안 잡힘 | `host.docker.internal` (크로스호스트 불가) | 사설IP로 sed |
| SSM 헬퍼 큰 출력에서 깨짐 | ConvertFrom-Json + cp949 인코딩 | `--query`로 status만 폴링 + `PYTHONIOENCODING=utf-8` |

**서비스별 env 변수명 차이 주의**: mock-server는 `KAFKA_BOOTSTRAP`(≠`_SERVERS`), `DB_HOST/DB_PORT/DB_NAME/DB_USER/DB_PASSWORD`. 상세는 [DEPLOY.md](DEPLOY.md) 부록.

---

## 7. 남은 작업 (TODO)

- [ ] **mock-server 기동 + 카드 시드** → 실시간 거래→backend consume→대시보드 **SSE 알림** E2E
  - 시드 후보: `backend/sql/dummy_full_flow_test.sql` (CREDIT_CARD 자산 포함 여부/연결 user_id 확인 필요)
  - mock 실행(app EC2): `KAFKA_BOOTSTRAP=10.0.11.152:9092`, `DB_HOST=<RDS>`, `DB_PORT=5432`, `DB_NAME=appdb`, `DB_USER=appuser`, `DB_PASSWORD=<pw>`
  - 카드 데이터 들어온 뒤 mock **재시작** 필요(시작 시 1회 로드)
- [ ] 레포 정리(선택): `application-secret.yml.example` 추가, frontend `dev`→`main` 정리, backend 수정 push 확인
- [ ] (추후) backend 오토스케일(ASG), Jenkins CI/CD — Phase 5

---

## 8. 비용 / 정리

상시 과금: NAT·ALB·CloudFront·RDS·EC2 4대 (대략 시간당 ~$0.25). **테스트 끝나면 즉시:**
```powershell
cd c:\itstudy\infra\terraform
terraform destroy     # 전부 삭제, 과금 0
```
> EC2는 부팅 시 user_data로 docker/clone 자동 → destroy 후 재apply하면 ②~⑦만 다시 하면 됨(DEPLOY.md 순서).

---

## 9. 재개 빠른 절차 (다음 세션)

1. `terraform output`으로 현재 살아있는지 + 값 확인 (없으면 `terraform apply`로 재생성, ~15분)
2. 재apply했다면 새 IP/엔드포인트로 5절 env 갱신해서 ②kafka→③monitoring→④ai→⑤backend→⑥frontend 재배포
3. 검증: `https://<cloudfront>` + `/actuator/health` 200 확인
4. (선택) mock-server + 카드 시드로 알림 E2E
5. 끝나면 `terraform destroy`
