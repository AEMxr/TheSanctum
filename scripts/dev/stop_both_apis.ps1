param(
  [string]$StatePath = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
if ([string]::IsNullOrWhiteSpace($StatePath)) {
  $StatePath = Join-Path $scriptDir ".both_apis_state.json"
}

if (-not (Test-Path -Path $StatePath -PathType Leaf)) {
  Write-Host "BOTH_APIS_STOPPED=true"
  Write-Host "STATE_PATH_MISSING=$StatePath"
  exit 0
}

$state = Get-Content -Path $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$pidList = New-Object System.Collections.Generic.List[int]

if ($state.PSObject.Properties.Name -contains "language_api") {
  $tmpPid = 0
  if ([int]::TryParse([string]$state.language_api.pid, [ref]$tmpPid) -and $tmpPid -gt 0) {
    [void]$pidList.Add($tmpPid)
  }
}
if ($state.PSObject.Properties.Name -contains "revenue_api") {
  $tmpPid = 0
  if ([int]::TryParse([string]$state.revenue_api.pid, [ref]$tmpPid) -and $tmpPid -gt 0) {
    [void]$pidList.Add($tmpPid)
  }
}

foreach ($procId in @($pidList | Select-Object -Unique)) {
  try {
    $proc = Get-Process -Id $procId -ErrorAction SilentlyContinue
    if ($null -ne $proc) {
      Stop-Process -Id $procId -Force -ErrorAction SilentlyContinue
      Write-Host "STOPPED_PID=$procId"
    }
  }
  catch {
    # best-effort cleanup
  }
}

Remove-Item -Path $StatePath -Force -ErrorAction SilentlyContinue
Write-Host "BOTH_APIS_STOPPED=true"
Write-Host "STATE_PATH_REMOVED=$StatePath"
exit 0
