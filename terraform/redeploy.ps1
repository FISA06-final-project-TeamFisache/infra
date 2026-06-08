# 앱 기동 자동화 — terraform output에서 식별자를 읽어 ②kafka~⑦frontend를 SSM으로 배포.
# 사용:
#   cd c:\itstudy\infra\terraform
#   .\redeploy.ps1            # 실제 배포
#   .\redeploy.ps1 -DryRun    # 값 주입만 검증(SSM 미실행)
#
# 전제: terraform apply 완료(인프라 살아있음) + EC2 부트스트랩 완료(/opt에 레포 clone) +
#       Session Manager 불필요(send-command 사용), aws 자격증명만 있으면 됨.
# 시크릿 출처: RDS비번=terraform output / OpenAI·Tavily=로컬 ai-server/.env / JWT=로컬 application-secret.yml(마운트)
param([switch]$DryRun)

$ErrorActionPreference = "Stop"
$here = $PSScriptRoot
Set-Location $here
$env:PATH = "$here;$here\.venv\Scripts;$env:PATH"
$env:PYTHONIOENCODING = "utf-8"
. "$here\ssm-run.ps1"

$tf = "$here\terraform.exe"
Write-Host "=== terraform output 읽는 중 ==="
$ids    = (& $tf output -json instance_ids) | ConvertFrom-Json
$ips    = (& $tf output -json instance_private_ips) | ConvertFrom-Json
$rds    = (& $tf output -raw rds_endpoint)
$pw     = (& $tf output -raw rds_password)
$cf     = (& $tf output -raw cloudfront_url)
$bucket = (& $tf output -raw frontend_bucket)
$dist   = (& $tf output -raw cloudfront_distribution_id)
$pwEnc  = [uri]::EscapeDataString($pw)

# 로컬 ai-server/.env 에서 LLM 키 파싱
function Get-EnvVal($file, $key) {
  $line = Get-Content $file | Where-Object { $_ -match "^\s*$key\s*=" } | Select-Object -First 1
  if ($line) { return ($line -replace "^\s*$key\s*=", "").Trim() } else { return "" }
}
$aiEnv  = "$here\..\..\ai-server\.env"
$openai = Get-EnvVal $aiEnv "OPENAI_API_KEY"
$tavily = Get-EnvVal $aiEnv "TAVILY_API_KEY"
$llm    = Get-EnvVal $aiEnv "LLM_MODEL"; if (-not $llm) { $llm = "gpt-4o-mini-2024-07-18" }
if (-not $openai) { throw "ai-server/.env 에서 OPENAI_API_KEY 를 못 읽음: $aiEnv" }

# backend secret 파일(application-secret.yml) → base64 (컨테이너에 마운트)
$secretPath = "$here\..\..\backend\src\main\resources\application-secret.yml"
$secretB64  = [Convert]::ToBase64String([IO.File]::ReadAllBytes($secretPath))

Write-Host ("app={0}/{1}  ai={2}/{3}  kafka={4}/{5}  mon={6}/{7}" -f `
  $ids.app, $ips.app, $ids.ai, $ips.ai, $ids.kafka, $ips.kafka, $ids.monitoring, $ips.monitoring)
Write-Host "rds=$rds  cloudfront=$cf  bucket=$bucket"

function Run-Step($name, $instId, $tpl, [hashtable]$repl, $timeout) {
  Write-Host "`n========== $name ($instId) =========="
  $bash = Get-Content -Raw $tpl
  foreach ($k in $repl.Keys) { $bash = $bash.Replace($k, [string]$repl[$k]) }
  $bash = $bash.Replace("`r`n", "`n")   # EC2(Linux)용 LF 강제
  $left = ([regex]::Matches($bash, "__[A-Z][A-Z0-9_]+__") | ForEach-Object { $_.Value } | Select-Object -Unique)
  if ($left) { Write-Host "  [WARN] 미치환 플레이스홀더: $($left -join ', ')" }
  if ($DryRun) {
    Write-Host "  [DRYRUN] bytes=$($bash.Length)  (SSM 미실행)"
    return
  }
  $tmp = Join-Path $env:TEMP ("dep-" + [guid]::NewGuid().ToString('N') + ".sh")
  [IO.File]::WriteAllText($tmp, $bash, (New-Object Text.UTF8Encoding($false)))
  $b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($tmp))
  Remove-Item $tmp -Force
  $st = Invoke-SSM -InstanceId $instId -Script "echo $b64 | base64 -d | bash" -TimeoutSec $timeout
  if ($st -ne "Success") { Write-Host "  [!!] $name STATUS=$st (위 로그 확인)" }
}

# ③ → ④ → ⑤ → ⑥ → ⑦  (kafka 먼저: 나머지가 그 IP를 참조)
Run-Step "kafka+redis"  $ids.kafka      "$here\deploy\kafka.sh"      @{ "__KAFKA_IP__" = $ips.kafka } 600
Run-Step "monitoring"   $ids.monitoring "$here\deploy\monitoring.sh" @{ "__APP_IP__" = $ips.app; "__KAFKA_IP__" = $ips.kafka } 900
Run-Step "ai-server"    $ids.ai         "$here\deploy\ai.sh"         @{ "__RDS__" = $rds; "__RDS_PW_ENC__" = $pwEnc; "__KAFKA_IP__" = $ips.kafka; "__OPENAI__" = $openai; "__TAVILY__" = $tavily; "__LLM_MODEL__" = $llm; "__CF__" = $cf } 900
Run-Step "backend"      $ids.app        "$here\deploy\backend.sh"    @{ "__RDS__" = $rds; "__RDS_PW__" = $pw; "__KAFKA_IP__" = $ips.kafka; "__AI_IP__" = $ips.ai; "__CF__" = $cf; "__SECRET_B64__" = $secretB64 } 1500
Run-Step "frontend"     $ids.app        "$here\deploy\frontend.sh"   @{ "__BUCKET__" = $bucket; "__DISTID__" = $dist } 1200

Write-Host "`n=== 완료. 접속: $cf ==="
Write-Host "검증: curl $cf/  +  $cf/actuator/health"
