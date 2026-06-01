# AWS Infra (Terraform)

AWS 인프라를 Terraform으로 관리합니다.
설계 방침: **처음부터 private + 멀티 AZ + SSM 접속** (나중에 마이그레이션 안 하도록).

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
 │ AI 서버      │   │ Grafana+Prom │
 └──────────────┘   │ +ELK         │
                    └──────────────┘
 ┌──────────────┐   ┌──────────────────────────┐
 │ RDS Postgres │   │ EC2 batch (Spring Batch) │
 │ (추후)       │   │ EventBridge Scheduler로  │
 └──────────────┘   │ 시간 맞춰 start/stop     │
                    └──────────────────────────┘

모든 EC2 = private 서브넷 / 공인 IP 없음 / SSM으로 접속
```

## 현재 만들어지는 것

- VPC `10.0.0.0/16` (서울 `ap-northeast-2`, **2 AZ**: a/c)
- public 서브넷 2개(NAT/추후 ALB) + private 서브넷 2개(EC2/추후 RDS)
- Internet Gateway + **NAT Gateway 1개**(private 아웃바운드)
- SG `internal` (VPC 내부 통신만 / 인터넷 인바운드 없음)
- **IAM 역할 + SSM** → SSH 키·bastion 없이 접속
- EC2 4대(전부 private, 2 AZ 분산):

  | 이름 | 타입 | 용도 | 비고 |
  |------|------|------|------|
  | `app` | t3.medium | Spring Boot | |
  | `kafka` | t3.small | Kafka 단일 | |
  | `ai` | t3.medium | AI 서버 | CPU only (GPU 미사용) |
  | `monitoring` | t3.medium | Grafana+Prometheus+ELK | 4GB로 시작, 빠듯하면 t3.large |

> 💡 모니터링이 같은 VPC 안에 있어서 private EC2를 자유롭게 scrape/수집합니다 (VPN 불필요).

## 사전 준비

1. **AWS CLI 설치 + 자격증명** (현재 미설치)
   ```powershell
   winget install Amazon.AWSCLI
   aws configure   # Access Key / Secret / region(ap-northeast-2)
   ```
2. **Terraform 설치** (현재 미설치, >= 1.5)
   ```powershell
   winget install HashiCorp.Terraform
   ```
3. **Session Manager plugin 설치** (SSM 접속용)
   - https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html

## 실행

```powershell
cd infra/terraform
Copy-Item terraform.tfvars.example terraform.tfvars   # 필요시 값 수정
terraform init
terraform plan      # 무엇이 생기는지 검토 (중요)
terraform apply     # yes 입력
```

## 접속 (SSM)

```powershell
terraform output instance_ids          # 인스턴스 ID 확인
terraform output ssm_connect_commands  # 바로 복사해서 사용

# 셸 접속 예시
aws ssm start-session --target i-0abc123...

# 로컬에서 Grafana(3000) 보기 — 포트 포워딩
aws ssm start-session --target <monitoring-id> `
  --document-name AWS-StartPortForwardingSession `
  --parameters '{"portNumber":["3000"],"localPortNumber":["3000"]}'
# → 브라우저 http://localhost:3000
```

> SSM 접속이 되려면 인스턴스가 부팅 후 NAT 통해 SSM에 등록될 때까지 1~2분 필요.

## 연결 검증 (verify.ps1)

apply 후 연결이 정상인지 자동 확인하는 스크립트. **컨테이너 안 올린 상태에선 SSM 전체 Online이면 합격** (NAT/IAM/라우팅/SSM 정상).

```powershell
cd infra/terraform
./verify.ps1                      # 핵심: SSM 등록 상태 확인
./verify.ps1 -Deep               # + NAT 아웃바운드 + 인스턴스 간 통신
./verify.ps1 -WaitMinutes 5      # 부팅 직후 등록 대기 시간 늘리기
```

| 체크 | 의미 |
|------|------|
| 도구/자격증명 | aws·terraform 설치 + `aws configure` |
| SSM Online (4대) | NAT·IAM·라우팅·SSM 한 번에 검증 (핵심) |
| (-Deep) NAT 아웃바운드 | 각 EC2의 외부 IP == NAT IP 확인 |
| (-Deep) 내부 통신 | app → 나머지 ping 도달 (internal SG) |

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
- 배치 EC2는 스케줄로 자동 on/off 되어 상시 과금 아님 (단, EBS는 꺼져 있어도 과금).

## 정리(삭제)

```powershell
terraform destroy
```

## 다음 단계 (TODO)

- [ ] **ALB + 타깃 그룹** (public 서브넷 2 AZ) → app으로 외부 트래픽 유입 *(추후 예정)*
- [ ] RDS PostgreSQL (private, Multi-AZ)
- [ ] CloudFront + S3 (프론트 정적 호스팅)
- [ ] (HA 강화 시) NAT를 AZ당 1개로 + private RT AZ별 분리
- [ ] state를 S3 백엔드로 이전 (`providers.tf` 참고)
```

왜 venv가 정답인가 — "삭제 = 폴더 지우기"
핵심 포인트 하나 짚고 갈게요: 우리 작업엔 Session Manager 플러그인(설치 까다로운 MSI)이 필요 없습니다.

verify.ps1은 describe-instance-information / send-command만 써서 플러그인 불필요
플러그인은 나중에 aws ssm start-session(셸 직접 접속/포트포워딩) 할 때만 필요
그래서 aws cli는 venv에 pip로, terraform은 폴더에 exe 하나로 두면 됩니다. 둘 다 시스템/레지스트리/Program Files 안 건드리고, 나중에 폴더만 지우면 끝입니다. (winget·MSI는 제어판 제거 필요)

참고: python 3.11.9, winget 둘 다 설치돼 있는 거 확인했어요. venv 바로 가능합니다.

순서
① venv 만들고 aws cli 설치

cd c:\it\infra\terraform
python -m venv .venv
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # 활성화 차단 풀기(이 창에서만)
.\.venv\Scripts\Activate.ps1                                 # 앞에 (.venv) 붙으면 성공
python -m pip install --upgrade pip
pip install awscli
aws --version
② terraform 포터블 설치 (폴더에 exe만)

$ver = (Invoke-RestMethod "https://checkpoint-api.hashicorp.com/v1/check/terraform").current_version
$zip = "terraform_${ver}_windows_amd64.zip"
Invoke-WebRequest "https://releases.hashicorp.com/terraform/$ver/$zip" -OutFile $zip
Expand-Archive $zip -DestinationPath . -Force
Remove-Item $zip
$env:PATH = "$PWD;$env:PATH"   # 이 창에서 terraform 명령 인식되게 (verify.ps1도 이걸로 인식)
terraform version
③ AWS 자격증명 등록

aws configure
#   AWS Access Key ID     : (발급받은 키)
#   AWS Secret Access Key : (발급받은 시크릿)
#   Default region name   : ap-northeast-2
#   Default output format : json
aws sts get-caller-identity   # 계정ID 나오면 OK
④ terraform 실행

Copy-Item terraform.tfvars.example terraform.tfvars   # (지금은 그대로 둬도 됨)
terraform init
terraform plan      # "Plan: N to add" 검토
terraform apply     # yes
⑤ 검증 스크립트

.\verify.ps1 -WaitMinutes 5
→ 인스턴스 4대 전부 SSM = Online 이면 합격 (지금 목표는 여기까지)
→ 더 보고 싶으면 .\verify.ps1 -Deep

나중에 깔끔하게 삭제 (전부 복구)

terraform destroy                       # ① AWS 리소스 삭제 (과금 중단)
deactivate                              # ② venv 빠져나오기
Remove-Item .venv -Recurse -Force       # ③ aws cli 삭제 = 폴더 삭제
Remove-Item terraform.exe               #    terraform 삭제 = 파일 삭제
Remove-Item .terraform -Recurse -Force  #    init 캐시 삭제
Remove-Item "$env:USERPROFILE\.aws" -Recurse -Force   # ④ 저장된 자격증명까지 지우려면
이 한 가지만 기억하세요: 도구는 전부 infra\terraform 폴더 안(.venv, terraform.exe)에만 설치되고, 시스템엔 흔적이 거의 없습니다. aws configure로 저장한 키만 ~\.aws에 따로 남아서 위 ④로 지우면 완전히 깨끗해집니다.

⚠️ 주의: 새 PowerShell 창을 열면 venv 재활성화(.\.venv\Scripts\Activate.ps1)와 PATH 추가($env:PATH = "$PWD;$env:PATH")를 다시 해줘야 aws/terraform이 인식됩니다.

막히는 단계 있으면 그 창에 나온 에러 그대로 붙여주세요.