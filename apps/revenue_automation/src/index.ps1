param(
  [string]$ConfigPath = "",
  [string]$TaskPath = "",
  [string]$OutputPath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$appRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path

. (Join-Path $scriptRoot "lib\task_router.ps1")
. (Join-Path $scriptRoot "lib\telemetry.ps1")

function Read-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -Path $Path -PathType Leaf)) {
    throw "$Label not found: $Path"
  }

  try {
    return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
  }
  catch {
    throw "$Label is not valid JSON: $($_.Exception.Message)"
  }
}

function Parse-StrictBool {
  param(
    [object]$Value,
    [bool]$DefaultValue,
    [string]$FieldName
  )

  if ($null -eq $Value) { return $DefaultValue }
  if ($Value -is [bool]) { return [bool]$Value }

  $s = ([string]$Value).Trim().ToLowerInvariant()
  switch ($s) {
    "true" { return $true }
    "false" { return $false }
    default { throw "Config field '$FieldName' must be boolean true/false." }
  }
}

function Normalize-Config {
  param([Parameter(Mandatory = $true)][object]$RawConfig)

  $providerMode = "mock"
  if ($RawConfig.PSObject.Properties.Name -contains "provider_mode" -and -not [string]::IsNullOrWhiteSpace([string]$RawConfig.provider_mode)) {
    $providerMode = ([string]$RawConfig.provider_mode).Trim().ToLowerInvariant()
  }

  if ($providerMode -notin @("mock", "http")) {
    throw "Config field 'provider_mode' must be one of: mock|http."
  }

  return [pscustomobject]@{
    enable_revenue_automation = Parse-StrictBool -Value $RawConfig.enable_revenue_automation -DefaultValue $false -FieldName "enable_revenue_automation"
    provider_mode = $providerMode
    emit_telemetry = Parse-StrictBool -Value $RawConfig.emit_telemetry -DefaultValue $true -FieldName "emit_telemetry"
    safe_mode = Parse-StrictBool -Value $RawConfig.safe_mode -DefaultValue $true -FieldName "safe_mode"
    dry_run = Parse-StrictBool -Value $RawConfig.dry_run -DefaultValue $true -FieldName "dry_run"
  }
}

function Get-TaskValidationErrors {
  param([Parameter(Mandatory = $true)][object]$Task)

  $errors = New-Object System.Collections.Generic.List[string]
  $names = @($Task.PSObject.Properties.Name)

  if ($names -notcontains "task_id" -or [string]::IsNullOrWhiteSpace([string]$Task.task_id)) {
    [void]$errors.Add("task_id is required and must be a non-empty string.")
  }

  if ($names -notcontains "task_type" -or [string]::IsNullOrWhiteSpace([string]$Task.task_type)) {
    [void]$errors.Add("task_type is required and must be a non-empty string.")
  }

  if ($names -notcontains "payload") {
    [void]$errors.Add("payload is required and must be an object.")
  }
  else {
    $payload = $Task.payload
    $isObjectLike = ($payload -is [System.Collections.IDictionary]) -or ($payload -is [pscustomobject])
    if (-not $isObjectLike) {
      [void]$errors.Add("payload must be an object.")
    }
  }

  if ($names -notcontains "created_at_utc" -or [string]::IsNullOrWhiteSpace([string]$Task.created_at_utc)) {
    [void]$errors.Add("created_at_utc is required and must be ISO8601.")
  }
  else {
    $tmpDate = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Task.created_at_utc, [ref]$tmpDate)) {
      [void]$errors.Add("created_at_utc must be parseable as ISO8601 datetime.")
    }
  }

  return @($errors.ToArray())
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $appRoot "config.example.json"
}

try {
  $configRaw = Read-JsonFile -Path $ConfigPath -Label "Config"
  $config = Normalize-Config -RawConfig $configRaw
}
catch {
  Write-Error $_.Exception.Message
  exit 2
}

if (-not $config.enable_revenue_automation) {
  Write-Host "Revenue automation disabled (enable_revenue_automation=false). Exiting with no side effects."
  exit 0
}

if ([string]::IsNullOrWhiteSpace($TaskPath)) {
  Write-Error "TaskPath is required when enable_revenue_automation=true."
  exit 2
}

$task = $null
try {
  $task = Read-JsonFile -Path $TaskPath -Label "Task envelope"
}
catch {
  Write-Error $_.Exception.Message
  exit 2
}

$taskId = if ($task.PSObject.Properties.Name -contains "task_id") { [string]$task.task_id } else { "" }
$taskType = if ($task.PSObject.Properties.Name -contains "task_type") { [string]$task.task_type } else { "" }

$started = Get-Date
$startedUtc = $started.ToUniversalTime().ToString("o")

$routeResult = $null
$validationErrors = @(Get-TaskValidationErrors -Task $task)
if ($validationErrors.Count -gt 0) {
  $routeResult = [pscustomobject]@{
    status = "FAILED"
    provider_used = "none"
    error = ($validationErrors -join " ")
    artifacts = @()
  }
}
else {
  $routeResult = Invoke-RevenueTaskRoute -Task $task -Config $config
}

$finished = Get-Date
$finishedUtc = $finished.ToUniversalTime().ToString("o")
$durationMs = [int](($finished - $started).TotalMilliseconds)

$result = [pscustomobject]@{
  task_id = $taskId
  status = [string]$routeResult.status
  provider_used = [string]$routeResult.provider_used
  started_at_utc = $startedUtc
  finished_at_utc = $finishedUtc
  duration_ms = $durationMs
  error = if ([string]::IsNullOrWhiteSpace([string]$routeResult.error)) { $null } else { [string]$routeResult.error }
  artifacts = @($routeResult.artifacts | ForEach-Object { [string]$_ })
  reason_codes = if ($routeResult.PSObject.Properties.Name -contains "reason_codes") { @($routeResult.reason_codes | ForEach-Object { [string]$_ }) } else { @() }
  policy = if ($routeResult.PSObject.Properties.Name -contains "policy") { $routeResult.policy } else { $null }
  route = if ($routeResult.PSObject.Properties.Name -contains "route") { $routeResult.route } else { $null }
  offer = if ($routeResult.PSObject.Properties.Name -contains "offer") { $routeResult.offer } else { $null }
  proposal = if ($routeResult.PSObject.Properties.Name -contains "proposal") { $routeResult.proposal } else { $null }
}

if ($config.emit_telemetry) {
  $telemetryPath = Join-Path $appRoot "artifacts\telemetry\revenue_events.jsonl"
  Write-RevenueTelemetryEvent `
    -TelemetryPath $telemetryPath `
    -TaskId $result.task_id `
    -TaskType $taskType `
    -Status $result.status `
    -ProviderMode $config.provider_mode `
    -DurationMs $result.duration_ms
}

$json = $result | ConvertTo-Json -Depth 20 -Compress

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outDir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  Set-Content -Path $OutputPath -Value $json -Encoding UTF8
}

Write-Output $json

if ($result.status -eq "FAILED") { exit 1 }
exit 0
