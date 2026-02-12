param(
  [int]$TimeoutSec = 45,
  [int]$IntervalSec = 1,
  [int]$LanguagePort = 8081,
  [int]$RevenuePort = 8082,
  [int]$IntegrationLanguagePort = 18081,
  [int]$IntegrationRevenuePort = 18082,
  [string]$ApiKey = "dev-local-key",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\\..")).Path
$startScript = Join-Path $scriptDir "start_both_apis.ps1"
$stopScript = Join-Path $scriptDir "stop_both_apis.ps1"
$bothSmoke = Join-Path $repoRoot "tests\\both_apis.smoke.Tests.ps1"
$languageIntegration = Join-Path $repoRoot "tests\\integration\\language_api.http.Tests.ps1"
$revenueIntegration = Join-Path $repoRoot "tests\\integration\\revenue_api.http.Tests.ps1"

if (-not (Test-Path -Path $startScript -PathType Leaf)) { throw "Missing script: $startScript" }
if (-not (Test-Path -Path $stopScript -PathType Leaf)) { throw "Missing script: $stopScript" }
if (-not (Test-Path -Path $bothSmoke -PathType Leaf)) { throw "Missing smoke test: $bothSmoke" }
if (-not (Test-Path -Path $languageIntegration -PathType Leaf)) { throw "Missing integration test: $languageIntegration" }
if (-not (Test-Path -Path $revenueIntegration -PathType Leaf)) { throw "Missing integration test: $revenueIntegration" }

$smokeStatePath = Join-Path $scriptDir ".both_apis_state.smoke.json"
$integrationStatePath = Join-Path $scriptDir ".both_apis_state.integration.json"

$startExit = -1
$integrationStartExit = -1
$smokeExit = -1
$languageIntegrationExit = -1
$revenueIntegrationExit = -1
$stopExit = -1
$integrationStopExit = -1
$errorText = ""
$smokeCounts = $null
$languageCounts = $null
$revenueCounts = $null

function Get-PesterCount {
  param(
    [Parameter(Mandatory = $true)][object]$Result,
    [Parameter(Mandatory = $true)][string]$PropertyName
  )

  if ($Result.PSObject.Properties.Name -contains $PropertyName) {
    return [int]$Result.$PropertyName
  }

  if ($Result.PSObject.Properties.Name -contains "TestResult") {
    $matches = @($Result.TestResult | Where-Object { [string]$_.Result -eq ($PropertyName -replace "Count$", "") })
    return $matches.Count
  }

  return 0
}

function Invoke-PesterSuite {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Name
  )

  $result = Invoke-Pester $Path -PassThru
  if ($null -eq $result) {
    throw "$Name returned no result object."
  }

  $passed = Get-PesterCount -Result $result -PropertyName "PassedCount"
  $failed = Get-PesterCount -Result $result -PropertyName "FailedCount"
  $skipped = Get-PesterCount -Result $result -PropertyName "SkippedCount"

  return [pscustomobject]@{
    passed = $passed
    failed = $failed
    skipped = $skipped
  }
}

function Start-ApiPair {
  param(
    [int]$LangPort,
    [int]$RevPort,
    [string]$StatePath
  )

  & $startScript -TimeoutSec $TimeoutSec -IntervalSec $IntervalSec -LanguagePort $LangPort -RevenuePort $RevPort -ApiKey $ApiKey -StatePath $StatePath
  if ($null -eq $LASTEXITCODE) { return 0 }
  return [int]$LASTEXITCODE
}

function Stop-ApiPair {
  param([string]$StatePath)

  & $stopScript -StatePath $StatePath
  if ($null -eq $LASTEXITCODE) { return 0 }
  return [int]$LASTEXITCODE
}

try {
  $startExit = Start-ApiPair -LangPort $LanguagePort -RevPort $RevenuePort -StatePath $smokeStatePath
  if ($startExit -ne 0) { throw "start_both_apis.ps1 failed with exit code $startExit." }

  $env:LANGUAGE_API_BASE_URL = "http://127.0.0.1:$LanguagePort"
  $env:REVENUE_API_BASE_URL = "http://127.0.0.1:$RevenuePort"
  $env:SANCTUM_API_KEY = $ApiKey

  $smokeCounts = Invoke-PesterSuite -Path $bothSmoke -Name "both_apis.smoke.Tests.ps1"
  $smokeExit = if ($smokeCounts.failed -gt 0) { 1 } else { 0 }
  if ($smokeExit -ne 0) { throw ("both_apis.smoke.Tests.ps1 failed. Passed={0} Failed={1} Skipped={2}" -f $smokeCounts.passed, $smokeCounts.failed, $smokeCounts.skipped) }

  $stopExit = Stop-ApiPair -StatePath $smokeStatePath
  if ($stopExit -ne 0) { throw "stop_both_apis.ps1 failed with exit code $stopExit after smoke suite." }

  $integrationStartExit = Start-ApiPair -LangPort $IntegrationLanguagePort -RevPort $IntegrationRevenuePort -StatePath $integrationStatePath
  if ($integrationStartExit -ne 0) { throw "start_both_apis.ps1 failed with exit code $integrationStartExit for integration suite." }

  $env:LANGUAGE_API_BASE_URL = "http://127.0.0.1:$IntegrationLanguagePort"
  $env:REVENUE_API_BASE_URL = "http://127.0.0.1:$IntegrationRevenuePort"

  $languageCounts = Invoke-PesterSuite -Path $languageIntegration -Name "language_api.http.Tests.ps1"
  $languageIntegrationExit = if ($languageCounts.failed -gt 0) { 1 } else { 0 }
  if ($languageIntegrationExit -ne 0) { throw ("language_api.http.Tests.ps1 failed. Passed={0} Failed={1} Skipped={2}" -f $languageCounts.passed, $languageCounts.failed, $languageCounts.skipped) }

  $revenueCounts = Invoke-PesterSuite -Path $revenueIntegration -Name "revenue_api.http.Tests.ps1"
  $revenueIntegrationExit = if ($revenueCounts.failed -gt 0) { 1 } else { 0 }
  if ($revenueIntegrationExit -ne 0) { throw ("revenue_api.http.Tests.ps1 failed. Passed={0} Failed={1} Skipped={2}" -f $revenueCounts.passed, $revenueCounts.failed, $revenueCounts.skipped) }
}
catch {
  $errorText = [string]$_.Exception.Message
}
finally {
  if ($stopExit -lt 0) {
    $stopExit = Stop-ApiPair -StatePath $smokeStatePath
  }
  $integrationStopExit = Stop-ApiPair -StatePath $integrationStatePath

  Remove-Item Env:LANGUAGE_API_BASE_URL -ErrorAction SilentlyContinue
  Remove-Item Env:REVENUE_API_BASE_URL -ErrorAction SilentlyContinue
  Remove-Item Env:SANCTUM_API_KEY -ErrorAction SilentlyContinue
}

$summary = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  language_api_base_url = "http://127.0.0.1:$LanguagePort"
  revenue_api_base_url = "http://127.0.0.1:$RevenuePort"
  integration_language_api_base_url = "http://127.0.0.1:$IntegrationLanguagePort"
  integration_revenue_api_base_url = "http://127.0.0.1:$IntegrationRevenuePort"
  start_exit = $startExit
  integration_start_exit = $integrationStartExit
  smoke_exit = $smokeExit
  smoke_passed = if ($null -ne $smokeCounts) { [int]$smokeCounts.passed } else { 0 }
  smoke_failed = if ($null -ne $smokeCounts) { [int]$smokeCounts.failed } else { 0 }
  smoke_skipped = if ($null -ne $smokeCounts) { [int]$smokeCounts.skipped } else { 0 }
  language_integration_exit = $languageIntegrationExit
  language_integration_passed = if ($null -ne $languageCounts) { [int]$languageCounts.passed } else { 0 }
  language_integration_failed = if ($null -ne $languageCounts) { [int]$languageCounts.failed } else { 0 }
  language_integration_skipped = if ($null -ne $languageCounts) { [int]$languageCounts.skipped } else { 0 }
  revenue_integration_exit = $revenueIntegrationExit
  revenue_integration_passed = if ($null -ne $revenueCounts) { [int]$revenueCounts.passed } else { 0 }
  revenue_integration_failed = if ($null -ne $revenueCounts) { [int]$revenueCounts.failed } else { 0 }
  revenue_integration_skipped = if ($null -ne $revenueCounts) { [int]$revenueCounts.skipped } else { 0 }
  stop_exit = $stopExit
  integration_stop_exit = $integrationStopExit
  error = $errorText
  verdict = if ([string]::IsNullOrWhiteSpace($errorText) -and $startExit -eq 0 -and $integrationStartExit -eq 0 -and $smokeExit -eq 0 -and $languageIntegrationExit -eq 0 -and $revenueIntegrationExit -eq 0 -and $stopExit -eq 0 -and $integrationStopExit -eq 0) { "PASS" } else { "FAIL" }
}

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outDir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $summary | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputPath -Encoding UTF8
}

Write-Output ($summary | ConvertTo-Json -Depth 20 -Compress)
if ($summary.verdict -ne "PASS") { exit 1 }
exit 0
