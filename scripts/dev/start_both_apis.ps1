param(
  [int]$TimeoutSec = 45,
  [int]$IntervalSec = 1,
  [int]$LanguagePort = 8081,
  [int]$RevenuePort = 8082,
  [string]$ApiKey = "dev-local-key",
  [string]$StatePath = "",
  [switch]$ForcePortReclaim = $true
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\\..")).Path
$waitScriptPath = Join-Path $scriptDir "wait_for_health.ps1"
$apiScriptPath = Join-Path $repoRoot "apps\\api\\src\\index.ps1"
$revenueScriptPath = Join-Path $repoRoot "apps\\revenue_automation\\src\\index.ps1"
$languageConfigExample = Join-Path $repoRoot "apps\\api\\config.example.json"
$revenueConfigExample = Join-Path $repoRoot "apps\\revenue_automation\\config.example.json"
$runtimeDir = Join-Path $repoRoot "artifacts\\runtime"

if (-not (Test-Path -Path $waitScriptPath -PathType Leaf)) { throw "Missing dependency script: $waitScriptPath" }
if (-not (Test-Path -Path $apiScriptPath -PathType Leaf)) { throw "Missing language API script: $apiScriptPath" }
if (-not (Test-Path -Path $revenueScriptPath -PathType Leaf)) { throw "Missing revenue API script: $revenueScriptPath" }
if (-not (Test-Path -Path $languageConfigExample -PathType Leaf)) { throw "Missing language config example: $languageConfigExample" }
if (-not (Test-Path -Path $revenueConfigExample -PathType Leaf)) { throw "Missing revenue config example: $revenueConfigExample" }

if (-not (Test-Path -Path $runtimeDir -PathType Container)) {
  New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
}

if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $scriptDir ".both_apis_state.json"
}

function Stop-PortListeners {
  param([int]$Port)

  if ($Port -le 0) { return }

  $listeners = @()
  try {
    $listeners = @(Get-NetTCPConnection -State Listen -LocalPort $Port -ErrorAction SilentlyContinue)
  }
  catch {
    $listeners = @()
  }

  foreach ($entry in @($listeners | Select-Object -ExpandProperty OwningProcess -Unique)) {
    if ($entry -eq $PID) { continue }
    try {
      Stop-Process -Id $entry -Force -ErrorAction SilentlyContinue
      Write-Host "RECLAIMED_PORT=$Port PID=$entry"
    }
    catch {
      # best effort
    }
  }
}

if ($ForcePortReclaim) {
  Stop-PortListeners -Port $LanguagePort
  Stop-PortListeners -Port $RevenuePort
}

$languageConfig = Get-Content -Path $languageConfigExample -Raw -Encoding UTF8 | ConvertFrom-Json
if ($null -eq $languageConfig.http) { $languageConfig | Add-Member -NotePropertyName http -NotePropertyValue ([pscustomobject]@{}) -Force }
$languageConfig.http.host = "127.0.0.1"
$languageConfig.http.port = $LanguagePort
$languageConfig.http.api_keys = @([pscustomobject]@{ key_id = "dev-local"; key = $ApiKey; role = "admin" })
$languageConfig.http.usage_ledger_path = "apps/api/artifacts/usage/language_api_usage.jsonl"

$revenueConfig = Get-Content -Path $revenueConfigExample -Raw -Encoding UTF8 | ConvertFrom-Json
$revenueConfig.enable_revenue_automation = $true
$revenueConfig.provider_mode = "mock"
$revenueConfig.safe_mode = $true
$revenueConfig.dry_run = $true
if ($null -eq $revenueConfig.http) { $revenueConfig | Add-Member -NotePropertyName http -NotePropertyValue ([pscustomobject]@{}) -Force }
$revenueConfig.http.host = "127.0.0.1"
$revenueConfig.http.port = $RevenuePort
$revenueConfig.http.api_keys = @([pscustomobject]@{ key_id = "dev-local"; key = $ApiKey; role = "admin" })
$revenueConfig.http.usage_ledger_path = "apps/revenue_automation/artifacts/usage/revenue_api_usage.jsonl"

$languageRuntimeConfigPath = Join-Path $runtimeDir "language_api.runtime.json"
$revenueRuntimeConfigPath = Join-Path $runtimeDir "revenue_api.runtime.json"
$languageConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $languageRuntimeConfigPath -Encoding UTF8
$revenueConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $revenueRuntimeConfigPath -Encoding UTF8

$shellPath = (Get-Process -Id $PID).Path

$languageArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $apiScriptPath,
  "-Serve",
  "-ConfigPath", $languageRuntimeConfigPath
)
$revenueArgs = @(
  "-NoProfile",
  "-ExecutionPolicy", "Bypass",
  "-File", $revenueScriptPath,
  "-Serve",
  "-ConfigPath", $revenueRuntimeConfigPath
)

$languageProc = $null
$revenueProc = $null
try {
  $languageProc = Start-Process -FilePath $shellPath -ArgumentList $languageArgs -PassThru -WindowStyle Hidden
  $revenueProc = Start-Process -FilePath $shellPath -ArgumentList $revenueArgs -PassThru -WindowStyle Hidden

  & $waitScriptPath -Name "language_api" -Url ("http://127.0.0.1:{0}/ready" -f $LanguagePort) -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec -RequireReady
  if ($LASTEXITCODE -ne 0) { throw "Language API failed readiness check." }

  & $waitScriptPath -Name "revenue_automation" -Url ("http://127.0.0.1:{0}/ready" -f $RevenuePort) -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec -RequireReady
  if ($LASTEXITCODE -ne 0) { throw "Revenue API failed readiness check." }
}
catch {
  if ($null -ne $languageProc -and -not $languageProc.HasExited) { Stop-Process -Id $languageProc.Id -Force -ErrorAction SilentlyContinue }
  if ($null -ne $revenueProc -and -not $revenueProc.HasExited) { Stop-Process -Id $revenueProc.Id -Force -ErrorAction SilentlyContinue }
  throw
}

$stateDir = Split-Path -Parent $StatePath
if (-not [string]::IsNullOrWhiteSpace($stateDir) -and -not (Test-Path -Path $stateDir -PathType Container)) {
  New-Item -ItemType Directory -Path $stateDir -Force | Out-Null
}

$state = [pscustomobject]@{
  started_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  ready = $true
  language_api = [pscustomobject]@{
    pid = $languageProc.Id
    base_url = "http://127.0.0.1:$LanguagePort"
    config_path = $languageRuntimeConfigPath
  }
  revenue_api = [pscustomobject]@{
    pid = $revenueProc.Id
    base_url = "http://127.0.0.1:$RevenuePort"
    config_path = $revenueRuntimeConfigPath
  }
  api_key = $ApiKey
}
$state | ConvertTo-Json -Depth 20 | Set-Content -Path $StatePath -Encoding UTF8

Write-Host "BOTH_APIS_READY=true"
Write-Host "STATE_PATH=$StatePath"
Write-Host "LANGUAGE_API_BASE_URL=http://127.0.0.1:$LanguagePort"
Write-Host "REVENUE_API_BASE_URL=http://127.0.0.1:$RevenuePort"
exit 0
