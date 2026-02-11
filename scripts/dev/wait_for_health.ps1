param(
  [Parameter(Mandatory = $true)][string]$Url,
  [string]$Name = "api",
  [int]$TimeoutSec = 30,
  [int]$IntervalSec = 1,
  [switch]$RequireReady
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if ($TimeoutSec -lt 1) { throw "TimeoutSec must be >= 1." }
if ($IntervalSec -lt 1) { throw "IntervalSec must be >= 1." }

$deadline = (Get-Date).AddSeconds($TimeoutSec)
$attempt = 0
while ((Get-Date) -lt $deadline) {
  $attempt++
  try {
    $resp = Invoke-WebRequest -Uri $Url -Method Get -UseBasicParsing -TimeoutSec $IntervalSec
    if ($resp.StatusCode -eq 200) {
      $payload = $null
      try {
        $payload = $resp.Content | ConvertFrom-Json
      }
      catch {
        $payload = $null
      }

      if (-not $RequireReady) {
        Write-Host "HEALTH_READY name=$Name attempt=$attempt"
        exit 0
      }

      if ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "result") {
        $result = $payload.result
        $isReady = $false
        if ($null -ne $result -and $result.PSObject.Properties.Name -contains "ready") {
          $isReady = [bool]$result.ready
        }
        if ($isReady) {
          Write-Host "HEALTH_READY name=$Name attempt=$attempt"
          exit 0
        }
      }
      elseif ($null -ne $payload -and $payload.PSObject.Properties.Name -contains "ready" -and [bool]$payload.ready) {
        Write-Host "HEALTH_READY name=$Name attempt=$attempt"
        exit 0
      }
    }
  }
  catch {
    # continue retries
  }

  Start-Sleep -Seconds $IntervalSec
}

Write-Error "Health check timeout for '$Name' after $TimeoutSec seconds. Url: $Url"
exit 1
