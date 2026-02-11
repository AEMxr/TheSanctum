param(
  [int]$TimeoutSec = 30,
  [int]$IntervalSec = 1,
  [string]$StatePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\\..")).Path
$waitScriptPath = Join-Path $scriptDir "wait_for_health.ps1"
$apiScriptPath = Join-Path $repoRoot "apps\\api\\src\\index.ps1"
$revenueScriptPath = Join-Path $repoRoot "apps\\revenue_automation\\src\\index.ps1"

if (-not (Test-Path -Path $waitScriptPath -PathType Leaf)) {
  Write-Error "Missing dependency script: $waitScriptPath"
  exit 2
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $scriptDir ".both_apis_state.json"
}

& $waitScriptPath -Name "language_api" -ScriptPath $apiScriptPath -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec
if ($LASTEXITCODE -ne 0) { exit [int]$LASTEXITCODE }

& $waitScriptPath -Name "revenue_automation" -ScriptPath $revenueScriptPath -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec
if ($LASTEXITCODE -ne 0) { exit [int]$LASTEXITCODE }

$stateDir = Split-Path -Parent $StatePath
if (-not [string]::IsNullOrWhiteSpace($stateDir) -and -not (Test-Path -Path $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$state = [pscustomobject]@{
  started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  ready = $true
  services = @(
    [pscustomobject]@{ name = "language_api"; script_path = $apiScriptPath; status = "ok" },
    [pscustomobject]@{ name = "revenue_automation"; script_path = $revenueScriptPath; status = "ok" }
  )
}
$state | ConvertTo-Json -Depth 10 | Set-Content -Path $StatePath -Encoding UTF8

Write-Host "BOTH_APIS_READY=true"
Write-Host "STATE_PATH=$StatePath"
exit 0
