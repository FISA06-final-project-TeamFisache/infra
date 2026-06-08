# SSM RunShellScript 헬퍼: 인스턴스에 셸 스크립트를 보내고 완료까지 대기 후 출력 표시.
# 사용: . .\ssm-run.ps1 ; Invoke-SSM -InstanceId i-xxxx -Script "echo hi"
function Invoke-SSM {
  param(
    [Parameter(Mandatory)][string]$InstanceId,
    [Parameter(Mandatory)][string]$Script,
    [int]$TimeoutSec = 900
  )
  $here = $PSScriptRoot
  $env:PATH = "$here;$here\.venv\Scripts;$env:PATH"
  $env:PYTHONIOENCODING = "utf-8"   # aws CLI 출력의 유니코드(✓ 등) cp949 인코딩 에러 방지

  # 파라미터 JSON (BOM 없이 작성 — aws CLI가 BOM이면 파싱 실패)
  $paramsFile = Join-Path $env:TEMP ("ssm-" + [guid]::NewGuid().ToString('N') + ".json")
  $json = @{ commands = @($Script) } | ConvertTo-Json -Compress
  [System.IO.File]::WriteAllText($paramsFile, $json, (New-Object System.Text.UTF8Encoding($false)))

  $cmdId = aws ssm send-command --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" --comment "phase3" `
    --parameters "file://$paramsFile" --query "Command.CommandId" --output text
  Remove-Item $paramsFile -Force -ErrorAction SilentlyContinue
  Write-Host "[$InstanceId] command-id: $cmdId"

  # 상태만 작게 폴링 (전체 JSON을 ConvertFrom-Json 하면 큰 출력에서 깨짐 → --query 사용)
  $deadline = (Get-Date).AddSeconds($TimeoutSec)
  $status = "Pending"
  do {
    Start-Sleep -Seconds 5
    $status = (aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId --query "Status" --output text 2>$null)
    if (-not $status) { $status = "Pending" }
  } while ($status -in @('Pending', 'InProgress', 'Delayed') -and (Get-Date) -lt $deadline)

  Write-Host "[$InstanceId] STATUS: $status"
  Write-Host "----- STDOUT -----"
  # Out-Host 로 출력 → 함수 반환값($status)에 섞이지 않게 (안 그러면 호출부에서 STATUS 오탐)
  (aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId --query "StandardOutputContent" --output text) | Out-Host
  $err = aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId --query "StandardErrorContent" --output text
  if ($err) { Write-Host "----- STDERR -----"; Write-Host $err }
  return $status
}
