param(
  [ValidateSet("language", "revenue", "both")]
  [string]$Api = "both",
  [ValidateSet("json", "csv")]
  [string]$Format = "json",
  [string]$OutputPath = "",
  [string]$From = "",
  [string]$To = "",
  [string]$LanguageLedgerPath = "apps/api/artifacts/usage/language_api_usage.jsonl",
  [string]$RevenueLedgerPath = "apps/revenue_automation/artifacts/usage/revenue_api_usage.jsonl"
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Convert-ToUtcDate {
  param(
    [string]$Value,
    [string]$FieldName
  )

  if ([string]::IsNullOrWhiteSpace($Value)) { return $null }
  $dt = [datetime]::MinValue
  if (-not [datetime]::TryParse([string]$Value, [ref]$dt)) {
    throw "$FieldName must be ISO8601 parseable. Actual: $Value"
  }
  return $dt.ToUniversalTime()
}

function Read-LedgerRows {
  param(
    [Parameter(Mandatory = $true)][string]$LedgerPath,
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [datetime]$FromUtc,
    [datetime]$ToUtc
  )

  if (-not (Test-Path -Path $LedgerPath -PathType Leaf)) {
    return @()
  }

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($line in Get-Content -Path $LedgerPath -Encoding UTF8) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    $entry = $null
    try {
      $entry = $line | ConvertFrom-Json
    }
    catch {
      continue
    }

    $ts = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$entry.timestamp_utc, [ref]$ts)) {
      continue
    }
    $utcTs = $ts.ToUniversalTime()
    if ($null -ne $FromUtc -and $utcTs -lt $FromUtc) { continue }
    if ($null -ne $ToUtc -and $utcTs -gt $ToUtc) { continue }

    if (-not ($entry.PSObject.Properties.Name -contains "service") -or [string]::IsNullOrWhiteSpace([string]$entry.service)) {
      $entry | Add-Member -NotePropertyName service -NotePropertyValue $ServiceName -Force
    }

    [void]$rows.Add($entry)
  }

  return @($rows.ToArray())
}

$fromUtc = Convert-ToUtcDate -Value $From -FieldName "From"
$toUtc = Convert-ToUtcDate -Value $To -FieldName "To"
if ($null -ne $fromUtc -and $null -ne $toUtc -and $fromUtc -gt $toUtc) {
  throw "From must be less than or equal to To."
}

$allRows = New-Object System.Collections.Generic.List[object]
if ($Api -in @("language", "both")) {
  foreach ($row in @(Read-LedgerRows -LedgerPath $LanguageLedgerPath -ServiceName "language_api" -FromUtc $fromUtc -ToUtc $toUtc)) {
    [void]$allRows.Add($row)
  }
}
if ($Api -in @("revenue", "both")) {
  foreach ($row in @(Read-LedgerRows -LedgerPath $RevenueLedgerPath -ServiceName "marketing_revenue_api" -FromUtc $fromUtc -ToUtc $toUtc)) {
    [void]$allRows.Add($row)
  }
}

$orderedRows = @(
  $allRows.ToArray() |
    Sort-Object -Property @{ Expression = { [datetime]$_.timestamp_utc }; Descending = $false }, @{ Expression = "service"; Descending = $false }, @{ Expression = "request_id"; Descending = $false }
)

$outputObject = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  api = $Api
  format = $Format
  from_utc = if ($null -ne $fromUtc) { $fromUtc.ToString("o") } else { $null }
  to_utc = if ($null -ne $toUtc) { $toUtc.ToString("o") } else { $null }
  row_count = $orderedRows.Count
  rows = $orderedRows
}

if ($Format -eq "json") {
  $payload = $outputObject | ConvertTo-Json -Depth 20
}
else {
  $csvRows = @(
    $orderedRows | Select-Object timestamp_utc, service, request_id, key_id, endpoint, status_code, latency_ms, billable_units, request_bytes, response_bytes, idempotency_replay
  )
  $payload = ($csvRows | ConvertTo-Csv -NoTypeInformation) -join [Environment]::NewLine
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  Write-Output $payload
}
else {
  $outDir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $payload | Set-Content -Path $OutputPath -Encoding UTF8
  Write-Host "USAGE_EXPORT_WRITTEN=$OutputPath"
}

exit 0
