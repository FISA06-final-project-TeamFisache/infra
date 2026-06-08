# 배포 현황 / 인수인계 (AWS 연결 테스트)

> **현재 상태(2026-06-08): 🔴 DESTROYED — 모든 리소스 삭제됨, 과금 $0.**
> 한 번 전체 배포·검증을 마치고 `terraform destroy`로 내린 상태. AWS에 떠있는 것 없음.
>
> 이번 세션에 한 일: 전체 스택 AWS 배포 → E2E 연결 검증 → **앱 기동 자동화(`redeploy.ps1`) 작성+실전 검증** → destroy.
> **다음 세션 복귀 = 두 줄**: `terraform apply` → `.\redeploy.ps1` (자세히는 9절).
> ⚠️ 아래 1절의 ID/IP/엔드포인트는 **지난 apply 때 값이라 지금은 전부 무효** — 재apply하면 새 값 생김(`terraform output`).
> ⚠️ **시크릿(비번/키)은 이 문서에 없음** — `terraform output` / 각 레포의 `.env`에서 가져옴(자동화가 알아서 읽음).
> 📌 미push 커밋: infra `b4ef20d`(헬퍼 오탐 수정) — 다음에 push 필요.

---

## 0. 한 줄 요약

폴리레포(backend/ai-server/frontend/mock-server/infra) 5개를 AWS에 배포.
**브라우저 → CloudFront(무료 HTTPS, 단일 origin) → S3(프론트) / ALB(backend·ai) → RDS·Redis·Kafka** 구조.
인프라/서비스 연결은 **전부 검증 완료**. 남은 건 mock-server(실시간 알림 E2E)뿐.

---

## 1. 리소스 식별자 (지난 apply 기준 — 현재는 destroy됨, 참고용)

> ⚠️ **지금은 전부 삭제된 상태.** 아래는 "이런 항목들이 생긴다"는 참고. 재apply하면 **새 값**이 생기니
> 항상 `terraform output`으로 확인(자동화 스크립트가 알아서 읽음).

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

## 2. 서비스 배포 상태 (destroy 전 마지막 시점 — `redeploy.ps1`로 재현됨)

> 아래는 한창 떠있을 때 상태. **`redeploy.ps1` 한 번으로 이 상태 전체가 재현됨을 실전 검증 완료**
> (5단계 모두 STATUS=Success, 외부 `GET /`=200, `/actuator/health`=200 UP). 지금은 destroy로 내려감.

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

### 3.0 ⭐ `aws ssm` 명령은 어디서 / 어떻게 실행하나 (사전 준비)

**실행 위치**: 내 **로컬 PC의 PowerShell 창** (EC2 안이 아님!). AWS 자격증명이 있는 곳이면 어디서든 OK.
EC2는 공인 IP가 없어 SSH 불가 → 전부 로컬에서 SSM으로 접속한다.

**사전 준비 3가지** (한 번만):

1. **AWS CLI 설치 + 자격증명** — 이미 돼 있음(이 프로젝트는 `infra/terraform/.venv`에 awscli 설치).
   - 새 PowerShell 창마다 PATH 한 줄 실행(포터블 설치라):
     ```powershell
     cd c:\itstudy\infra\terraform
     $env:PATH = "$PWD;$PWD\.venv\Scripts;$env:PATH"
     ```
   - 확인: `aws sts get-caller-identity` → 계정 ID 나오면 OK.
   - (winget 등으로 aws를 **전역 설치**했다면 PATH 줄 불필요, 아무 창에서나 됨)

2. **Session Manager plugin 설치** — ⚠️ **start-session / 포트포워딩에 필수**. 없으면
   `SessionManagerPlugin is not found` 에러. (terraform apply/verify에는 불필요해서 안 깔려 있을 수 있음)
   - 설치(택1):
     ```powershell
     winget install Amazon.SessionManagerPlugin
     ```
     또는 수동: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html
   - 설치 후 **새 창**에서 확인: `session-manager-plugin` (버전/사용법 나오면 OK)

3. **리전** — `aws configure`에서 `ap-northeast-2`로 돼 있으면 그대로. 아니면 각 명령에 `--region ap-northeast-2` 추가.

**포트포워딩 사용 팁**:
- 포워딩 명령을 실행한 **그 창은 터널이 유지되는 동안 계속 점유**된다(닫으면 끊김).
  → 그 창은 그대로 두고, **브라우저/다른 작업은 별도 창**에서 한다.
- "Waiting for connections..." 가 뜨면 성공 → 브라우저에서 `http://localhost:<localPortNumber>` 접속.
- 끊을 땐 그 창에서 `Ctrl + C`.

> 요약: **로컬 PowerShell → (PATH 한 줄) → aws sts get-caller-identity 로 확인 → start-session**. 막히면 십중팔구 Session Manager plugin 미설치.

### 앱 (브라우저 바로 — SSM 불필요)
https://dumjmuqwuhqbz.cloudfront.net

### EC2 셸 접속 (SSM)
```powershell
# 로컬 PowerShell에서 (3.0 사전준비 완료 가정)
aws ssm start-session --target i-003545fe3811e01d1     # app
# 접속되면 그 안에서: sudo su - ec2-user  (docker 명령용)
# 종료: exit
```
> 비대화형으로 명령만 돌릴 땐 셸 접속 대신 `ssm-run.ps1` 헬퍼 사용 (4절).

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

> ⭐ **자동화됨**: `apply` 후 아래 한 줄이면 ②kafka~⑦frontend 전부 배포된다. 식별자(IP/RDS/CloudFront/버킷)는
> `terraform output`에서 자동으로 읽으므로 **손댈 값 없음**. 시크릿도 자동(아래 출처).
> ```powershell
> cd c:\itstudy\infra\terraform
> .\redeploy.ps1            # 실제 배포 (~15~20분)
> .\redeploy.ps1 -DryRun    # 값 주입만 검증(SSM 미실행)
> ```
> 구성: `redeploy.ps1`(오케스트레이터) + `deploy\*.sh`(단계별 템플릿, 플레이스홀더).
> 시크릿 출처: RDS비번=`terraform output` / OpenAI·Tavily·LLM_MODEL=로컬 `ai-server/.env` / JWT=로컬 `backend/.../application-secret.yml`(컨테이너에 마운트).
> ⚠️ 그래서 **로컬에 `ai-server/.env`와 `backend/src/main/resources/application-secret.yml`이 있어야** 한다(둘 다 gitignore).
>
> 아래는 redeploy.ps1이 내부적으로 하는 일(수동/디버그 참고용):

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
| redeploy STATUS 오탐 `[!!]` | 헬퍼 반환값에 출력 섞임 | StandardOutputContent를 `Out-Host`로 (`b4ef20d`) |
| destroy 실패 `BucketNotEmpty` | S3에 프론트 파일 남아 버킷 삭제 불가 | `aws s3 rm --recursive` 후 재destroy + 버킷에 `force_destroy=true` 추가 |

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

1. `terraform apply` (인프라 재생성, ~15분) — destroy된 상태라면
2. `.\redeploy.ps1` (앱 ②~⑦ 자동 배포, ~15~20분) — **식별자/시크릿 자동, 손댈 값 없음**
3. 검증: `https://<cloudfront_url>` + `/actuator/health` 200  (URL은 `terraform output cloudfront_url`)
4. (선택) mock-server + 카드 시드로 알림 E2E
5. 끝나면 `terraform destroy`

> 즉 다음 세션은 **`terraform apply` → `.\redeploy.ps1`** 두 줄이면 지금 상태로 복귀(데이터 제외).
