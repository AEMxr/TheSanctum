param(
  [string]$ConfigPath = "",
  [string]$FixturesDir = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$appRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
$indexPath = Join-Path $appRoot "src\index.ps1"

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $appRoot "config.example.json"
}
if ([string]::IsNullOrWhiteSpace($FixturesDir)) {
  $FixturesDir = Join-Path $appRoot "fixtures"
}
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $appRoot "artifacts\replay\replay_summary.json"
}

if (-not (Test-Path -Path $indexPath -PathType Leaf)) {
  Write-Error "Entrypoint not found: $indexPath"
  exit 2
}
if (-not (Test-Path -Path $ConfigPath -PathType Leaf)) {
  Write-Error "Config not found: $ConfigPath"
  exit 2
}
if (-not (Test-Path -Path $FixturesDir -PathType Container)) {
  Write-Error "Fixtures directory not found: $FixturesDir"
  exit 2
}

function Read-JsonFile {
  param([Parameter(Mandatory = $true)][string]$Path)
  return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
}

function Parse-StrictBool {
  param([object]$Value, [bool]$DefaultValue)

  if ($null -eq $Value) { return $DefaultValue }
  if ($Value -is [bool]) { return [bool]$Value }

  $s = ([string]$Value).Trim().ToLowerInvariant()
  switch ($s) {
    "true" { return $true }
    "false" { return $false }
    default { throw "Boolean value expected, got '$Value'" }
  }
}

function Test-OutputContract {
  param([object]$Result)

  if ($null -eq $Result) { return $false }

  $required = @(
    "task_id",
    "status",
    "provider_used",
    "started_at_utc",
    "finished_at_utc",
    "duration_ms",
    "error",
    "artifacts"
  )

  foreach ($name in $required) {
    if (-not ($Result.PSObject.Properties.Name -contains $name)) {
      return $false
    }
  }

  if ([string]::IsNullOrWhiteSpace([string]$Result.task_id)) { return $false }
  if (([string]$Result.status) -notin @("SUCCESS", "FAILED", "SKIPPED")) { return $false }

  $tmpDuration = 0
  if (-not [int]::TryParse([string]$Result.duration_ms, [ref]$tmpDuration)) { return $false }
  if ($tmpDuration -lt 0) { return $false }

  return $true
}

function Get-ExpectedOutcome {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][string]$ProviderMode
  )

  $expectedStatus = ""
  if ($Task.PSObject.Properties.Name -contains "expected_status" -and -not [string]::IsNullOrWhiteSpace([string]$Task.expected_status)) {
    $expectedStatus = ([string]$Task.expected_status).Trim().ToUpperInvariant()
  }

  if ([string]::IsNullOrWhiteSpace($expectedStatus)) {
    $known = @("lead_enrich", "followup_draft", "calendar_proposal")
    $taskType = [string]$Task.task_type
    if ($known -notcontains $taskType) {
      $expectedStatus = "SKIPPED"
    }
    elseif ($ProviderMode -eq "http") {
      $expectedStatus = "SKIPPED"
    }
    else {
      $expectedStatus = "SUCCESS"
    }
  }

  if ($expectedStatus -notin @("SUCCESS", "FAILED", "SKIPPED")) {
    throw "Fixture expected_status must be one of SUCCESS|FAILED|SKIPPED (task_id=$($Task.task_id), got '$expectedStatus')"
  }

  $expectedExitCode = if ($expectedStatus -eq "FAILED") { 1 } else { 0 }
  if ($Task.PSObject.Properties.Name -contains "expected_exit_code") {
    $tmpExpected = 0
    if (-not [int]::TryParse([string]$Task.expected_exit_code, [ref]$tmpExpected)) {
      throw "Fixture expected_exit_code must be integer-like (task_id=$($Task.task_id), got '$($Task.expected_exit_code)')"
    }
    $expectedExitCode = $tmpExpected
  }

  return [pscustomobject]@{
    status = $expectedStatus
    exit_code = $expectedExitCode
  }
}

try {
  $configRaw = Read-JsonFile -Path $ConfigPath
}
catch {
  Write-Error "Unable to parse config JSON at ${ConfigPath}: $($_.Exception.Message)"
  exit 2
}

$providerMode = "mock"
if ($configRaw.PSObject.Properties.Name -contains "provider_mode" -and -not [string]::IsNullOrWhiteSpace([string]$configRaw.provider_mode)) {
  $providerMode = ([string]$configRaw.provider_mode).Trim().ToLowerInvariant()
}
if ($providerMode -notin @("mock", "http")) {
  Write-Warning "Unsupported provider_mode '$providerMode' in config; defaulting to mock."
  $providerMode = "mock"
}

$emitTelemetry = $true
if ($configRaw.PSObject.Properties.Name -contains "emit_telemetry") {
  $emitTelemetry = Parse-StrictBool -Value $configRaw.emit_telemetry -DefaultValue $true
}

$runtimeConfig = [pscustomobject]@{
  enable_revenue_automation = $true
  provider_mode = $providerMode
  emit_telemetry = $emitTelemetry
  safe_mode = $true
  dry_run = $true
}

if (-not $runtimeConfig.safe_mode -or -not $runtimeConfig.dry_run) {
  Write-Error "Replay runner requires safe_mode=true and dry_run=true."
  exit 2
}

$outputDir = Split-Path -Parent $OutputPath
if (-not [string]::IsNullOrWhiteSpace($outputDir) -and -not (Test-Path -Path $outputDir -PathType Container)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}
$runtimeConfigPath = Join-Path $outputDir "replay_runtime_config.json"
$runtimeConfig | ConvertTo-Json -Depth 20 | Set-Content -Path $runtimeConfigPath -Encoding UTF8

$powerShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
$fixtures = @(Get-ChildItem -Path $FixturesDir -Filter *.json -File | Sort-Object Name)
if ($fixtures.Count -eq 0) {
  Write-Error "No fixture JSON files found in $FixturesDir"
  exit 2
}

$results = New-Object System.Collections.Generic.List[object]

foreach ($fixture in $fixtures) {
  $fixtureTask = $null
  try {
    $fixtureTask = Read-JsonFile -Path $fixture.FullName
  }
  catch {
    [void]$results.Add([pscustomobject]@{
      fixture = $fixture.Name
      expected_status = "UNKNOWN"
      actual_status = "FAILED"
      expected_exit_code = -1
      exit_code = -1
      contract_ok = $false
      pass = $false
      message = "Fixture JSON parse failed: $($_.Exception.Message)"
    })
    continue
  }

  $expected = $null
  try {
    $expected = Get-ExpectedOutcome -Task $fixtureTask -ProviderMode $providerMode
  }
  catch {
    [void]$results.Add([pscustomobject]@{
      fixture = $fixture.Name
      expected_status = "UNKNOWN"
      actual_status = "FAILED"
      expected_exit_code = -1
      exit_code = -1
      contract_ok = $false
      pass = $false
      message = $_.Exception.Message
    })
    continue
  }

  $outputLines = @(& $powerShellExe -NoProfile -ExecutionPolicy Bypass -File $indexPath -ConfigPath $runtimeConfigPath -TaskPath $fixture.FullName 2>&1)
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  $jsonLine = @($outputLines | ForEach-Object { [string]$_ } | Where-Object { $_.Trim().StartsWith("{") -and $_.Trim().EndsWith("}") } | Select-Object -Last 1)

  $resultObj = $null
  if ($jsonLine.Count -gt 0) {
    try {
      $resultObj = ($jsonLine[0] | ConvertFrom-Json)
    }
    catch {
      $resultObj = $null
    }
  }

  $contractOk = Test-OutputContract -Result $resultObj
  $actualStatus = if ($null -ne $resultObj) { [string]$resultObj.status } else { "" }
  $statusMatch = ($actualStatus -eq [string]$expected.status)
  $exitMatch = ($exitCode -eq [int]$expected.exit_code)
  $passed = ($contractOk -and $statusMatch -and $exitMatch)

  $messageParts = New-Object System.Collections.Generic.List[string]
  if (-not $contractOk) { [void]$messageParts.Add("contract_check_failed") }
  if (-not $statusMatch) { [void]$messageParts.Add("status_mismatch(expected=$([string]$expected.status) actual=$actualStatus)") }
  if (-not $exitMatch) { [void]$messageParts.Add("exit_code_mismatch(expected=$([int]$expected.exit_code) actual=$exitCode)") }
  $message = if ($messageParts.Count -eq 0) { "ok" } else { ($messageParts -join ";") }

  [void]$results.Add([pscustomobject]@{
    fixture = $fixture.Name
    expected_status = [string]$expected.status
    actual_status = $actualStatus
    expected_exit_code = [int]$expected.exit_code
    exit_code = $exitCode
    contract_ok = $contractOk
    pass = $passed
    message = $message
  })
}

$resultArray = @($results.ToArray())
$failedCount = @($resultArray | Where-Object { -not [bool]$_.pass }).Count
$passedCount = @($resultArray | Where-Object { [bool]$_.pass }).Count

$summary = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  config_path = (Resolve-Path -LiteralPath $ConfigPath).Path
  runtime_config_path = $runtimeConfigPath
  fixtures_dir = (Resolve-Path -LiteralPath $FixturesDir).Path
  provider_mode = $providerMode
  safe_mode = $runtimeConfig.safe_mode
  dry_run = $runtimeConfig.dry_run
  total = $resultArray.Count
  passed = $passedCount
  failed = $failedCount
  results = $resultArray
}

$summary | ConvertTo-Json -Depth 30 | Set-Content -Path $OutputPath -Encoding UTF8
$resultArray | Format-Table fixture, expected_status, actual_status, expected_exit_code, exit_code, contract_ok, pass -AutoSize | Out-String | Write-Host
Write-Host "Replay summary written to: $OutputPath"

if ($failedCount -gt 0) {
  Write-Error "Fixture replay failed for $failedCount fixture(s)."
  exit 1
}

exit 0
