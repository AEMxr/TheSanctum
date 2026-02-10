param(
  [string]$BaseUrl = '',
  [string]$ApiHealthPath = '/health',
  [int]$TimeoutSec = 10,
  [string]$PsqlExe = 'psql',
  [string[]]$PsqlArgs = @(),
  [string]$NewmanExe = 'newman',
  [switch]$SkipApiCheck,
  [switch]$SkipPsqlCheck,
  [switch]$SkipNewmanCheck,
  [switch]$SkipDbConnectivity
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$blockers = New-Object System.Collections.Generic.List[string]
$warnings = New-Object System.Collections.Generic.List[string]

function Add-Blocker {
  param([string]$Message)
  [void]$blockers.Add($Message)
}

function Add-Warning {
  param([string]$Message)
  [void]$warnings.Add($Message)
}

function Resolve-BaseUrl {
  param([string]$Explicit)
  if (-not [string]::IsNullOrWhiteSpace($Explicit)) { return $Explicit.Trim() }
  foreach ($name in @('STAGING_BASE_URL', 'BASE_URL', 'API_BASE_URL')) {
    $value = [Environment]::GetEnvironmentVariable($name)
    if (-not [string]::IsNullOrWhiteSpace($value)) {
      return $value.Trim()
    }
  }
  return ''
}

function Test-Tool {
  param(
    [string]$ToolName,
    [string]$Label
  )
  try {
    $cmd = Get-Command $ToolName -ErrorAction Stop
    return [pscustomobject]@{ Found = $true; Source = $cmd.Source; Version = [string]$cmd.Version }
  }
  catch {
    Add-Blocker "$Label not found on PATH: $ToolName"
    return [pscustomobject]@{ Found = $false; Source = ''; Version = '' }
  }
}

function Join-Url {
  param([string]$Root, [string]$Path)
  if ($Path.StartsWith('/')) { return "$Root$Path" }
  return "$Root/$Path"
}

$resolvedBaseUrl = Resolve-BaseUrl -Explicit $BaseUrl

$psqlInfo = [pscustomobject]@{ Found = $false; Source = ''; Version = '' }
$newmanInfo = [pscustomobject]@{ Found = $false; Source = ''; Version = '' }
$apiStatusCode = -1
$apiStatusText = ''

if (-not $SkipPsqlCheck) {
  $psqlInfo = Test-Tool -ToolName $PsqlExe -Label 'psql'
  if ($psqlInfo.Found -and -not $SkipDbConnectivity -and $PsqlArgs.Count -gt 0) {
    try {
      $dbOut = & $PsqlExe @PsqlArgs -c "select 1 as preflight_ok;" 2>&1
      if ($LASTEXITCODE -ne 0) {
        Add-Blocker "psql connectivity check failed (exit=$LASTEXITCODE): $($dbOut | Out-String)"
      }
    }
    catch {
      Add-Blocker "psql connectivity check failed: $($_.Exception.Message)"
    }
  }
  elseif ($psqlInfo.Found -and -not $SkipDbConnectivity -and $PsqlArgs.Count -eq 0) {
    Add-Warning 'Skipping DB connectivity probe because no -PsqlArgs were provided.'
  }
}

if (-not $SkipNewmanCheck) {
  $newmanInfo = Test-Tool -ToolName $NewmanExe -Label 'newman'
}

if (-not $SkipApiCheck) {
  if ([string]::IsNullOrWhiteSpace($resolvedBaseUrl)) {
    Add-Blocker 'BaseUrl not provided and no STAGING_BASE_URL/BASE_URL/API_BASE_URL env var found.'
  }
  else {
    $uri = Join-Url -Root $resolvedBaseUrl.TrimEnd('/') -Path $ApiHealthPath
    try {
      $resp = Invoke-WebRequest -Method GET -Uri $uri -TimeoutSec $TimeoutSec -UseBasicParsing
      $apiStatusCode = [int]$resp.StatusCode
      $apiStatusText = [string]$resp.StatusDescription
      if ($apiStatusCode -lt 200 -or $apiStatusCode -ge 400) {
        Add-Blocker "API health check returned non-success status: $apiStatusCode $apiStatusText ($uri)"
      }
    }
    catch {
      Add-Blocker "API health check failed for ${uri}: $($_.Exception.Message)"
    }
  }
}

$report = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  base_url = $resolvedBaseUrl
  api_health_path = $ApiHealthPath
  timeout_sec = $TimeoutSec
  psql = $psqlInfo
  newman = $newmanInfo
  api_status_code = $apiStatusCode
  api_status_text = $apiStatusText
  blockers = @($blockers.ToArray())
  warnings = @($warnings.ToArray())
  blocker_count = $blockers.Count
  warning_count = $warnings.Count
  verdict = if ($blockers.Count -eq 0) { 'PREFLIGHT_READY' } else { 'PREFLIGHT_BLOCKED' }
}

$report | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 preflight_report.json

if ($warnings.Count -gt 0) {
  Write-Host 'Warnings:'
  foreach ($w in $warnings) { Write-Host " - $w" }
}

if ($blockers.Count -gt 0) {
  Write-Host 'Blockers:'
  foreach ($b in $blockers) { Write-Host " - $b" }
  Write-Host 'VERDICT: PREFLIGHT_BLOCKED'
  exit 1
}

Write-Host 'VERDICT: PREFLIGHT_READY'
exit 0
