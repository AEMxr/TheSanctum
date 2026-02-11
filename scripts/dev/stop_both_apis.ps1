param(
  [string]$StatePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $scriptDir ".both_apis_state.json"
}

if (Test-Path -Path $StatePath -PathType Leaf) {
  Remove-Item -Path $StatePath -Force
  Write-Host "BOTH_APIS_STOPPED=true"
  Write-Host "STATE_PATH_REMOVED=$StatePath"
  exit 0
}

Write-Host "BOTH_APIS_STOPPED=true"
Write-Host "STATE_PATH_MISSING=$StatePath"
exit 0
