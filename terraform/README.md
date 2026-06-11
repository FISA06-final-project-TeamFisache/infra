# AWS Infra (Terraform)

AWS 인프라를 Terraform으로 관리합니다.
설계 방침: **처음부터 private + 멀티 AZ + SSM 접속** (나중에 마이그레이션 안 하도록).

> 🚀 **처음 해보는 팀원은 맨 아래 [팀원용 전체 절차](#-팀원용-전체-절차-설치--실행--삭제) 를 그대로 복붙**하면 설치→생성→검증→배포→삭제까지 됩니다.

## 아키텍처 (현재 구성 — 전부 코드에 있음)

```
                      [브라우저]
                          │ HTTPS
                    [CloudFront]              ← 단일 진입점 (*.cloudfront.net 무료 인증서)
                  ┌───────┴────────┐
   기본(정적)     │                │  /api/*, /actuator/*, ai 경로들
              [S3 버킷]      [ALB (public, 2 AZ, HTTP 80)]
           (비공개, OAC만)        │ default → 8080   ai 경로 → 8000
                            ┌─────┴──────┐
                     ┌──────────────┐ ┌──────────────┐
                     │ EC2 app      │ │ EC2 ai       │
                     │ Spring(8080) │ │ FastAPI(8000)│
                     └──────────────┘ └──────────────┘
                     ┌──────────────┐ ┌───────────────────┐
                     │ EC2 kafka    │ │ EC2 monitoring    │
                     │ Kafka+Redis  │ │ Grafana+Prom+ELK  │
                     └──────────────┘ └───────────────────┘
                     ┌──────────────┐ ┌──────────────────────────┐
                     │ RDS Postgres │ │ EC2 jenkins (CI/CD)      │
                     │ private/2AZ  │ │ SSM 포트포워딩으로 UI접속│
                     └──────────────┘ │ ※ enable_jenkins(기본 on)│
                                      └──────────────────────────┘

모든 EC2 = private 서브넷 / 공인 IP 없음 / SSM으로 접속
Spring Batch = 분리 안 함 — app(Spring Boot) 안에서 스케줄링으로 실행
RDS = private / 공인 접근 불가 / EC2(internal SG)에서만 5432 접속
ALB→EC2 = internal SG(VPC 내부 전체 허용)로 통신 (별도 SG 규칙 불필요)
```

### 경로 라우팅 (CloudFront → ALB → 타깃)

| 경로 | CloudFront | ALB 타깃 |
|------|-----------|----------|
| `/`, `/dashboard` 등 그 외 전부 | S3 (정적, SPA fallback: 403/404→index.html) | — |
| `/api/*`, `/actuator/*` | ALB (캐시 끔) | backend (app:8080) |
| `/consultant/*` `/portfolio/*` `/mini_challenge/*` `/report*` `/salary*` `/propose` | ALB (캐시 끔) | ai-server (ai:8000) |

경로 목록은 [alb.tf](alb.tf)의 `locals` 한 곳에서 관리합니다 (CloudFront 동작도 같은 목록 사용).

## 만들어지는 리소스 (파일별)

| 파일 | 내용 |
|------|------|
| `network.tf` | VPC `10.0.0.0/16` (서울, 2 AZ: a/c), public×2 + private×2 서브넷, IGW, **NAT GW 1개**, 라우트 테이블 |
| `security.tf` | SG `internal` — VPC 내부 통신 전체 허용, 인터넷 인바운드 없음 |
| `iam.tf` | SSM 접속용 역할/프로파일 + app EC2의 **S3 업로드·CloudFront 무효화** 권한(프론트 배포용) |
| `ec2.tf` | EC2 4대 (private, 2 AZ 분산, AL2023, gp3 20GB) + 부트스트랩 user_data |
| `bootstrap.sh.tftpl` | 부팅 시 docker/git/compose 설치 + 역할별 레포를 `/opt`에 clone (컨테이너 기동은 안 함 → 배포 단계에서) |
| `rds.tf` | RDS PostgreSQL 16 (private 2 AZ 서브넷 그룹, 전용 SG: internal에서만 5432) — `enable_rds`로 on/off |
| `alb.tf` | ALB(public 2 AZ) + 타깃그룹 2개(backend 8080 / ai 8000) + 경로 라우팅 리스너 |
| `cdn.tf` | S3 프론트 버킷(비공개, OAC) + CloudFront(정적=S3, API=ALB 이중 origin, HTTPS) |
| `jenkins.tf` | Jenkins EC2(t3.medium, private) + 전용 IAM(타 EC2 SSM 배포 명령 + S3 + CloudFront) — `enable_jenkins`로 on/off (기본 on) |
| `outputs.tf` | 접속 주소·인스턴스 ID·RDS 접속정보·버킷/배포 ID 등 |

### EC2

| 이름 | 타입 | 용도 | 부트스트랩 | 비고 |
|------|------|------|-----------|------|
| `app` | t3.medium | Spring Boot(8080) + 프론트 빌드/업로드 | backend, mock-server clone | 배치도 app 안에서 스케줄링 |
| `kafka` | t3.small | Kafka + Redis | infra clone | |
| `ai` | t3.small | FastAPI(8000) — 외부 LLM API 호출 | ai-server clone | 무거우면 t3.medium |
| `monitoring` | t3.medium | Grafana+Prometheus+ELK | infra clone | 빠듯하면 t3.large |
| `jenkins` | t3.medium | CI/CD (Jenkins 네이티브 설치) | java21 + jenkins 설치/기동 | `jenkins.tf` 별도 관리, `enable_jenkins` |

clone 대상 GitHub 조직은 `github_org` 변수(기본 `FISA06-final-project-TeamFisache`).
공통 부트스트랩: docker / git / docker compose 설치 (컨테이너 기동은 배포 단계에서).

### RDS PostgreSQL

| 항목 | 기본값 | 비고 |
|------|--------|------|
| 생성 여부 | `enable_rds = true` | `false`로 apply 하면 RDS만 삭제(EC2 유지) |
| 타입 | `db.t3.micro` | 운영은 `db.t3.medium`+ |
| 스토리지 | 20GB(gp3, 암호화) | 100GB까지 오토스케일 |
| Multi-AZ | `false` | 운영 전환 시 `true` (서브넷 그룹이 2 AZ라 재생성 없이 가능) |
| 비밀번호 | 자동 생성 | `terraform output -raw rds_password` |

> 💡 모니터링이 같은 VPC 안에 있어서 private EC2를 자유롭게 scrape/수집합니다 (VPN 불필요).

## 사전 준비 (도구 설치 — 2가지 방법)

도구는 `aws` CLI 와 `terraform` 두 개입니다. 둘 중 편한 방법을 고르세요.

- **방법 A — 포터블(권장, 관리자 권한 불필요)**: 도구를 이 폴더 안에만 설치 → 나중에 폴더 삭제로 깔끔히 제거.
  명령은 아래 [팀원용 전체 절차](#-팀원용-전체-절차-설치--실행--삭제) 0번 참고.
- **방법 B — winget(시스템 전역 설치)**: 빠르지만 제어판으로 제거해야 함.
  ```powershell
  winget install HashiCorp.Terraform
  winget install Amazon.AWSCLI
  ```

> SSM **셸 직접 접속/포트포워딩**을 쓸 때만 Session Manager plugin 이 추가로 필요합니다
> (생성·검증·`verify.ps1`·`redeploy.ps1` 에는 불필요 — send-command 만 사용). 설치: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

## 접속

```powershell
terraform output cloudfront_url        # 브라우저 접속 주소 (프론트+API 단일 진입점)
terraform output alb_dns_name          # ALB 직접 주소 (디버깅용 HTTP)
terraform output instance_ids          # 인스턴스 ID 확인
terraform output ssm_connect_commands  # SSM 셸 접속 명령 (복사해서 사용)

# 셸 접속 예시 (Session Manager plugin 필요)
aws ssm start-session --target i-0abc123...

# 로컬에서 Grafana(3000) 보기 — 포트 포워딩
aws ssm start-session --target <monitoring-id> `
  --document-name AWS-StartPortForwardingSession `
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
# → 브라우저 http://localhost:3000
```

> SSM 접속이 되려면 인스턴스가 부팅 후 NAT 통해 SSM에 등록될 때까지 1~2분 필요.

## RDS (PostgreSQL) 접속/사용

RDS 는 **private** 이라 인터넷에서 직접 못 붙습니다. EC2(internal SG)에서만 5432 로 접속됩니다.

```powershell
terraform output rds_endpoint           # 접속 호스트 (private DNS)
terraform output rds_jdbc_url           # Spring 용 JDBC URL
terraform output -raw rds_password      # 자동 생성된 비밀번호 (sensitive)
```

앱에는 `redeploy.ps1` 이 이 값들을 환경변수(`SPRING_DATASOURCE_URL` 등)로 자동 주입합니다 — 아래 [앱 배포](#앱-배포-redeployps1) 참고.

> 로컬 PC 에서 직접 DB 를 보려면 SSM 포트포워딩으로 터널을 뚫어야 합니다
> (private 이라 바로 접속 불가). 서비스 경로는 전부 VPC 내부라 터널 불필요.

## 연결 검증 (verify.ps1)

apply 후 연결이 정상인지 자동 확인하는 스크립트. **컨테이너 안 올린 상태에선 SSM 전체 Online이면 합격** (NAT/IAM/라우팅/SSM 정상).

```powershell
./verify.ps1                      # 핵심: SSM 등록 상태 확인
./verify.ps1 -Deep               # + NAT 아웃바운드 + 내부통신 + RDS 연결
./verify.ps1 -WaitMinutes 5      # 부팅 직후 등록 대기 시간 늘리기
```

| 체크 | 의미 |
|------|------|
| 도구/자격증명 | aws·terraform 설치 + `aws configure` |
| SSM Online (4대) | NAT·IAM·라우팅·SSM 한 번에 검증 (핵심) |
| (-Deep) NAT 아웃바운드 | 각 EC2의 외부 IP == NAT IP 확인 |
| (-Deep) 내부 통신 | app → 나머지 ping 도달 (internal SG) |
| (-Deep) RDS 연결 | app → RDS 5432 TCP 연결 (rds SG/서브넷) |

> ✅ **검증 완료(2026-06-02)**: EC2 4대 + RDS 구성으로 `apply` → `verify.ps1 -Deep` 전체 통과 확인됨.

> ⚠️ **인코딩 주의**: `verify.ps1` 은 한글이 포함돼 있어 반드시 **UTF-8 + BOM** 으로 저장해야 합니다.
> Windows PowerShell 5.1 은 BOM 없는 파일을 ANSI(cp949)로 읽어 한글이 깨지고 **스크립트 파싱이 실패**합니다.
> 에디터에서 수정 시 인코딩이 "UTF-8(BOM 없음)"으로 바뀌지 않게 주의. (BOM 재적용:
> `$c=Get-Content -Raw -Encoding UTF8 verify.ps1; Set-Content verify.ps1 -Value $c -Encoding UTF8 -NoNewline`)

## 앱 배포 (redeploy.ps1)

인프라 생성 후 **컨테이너 기동/프론트 업로드까지 자동화**한 스크립트.
`terraform output` 에서 IP/RDS/버킷 정보를 읽어, 각 EC2에 SSM send-command 로 [deploy/](deploy/) 스크립트를 순서대로 실행합니다.

```powershell
.\redeploy.ps1            # 실제 배포 (kafka → monitoring → ai → backend → frontend 순)
.\redeploy.ps1 -DryRun    # 값 주입만 검증 (SSM 미실행)
```

| 순서 | 스크립트 | 대상 EC2 | 하는 일 |
|------|----------|----------|---------|
| ① | `deploy/kafka.sh` | kafka | Kafka+Redis 기동 (advertised listener = 사설 IP) |
| ② | `deploy/monitoring.sh` | monitoring | Prometheus/Grafana/ELK 기동 (타깃 IP 치환) |
| ③ | `deploy/ai.sh` | ai | ai-server `.env` 생성 후 compose 기동 |
| ④ | `deploy/backend.sh` | app | backend 빌드/기동 (RDS·Kafka·AI 주소 환경변수 주입) |
| ⑤ | `deploy/frontend.sh` | app | 프론트 빌드 → S3 sync → CloudFront 무효화 |

**전제 조건** (시크릿은 로컬에서 읽어 주입):
- `terraform apply` 완료 + EC2 부트스트랩 완료(`/opt`에 레포 clone — 부팅 후 수 분)
- 로컬 `ai-server/.env` 에 `OPENAI_API_KEY`, `TAVILY_API_KEY` (LLM 키)
- 로컬 `backend/src/main/resources/application-secret.yml` (JWT 등 — base64로 컨테이너에 마운트)

배포 후 확인: `curl <cloudfront_url>/` + `curl <cloudfront_url>/actuator/health`

## 인스턴스 추가/변경

`variables.tf` 의 `instances` 맵만 수정. `subnet_index`(0/1)로 AZ 지정.
(배치는 start/stop 스케줄이 따로 필요해 아래 별도 관리)

## Jenkins (CI/CD)

`jenkins.tf` 로 Jenkins EC2가 생성됩니다 (`enable_jenkins = true` 기본 on, 끄면 Jenkins EC2/IAM만 삭제).
private 서브넷이라 **UI 접속은 SSM 포트포워딩**으로만 합니다 (Session Manager plugin 필요).

```powershell
# 포워딩 명령은 output으로 제공 — 실행 후 브라우저 http://localhost:8081
terraform output -raw jenkins_port_forward

# 초기 관리자 비밀번호 (SSM 셸 접속 후)
aws ssm start-session --target $(terraform output -raw jenkins_instance_id)
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

- 부트스트랩이 java 21 + Jenkins(공식 yum repo) 설치/기동 + `jenkins` 유저에 docker 권한 부여까지 합니다.
- **GitHub webhook은 못 받습니다** (private — 인바운드 없음). 빌드 트리거는 **SCM 폴링** 또는 수동.
- Jenkins 역할에 배포 권한이 있어 파이프라인에서 `redeploy.ps1` 이 하던 일을 그대로 할 수 있습니다:
  타 EC2에 `aws ssm send-command` 로 [deploy/](deploy/) 스크립트 실행 + 프론트 `s3 sync` + CloudFront 무효화.
- **Spring Batch는 EC2로 분리하지 않습니다** — app(Spring Boot) 안에서 `@Scheduled` 등으로 실행.
  (이전의 배치 EC2 + EventBridge start/stop 구성은 제거됨 — 필요해지면 git 히스토리에서 복구)

## ⚠️ 비용 주의

- **NAT Gateway**: 시간당 + 데이터 처리 요금 (대략 월 $32~ + 트래픽). 안 쓸 땐 `terraform destroy`.
- **ALB**: 시간당 과금 (대략 월 $20~ + LCU). 켜두면 상시 과금.
- **CloudFront/S3**: 사용량 과금 — 데모 트래픽 수준이면 거의 무료.
- EC2 4대 + EBS. 개발 끝나면 내려두기.
- **Jenkins EC2**: t3.medium 상시 켜두면 월 ~$38 + EBS 30GB. 안 쓸 땐 `enable_jenkins = false` 로 apply (EC2/IAM만 삭제).
- **RDS**: 상시 과금(인스턴스 + 스토리지). `db.t3.micro` single-AZ 로 시작. Multi-AZ 켜면 약 2배. 안 쓸 땐 destroy.

## 다음 단계 (TODO)

- [x] ALB + 타깃 그룹 (public 2 AZ, backend/ai 경로 라우팅) — `alb.tf`
- [x] CloudFront + S3 (프론트 정적 + API 단일 진입점, HTTPS) — `cdn.tf`
- [x] RDS PostgreSQL (private, 2 AZ 서브넷 그룹 / Multi-AZ 옵션 / `enable_rds` on-off)
- [x] Spring ↔ RDS 연결 — `redeploy.ps1`(backend.sh)이 `terraform output` 값을 환경변수로 주입
- [x] 앱 배포 자동화 — `redeploy.ps1` + `deploy/*.sh` (SSM send-command)
- [x] Jenkins EC2 (private, SSM 포트포워딩, 배포용 IAM) — `jenkins.tf`
- [ ] **Jenkins 파이프라인 작성** — Jenkinsfile 로 `redeploy.ps1` 의 배포 흐름 이관 (deploy/*.sh 를 send-command 로 실행)
- [ ] 커스텀 도메인 + ACM 인증서 (현재는 *.cloudfront.net)
- [ ] (HA 강화 시) NAT를 AZ당 1개로 + private RT AZ별 분리
- [ ] state를 S3 백엔드로 이전 (`providers.tf` 참고)

---

# 🚀 팀원용 전체 절차 (설치 → 실행 → 삭제)

처음부터 끝까지 **복붙으로** 따라 할 수 있게 정리했습니다.

- **사전 조건**: Windows + Python 3.11+ (`python --version` 으로 확인), 본인 AWS Access Key/Secret (VPC/EC2/RDS/IAM/ALB/CloudFront/S3 생성 권한).
- **방침**: 도구는 전부 `infra\terraform` 폴더 안에만 설치 → **관리자 권한 불필요**, 나중에 폴더 정리로 깔끔히 제거.
- ⚠️ **새 PowerShell 창을 열 때마다 [2번 PATH] 한 줄을 다시 실행**해야 `terraform`·`aws` 명령이 인식됩니다. (키는 `~/.aws`에 저장돼 PATH와 무관)

### 0. 도구 설치 (최초 1회)

```powershell
cd c:\itstudy\infra\terraform

# (1) aws CLI — venv 안에 설치
python -m venv .venv
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # 활성화 차단 풀기(이 창에서만)
.\.venv\Scripts\Activate.ps1                                 # 앞에 (.venv) 붙으면 성공
python -m pip install --upgrade pip
pip install awscli
aws --version

# (2) terraform — 폴더에 exe 하나로 (포터블)
$ver = (Invoke-RestMethod "https://checkpoint-api.hashicorp.com/v1/check/terraform").current_version
$zip = "terraform_${ver}_windows_amd64.zip"
Invoke-WebRequest "https://releases.hashicorp.com/terraform/$ver/$zip" -OutFile $zip
Expand-Archive $zip -DestinationPath . -Force; Remove-Item $zip
.\terraform.exe version
```

### 1. AWS 자격증명 (최초 1회)

```powershell
aws configure
#   AWS Access Key ID     : (발급받은 키)
#   AWS Secret Access Key : (시크릿)
#   Default region name   : ap-northeast-2
#   Default output format : json

aws sts get-caller-identity   # 계정 ID 나오면 성공
```

> 키는 `~/.aws` 파일에 한 번 저장되면 끝(매번 입력 X, 새 창에서도 유지).
> 키 발급: AWS 콘솔 → **IAM → 사용자 → 보안 자격 증명 → 액세스 키 만들기(CLI)**.
> **Secret 은 생성 화면에서 딱 한 번만 보임 — 즉시 복사/다운로드.**

### 2. PATH 잡기 (⚠️ 새 창마다)

```powershell
cd c:\itstudy\infra\terraform
$env:PATH = "$PWD;$PWD\.venv\Scripts;$env:PATH"   # terraform + aws 둘 다 인식
```

### 3. 생성 (apply)

```powershell
Copy-Item terraform.tfvars.example terraform.tfvars -ErrorAction SilentlyContinue  # 필요시 값 수정
terraform init        # 최초 1회 (프로바이더 다운로드)
terraform plan        # "Plan: N to add" 검토 (중요)
terraform apply       # yes 입력 → 생성 (RDS+CloudFront 때문에 ~15분 소요)
```

### 4. 검증 (verify.ps1)

```powershell
.\verify.ps1 -Deep -WaitMinutes 5
# EC2 4대 SSM Online + NAT + 내부통신 + RDS 5432 가 전부 [ OK ] 면 합격
```

### 5. 앱 배포 (redeploy.ps1)

```powershell
# 전제: 로컬에 ai-server/.env (LLM 키) + backend/.../application-secret.yml 존재
.\redeploy.ps1 -DryRun    # 먼저 값 주입 검증
.\redeploy.ps1            # kafka → monitoring → ai → backend → frontend 순 배포
terraform output cloudfront_url   # 이 주소로 접속
```

### 6. 삭제 (destroy — 과금 중단)

```powershell
terraform destroy     # yes 입력 → 전부 삭제 (CloudFront 비활성화 포함 ~15분). 이후 과금 0
```

> `terraform` 명령은 venv 활성화 없이도 됩니다(키를 `~/.aws`에서 직접 읽음). 단 **[2번 PATH]는 필요**.
> RDS만 잠깐 끄려면: `terraform.tfvars` 에 `enable_rds = false` 두고 `terraform apply` → EC2는 유지, RDS만 삭제.

### 7. (선택) 도구까지 완전 제거

```powershell
deactivate                                            # venv 빠져나오기 (활성화했었다면)
Remove-Item .venv,.terraform -Recurse -Force          # aws CLI + init 캐시
Remove-Item terraform.exe,.terraform.lock.hcl -Force  # terraform 바이너리/락
Remove-Item terraform.tfstate* -Force                 # 로컬 state (destroy 후엔 빈 파일)
Remove-Item "$env:USERPROFILE\.aws" -Recurse -Force   # 저장된 AWS 키까지 지우려면
```

> 도구는 전부 `infra\terraform` 폴더 안에만 있어서 폴더 정리로 끝. 시스템/레지스트리엔 흔적이 거의 없습니다.
> (winget 으로 깔았다면 제어판 또는 `winget uninstall` 로 제거)

### 자주 막히는 곳

| 증상 | 원인 / 해결 |
|------|------------|
| `terraform : 명령을 찾을 수 없음` | [2번 PATH] 안 함. 새 창마다 다시 실행 |
| `aws : 명령을 찾을 수 없음` | venv 미설치/미활성 또는 PATH 누락. 0번·2번 확인 |
| `Activate.ps1 ... 실행할 수 없습니다` | `Set-ExecutionPolicy -Scope Process Bypass` 먼저 |
| `NoCredentialProviders` / 인증 실패 | 1번 `aws configure` 안 됨. `aws sts get-caller-identity` 로 확인 |
| `verify.ps1` 한글 깨지고 파싱 에러 | 파일이 UTF-8(BOM 없음). 위 **인코딩 주의** 참고해 BOM 재적용 |
| SSM 일부 OFFLINE | 부팅 직후. `-WaitMinutes` 늘려 재시도 (NAT 등록에 1~2분) |
| `redeploy.ps1` 에서 레포 없음 에러 | EC2 부트스트랩(`/opt` clone)이 아직 안 끝남. 부팅 후 수 분 대기 |
| CloudFront 주소 403/404 | 프론트 미업로드 상태. 5번 `redeploy.ps1` 실행 (frontend 단계가 S3 sync) |
