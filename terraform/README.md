# AWS Infra (Terraform)

AWS 인프라를 Terraform으로 관리합니다.
설계 방침: **처음부터 private + 멀티 AZ + SSM 접속** (나중에 마이그레이션 안 하도록).

> 🚀 **처음 해보는 팀원은 맨 아래 [팀원용 전체 절차](#-팀원용-전체-절차-설치--실행--삭제) 를 그대로 복붙**하면 설치→생성→검증→삭제까지 됩니다.

## 목표 아키텍처

```
[CloudFront + S3]            ← 프론트 정적 (추후)
        │
      [ALB]                  ← 추후 예정 (지금은 안 만듦)
        │  (private로 전달)
 ┌──────────────┐   ┌──────────────┐
 │ EC2 app      │   │ EC2 kafka    │
 │ Spring Boot  │   │ Kafka(단일)  │
 └──────────────┘   └──────────────┘
 ┌──────────────┐   ┌──────────────┐
 │ EC2 ai       │   │ EC2 monitoring│
 │ FastAPI      │   │ Grafana+Prom │
 │ (LLM API호출)│   │ +ELK         │
 └──────────────┘   └──────────────┘
 ┌──────────────┐   ┌──────────────────────────┐
 │ RDS Postgres │   │ EC2 batch (Spring Batch) │
 │ private/2AZ  │   │ EventBridge Scheduler로  │
 │ subnet group │   │ 시간 맞춰 start/stop     │
 └──────────────┘   │ ※ 추후 예정              │
                    └──────────────────────────┘

모든 EC2 = private 서브넷 / 공인 IP 없음 / SSM으로 접속
RDS = private / 공인 접근 불가 / EC2(internal SG)에서만 5432 접속
```

## 현재 만들어지는 것

- VPC `10.0.0.0/16` (서울 `ap-northeast-2`, **2 AZ**: a/c)
- public 서브넷 2개(NAT/추후 ALB) + private 서브넷 2개(EC2/추후 RDS)
- Internet Gateway + **NAT Gateway 1개**(private 아웃바운드)
- SG `internal` (VPC 내부 통신만 / 인터넷 인바운드 없음)
- SG `rds` (Postgres 5432 를 `internal` SG 에서만 허용)
- **IAM 역할 + SSM** → SSH 키·bastion 없이 접속
- EC2 4대(전부 private, 2 AZ 분산):

  | 이름 | 타입 | 용도 | 비고 |
  |------|------|------|------|
  | `app` | t3.medium | Spring Boot | |
  | `kafka` | t3.small | Kafka 단일 | |
  | `ai` | t3.small | FastAPI | 외부 LLM API 호출 프록시(경량). 무거우면 t3.medium |
  | `monitoring` | t3.medium | Grafana+Prometheus+ELK | 4GB로 시작, 빠듯하면 t3.large |

- **RDS PostgreSQL** (private, 2 AZ 서브넷 그룹). `enable_rds` 로 on/off (기본 on):

  | 항목 | 기본값 | 비고 |
  |------|--------|------|
  | 생성 여부 | `enable_rds = true` | `false` 로 apply 하면 RDS 만 삭제(EC2 유지) |
  | 타입 | `db.t3.micro` | 운영은 `db.t3.medium`+ |
  | 스토리지 | 20GB(gp3, 암호화) | 100GB까지 오토스케일 |
  | Multi-AZ | `false` | 운영 전환 시 `true` (재생성 없이 가능) |
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
> (생성·검증·`verify.ps1` 에는 불필요). 설치: https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

## 접속 (SSM)

```powershell
terraform output instance_ids          # 인스턴스 ID 확인
terraform output ssm_connect_commands  # 바로 복사해서 사용

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

앱(Spring Boot)에는 보통 환경변수/`application.yml` 로 주입:

```
SPRING_DATASOURCE_URL=jdbc:postgresql://<rds_endpoint>:5432/appdb
SPRING_DATASOURCE_USERNAME=appuser
SPRING_DATASOURCE_PASSWORD=<terraform output -raw rds_password>
```

> 로컬 PC 에서 직접 DB 를 보려면 SSM 포트포워딩으로 터널을 뚫어야 합니다
> (private 이라 바로 접속 불가). 데모 경로는 전부 VPC 내부라 터널 불필요.

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

> ✅ **검증 완료(2026-06-02)**: 위 전체 구성(EC2 4대 + RDS)으로 `apply` → `verify.ps1 -Deep`
> 모든 항목 통과(SSM Online·NAT·내부통신·RDS 5432) 확인됨.

> ⚠️ **인코딩 주의**: `verify.ps1` 은 한글이 포함돼 있어 반드시 **UTF-8 + BOM** 으로 저장해야 합니다.
> Windows PowerShell 5.1 은 BOM 없는 파일을 ANSI(cp949)로 읽어 한글이 깨지고 **스크립트 파싱이 실패**합니다.
> 에디터에서 수정 시 인코딩이 "UTF-8(BOM 없음)"으로 바뀌지 않게 주의. (BOM 재적용:
> `$c=Get-Content -Raw -Encoding UTF8 verify.ps1; Set-Content verify.ps1 -Value $c -Encoding UTF8 -NoNewline`)

## 인스턴스 추가/변경

`variables.tf` 의 `instances` 맵만 수정. `subnet_index`(0/1)로 AZ 지정.
(배치는 start/stop 스케줄이 따로 필요해 아래 별도 관리)

## Spring Batch (분리 시)

배치는 정해진 시간에만 돌면 되므로, **EventBridge Scheduler로 EC2를 켰다(start) 끄는(stop)** 방식으로 비용을 아낍니다. `batch.tf` 에 정의되어 있고 **`enable_batch` 플래그로 켜고 끕니다.**

```hcl
# terraform.tfvars
enable_batch     = true
batch_start_cron = "cron(50 1 * * ? *)"  # 매일 01:50 KST 시작
batch_stop_cron  = "cron(0 3 * * ? *)"   # 매일 03:00 KST 중지
```

`terraform apply` 하면 다음이 생깁니다:
- 배치 EC2 1대 (private, SSM 접속, 기본 t3.small)
- EventBridge Scheduler 2개 (start / stop, 시간대 `Asia/Seoul`)
- 스케줄러가 해당 EC2만 start/stop 하도록 제한된 IAM 역할

> 동작: 시작 스케줄에 EC2가 켜짐 → 부팅 시 배치 잡 실행(앱 자동 시작 설정 필요) → 중지 스케줄에 꺼짐.
> cron 형식: `cron(분 시 일 월 요일 연)`. 평일만 돌리려면 요일 자리를 `MON-FRI` 로.

기본값(`enable_batch = false`)일 때는 배치 관련 리소스가 **하나도 생기지 않습니다.**

## ⚠️ 비용 주의

- **NAT Gateway**: 시간당 + 데이터 처리 요금 (대략 월 $32~ + 트래픽). 안 쓸 땐 `terraform destroy`.
- EC2 4대 + EBS. 개발 끝나면 내려두기.
- **RDS**: 상시 과금(인스턴스 + 스토리지). `db.t3.micro` single-AZ 로 시작. Multi-AZ 켜면 약 2배. 안 쓸 땐 destroy.
- 배치 EC2는 스케줄로 자동 on/off 되어 상시 과금 아님 (단, EBS는 꺼져 있어도 과금).

## 다음 단계 (TODO)

- [ ] **ALB + 타깃 그룹** (public 서브넷 2 AZ) → app으로 외부 트래픽 유입 *(추후 예정)*
- [ ] **EC2 batch (Spring Batch)** + EventBridge start/stop *(추후 예정 — `batch.tf`, `enable_batch`)*
- [x] RDS PostgreSQL (private, 2 AZ 서브넷 그룹 / Multi-AZ 옵션 / `enable_rds` on-off)
- [ ] **Spring `application.yml` ↔ RDS 연결** — `terraform output` 의 DB 정보를 앱이 환경변수로 받아 쓰도록 주입 (`SPRING_DATASOURCE_URL/USERNAME/PASSWORD`) *(추후)*
- [ ] CloudFront + S3 (프론트 정적 호스팅)
- [ ] (HA 강화 시) NAT를 AZ당 1개로 + private RT AZ별 분리
- [ ] state를 S3 백엔드로 이전 (`providers.tf` 참고)

---

# 🚀 팀원용 전체 절차 (설치 → 실행 → 삭제)

처음부터 끝까지 **복붙으로** 따라 할 수 있게 정리했습니다.

- **사전 조건**: Windows + Python 3.11+ (`python --version` 으로 확인), 본인 AWS Access Key/Secret (VPC/EC2/RDS/IAM 생성 권한).
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
terraform apply       # yes 입력 → 생성 (RDS 때문에 ~10분 소요)
```

### 4. 검증 (verify.ps1)

```powershell
.\verify.ps1 -Deep -WaitMinutes 5
# EC2 4대 SSM Online + NAT + 내부통신 + RDS 5432 가 전부 [ OK ] 면 합격
```

### 5. 삭제 (destroy — 과금 중단)

```powershell
terraform destroy     # yes 입력 → 전부 삭제 (~7~10분). 이후 과금 0
```

> `terraform` 명령은 venv 활성화 없이도 됩니다(키를 `~/.aws`에서 직접 읽음). 단 **[2번 PATH]는 필요**.
> RDS만 잠깐 끄려면: `terraform.tfvars` 에 `enable_rds = false` 두고 `terraform apply` → EC2는 유지, RDS만 삭제.

### 6. (선택) 도구까지 완전 제거

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
