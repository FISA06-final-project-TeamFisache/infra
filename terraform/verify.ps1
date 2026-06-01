#requires -Version 5.1
<#
.SYNOPSIS
  Terraform으로 올린 AWS 인프라 연결 검증 (컨테이너 없이 가능한 범위).

.DESCRIPTION
  기본: 도구/자격증명 → terraform output → SSM 등록(Online) 확인 (= 핵심 2단계).
        4대 모두 Online이면 NAT·IAM·라우팅·SSM이 정상이라는 뜻.
  -Deep: 추가로 각 EC2의 아웃바운드(NAT) + 인스턴스 간 내부 통신(ping)까지 확인.

.EXAMPLE
  ./verify.ps1
  ./verify.ps1 -Deep -WaitMinutes 5
#>
[CmdletBinding()]
param(
  [int]$WaitMinutes = 3,   # SSM Online 대기 최대 시간(부팅 후 등록까지 1~2분 소요)
  [switch]$Deep            # NAT 아웃바운드 + 내부 통신까지 확인
)

$ErrorActionPreference = 'Stop'

function Section($t) { Write-Host "`n=== $t ===" -ForegroundColor Cyan }
function Ok($m)   { Write-Host "[ OK ] $m" -ForegroundColor Green }
function Fail($m) { Write-Host "[FAIL] $m" -ForegroundColor Red }
function Info($m) { Write-Host "[ .. ] $m" -ForegroundColor Yellow }

# SSM RunShellScript 원격 실행 헬퍼 (결과 객체 반환, 실패시 $null)
function Invoke-Ssm($InstanceId, $ShellCmd) {
  $tmp = New-TemporaryFile
  try {
    (@{ commands = @($ShellCmd) } | ConvertTo-Json -Compress) | Set-Content -Path $tmp -Encoding ascii
    $cid = aws ssm send-command --instance-ids $InstanceId `
      --document-name AWS-RunShellScript --parameters "file://$tmp" `
      --query "Command.CommandId" --output text
    if (-not $cid) { return $null }
    for ($n = 0; $n -lt 20; $n++) {
      Start-Sleep -Seconds 3
      try {
        $inv = aws ssm get-command-invocation --command-id $cid --instance-id $InstanceId --output json | ConvertFrom-Json
      } catch { continue }
      if ($inv.Status -in 'Success', 'Failed', 'Cancelled', 'TimedOut') { return $inv }
    }
    return $null
  } finally { Remove-Item $tmp -ErrorAction SilentlyContinue }
}

#############################################
# 0. 사전 확인 (도구 + 자격증명)
#############################################
Section "사전 확인"
foreach ($t in 'aws', 'terraform') {
  if (-not (Get-Command $t -ErrorAction SilentlyContinue)) { Fail "$t 미설치"; exit 1 }
}
Ok "aws / terraform 설치 확인"

try {
  $who = aws sts get-caller-identity --output json | ConvertFrom-Json
  Ok "AWS 자격증명 OK (계정 $($who.Account))"
} catch { Fail "AWS 자격증명 실패 — 'aws configure' 확인"; exit 1 }

#############################################
# 1. Terraform output 읽기
#############################################
Section "Terraform 출력 읽기"
Push-Location $PSScriptRoot
try { $tf = terraform output -json | ConvertFrom-Json }
catch { Fail "terraform output 실패 — apply 했는지 확인"; Pop-Location; exit 1 }
Pop-Location

if (-not $tf.instance_ids) { Fail "instance_ids 출력 없음 — apply 확인"; exit 1 }

$instances = [ordered]@{}
foreach ($p in $tf.instance_ids.value.PSObject.Properties) { $instances[$p.Name] = $p.Value }
# 배치는 enable_batch=true 일 때만
if ($tf.PSObject.Properties.Name -contains 'batch_instance_id' -and $tf.batch_instance_id.value) {
  $instances['batch'] = $tf.batch_instance_id.value
}

$privIps = @{}
if ($tf.instance_private_ips) {
  foreach ($p in $tf.instance_private_ips.value.PSObject.Properties) { $privIps[$p.Name] = $p.Value }
}
$natIp = if ($tf.nat_public_ip) { $tf.nat_public_ip.value } else { $null }

Ok "인스턴스 $($instances.Count)대 / NAT IP: $natIp"

#############################################
# 2. SSM Online 확인 (핵심) — 최대 WaitMinutes 폴링
#############################################
Section "SSM 등록 상태 (핵심 2단계)"
$deadline = (Get-Date).AddMinutes($WaitMinutes)
$online = @{}
do {
  try {
    $raw = aws ssm describe-instance-information `
      --query "InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}" --output json | ConvertFrom-Json
  } catch { $raw = @() }
  $online = @{}
  foreach ($i in @($raw)) { if ($i) { $online[$i.Id] = $i.Ping } }

  $pending = @($instances.GetEnumerator() | Where-Object { $online[$_.Value] -ne 'Online' })
  if ($pending.Count -eq 0) { break }
  if ((Get-Date) -ge $deadline) { break }
  Info "$($pending.Count)대 아직 미등록... 15초 후 재확인 (남은 대기 $([int]($deadline - (Get-Date)).TotalSeconds)s)"
  Start-Sleep -Seconds 15
} while ($true)

$results = foreach ($kv in $instances.GetEnumerator()) {
  [pscustomobject]@{
    Name       = $kv.Key
    InstanceId = $kv.Value
    PrivateIP  = $privIps[$kv.Key]
    SSM        = if ($online[$kv.Value] -eq 'Online') { 'Online' } else { 'OFFLINE' }
  }
}
$results | Format-Table -AutoSize | Out-Host

$allOnline = -not ($results | Where-Object { $_.SSM -ne 'Online' })
if ($allOnline) { Ok "전체 SSM Online — NAT/IAM/라우팅/SSM 정상" }
else {
  Fail "일부 OFFLINE — 부팅 직후면 -WaitMinutes 늘려 재시도. 계속되면 NAT 라우트/IAM 역할 확인"
  exit 1
}

#############################################
# 3~4. (옵션) NAT 아웃바운드 + 내부 통신
#############################################
if ($Deep) {
  Section "NAT 아웃바운드 확인 (각 EC2 → 인터넷)"
  foreach ($kv in $instances.GetEnumerator()) {
    $inv = Invoke-Ssm $kv.Value "curl -s --max-time 10 https://ifconfig.me"
    $seen = if ($inv) { $inv.StandardOutputContent.Trim() } else { $null }
    if ($seen -and $natIp -and $seen -eq $natIp) { Ok "$($kv.Key): 외부 IP $seen (= NAT IP, 정상)" }
    elseif ($seen) { Info "$($kv.Key): 외부 IP $seen (NAT IP $natIp 와 다름 — 확인)" }
    else { Fail "$($kv.Key): 아웃바운드 실패 (NAT 경로 확인)" }
  }

  Section "내부 통신 확인 (app → 나머지, ping)"
  $src = $instances['app']
  if (-not $src) { Info "app 인스턴스 없음 — 내부 통신 확인 생략" }
  else {
    foreach ($kv in $instances.GetEnumerator()) {
      if ($kv.Key -eq 'app') { continue }
      $target = $privIps[$kv.Key]
      if (-not $target) { continue }
      $inv = Invoke-Ssm $src "ping -c 2 -W 2 $target >/dev/null 2>&1 && echo REACHABLE || echo UNREACHABLE"
      $out = if ($inv) { $inv.StandardOutputContent.Trim() } else { 'NO_RESULT' }
      if ($out -eq 'REACHABLE') { Ok "app → $($kv.Key) ($target) 도달" }
      else { Fail "app → $($kv.Key) ($target) 도달 실패 (internal SG 확인)" }
    }
  }
}

Section "완료"
Ok "검증 끝. (서비스/포트 확인은 컨테이너 배포 후 -Deep 또는 수동 확인)"
exit 0
