Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-RevenueTelemetryEvent {
  param(
    [Parameter(Mandatory = $true)][string]$TelemetryPath,
    [Parameter(Mandatory = $true)][string]$TaskId,
    [Parameter(Mandatory = $true)][string]$TaskType,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$ProviderMode,
    [Parameter(Mandatory = $true)][int]$DurationMs
  )

  try {
    $dir = Split-Path -Parent $TelemetryPath
    if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -Path $dir -PathType Container)) {
      New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $event = [pscustomobject]@{
      ts_utc = (Get-Date).ToUniversalTime().ToString("o")
      task_id = $TaskId
      task_type = $TaskType
      status = $Status
      provider_mode = $ProviderMode
      duration_ms = $DurationMs
    }

    $line = $event | ConvertTo-Json -Compress
    Add-Content -Path $TelemetryPath -Value $line -Encoding UTF8
  }
  catch {
    Write-Warning "Revenue telemetry write failed: $($_.Exception.Message)"
  }
}
