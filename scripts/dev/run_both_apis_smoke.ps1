param(
  [int]$TimeoutSec = 30,
  [int]$IntervalSec = 1,
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\\..")).Path
$startScript = Join-Path $scriptDir "start_both_apis.ps1"
$stopScript = Join-Path $scriptDir "stop_both_apis.ps1"
$smokeTest = Join-Path $repoRoot "tests\\both_apis.smoke.Tests.ps1"

if (-not (Test-Path -Path $startScript -PathType Leaf)) { throw "Missing script: $startScript" }
if (-not (Test-Path -Path $stopScript -PathType Leaf)) { throw "Missing script: $stopScript" }
if (-not (Test-Path -Path $smokeTest -PathType Leaf)) { throw "Missing smoke test: $smokeTest" }

$startExit = $null
$smokeExit = $null
$stopExit = $null
$errorText = ""

try {
  & $startScript -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec
  $startExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if ($startExit -ne 0) { throw "start_both_apis.ps1 failed with exit code $startExit." }

  Invoke-Pester $smokeTest -EnableExit
  $smokeExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  if ($smokeExit -ne 0) { throw "both_apis.smoke.Tests.ps1 failed with exit code $smokeExit." }
}
catch {
  if ($null -eq $startExit) { $startExit = -1 }
  if ($null -eq $smokeExit) { $smokeExit = -1 }
  $errorText = [string]$_.Exception.Message
}
finally {
  & $stopScript
  $stopExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
}

$summary = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  start_exit = $startExit
  smoke_exit = $smokeExit
  stop_exit = $stopExit
  error = $errorText
  verdict = if ([string]::IsNullOrWhiteSpace($errorText) -and $startExit -eq 0 -and $smokeExit -eq 0 -and $stopExit -eq 0) { "PASS" } else { "FAIL" }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outDir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $summary | ConvertTo-Json -Depth 10 | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Output ($summary | ConvertTo-Json -Depth 10 -Compress)
if ($summary.verdict -ne "PASS") { exit 1 }
exit 0
