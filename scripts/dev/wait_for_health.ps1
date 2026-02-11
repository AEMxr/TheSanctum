param(
  [Parameter(Mandatory = $true)][string]$ScriptPath,
  [string]$Name = "api",
  [int]$TimeoutSec = 30,
  [int]$IntervalSec = 1
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($TimeoutSec -lt 1) { throw "TimeoutSec must be >= 1." }
if ($IntervalSec -lt 1) { throw "IntervalSec must be >= 1." }

if (-not (Test-Path -Path $ScriptPath -PathType Leaf)) {
  Write-Error "Health target script not found: $ScriptPath"
  exit 2
}

$resolvedScriptPath = (Resolve-Path -Path $ScriptPath).Path
$shellPath = (Get-Process -Id $PID).Path
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$attempt = 0

while ((Get-Date) -lt $deadline) {
  $attempt++
  $output = @(& $shellPath -NoProfile -ExecutionPolicy Bypass -File $resolvedScriptPath -Health 2>&1)
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

  if ($exitCode -eq 0) {
    $raw = ($output -join [Environment]::NewLine)
    try {
      $health = $raw | ConvertFrom-Json
      if ($null -ne $health -and [string]$health.status -eq "ok" -and [bool]$health.ready) {
        Write-Host "HEALTH_READY name=$Name attempt=$attempt"
        exit 0
      }
    }
    catch {
      # Retry until timeout if payload is not parseable yet.
    }
  }

  Start-Sleep -Seconds $IntervalSec
}

Write-Error "Health check timeout for '$Name' after $TimeoutSec seconds."
exit 1
