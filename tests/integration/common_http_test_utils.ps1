Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

try {
  Add-Type -AssemblyName System.Net.Http -ErrorAction Stop | Out-Null
}
catch {
  # Assembly can already be loaded; continue.
}

function Invoke-HttpJsonRequest {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers,
    [object]$Body,
    [int]$TimeoutSec = 15
  )

  $bodyJson = $null
  if ($PSBoundParameters.ContainsKey("Body") -and $null -ne $Body) {
    $bodyJson = $Body | ConvertTo-Json -Depth 60 -Compress
  }

  $handler = New-Object System.Net.Http.HttpClientHandler
  $client = New-Object System.Net.Http.HttpClient($handler)
  try {
    $client.Timeout = [TimeSpan]::FromSeconds([Math]::Max(1, $TimeoutSec))
    $message = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::new($Method), $Url)

    if ($null -ne $Headers) {
      foreach ($key in $Headers.Keys) {
        $value = [string]$Headers[$key]
        if (-not [string]::IsNullOrWhiteSpace($key)) {
          [void]$message.Headers.TryAddWithoutValidation([string]$key, $value)
        }
      }
    }

    if (-not [string]::IsNullOrWhiteSpace($bodyJson)) {
      $message.Content = New-Object System.Net.Http.StringContent($bodyJson, [System.Text.Encoding]::UTF8, "application/json")
    }

    $response = $client.SendAsync($message).GetAwaiter().GetResult()
    $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($content)) { $json = $content | ConvertFrom-Json } } catch {}

    $headerTable = @{}
    foreach ($pair in $response.Headers) {
      $headerTable[[string]$pair.Key] = [string]($pair.Value -join ",")
    }
    foreach ($pair in $response.Content.Headers) {
      $headerTable[[string]$pair.Key] = [string]($pair.Value -join ",")
    }

    return [pscustomobject]@{
      status_code = [int]$response.StatusCode
      headers = $headerTable
      content = [string]$content
      json = $json
    }
  }
  finally {
    $client.Dispose()
    $handler.Dispose()
  }
}

function Get-IntegrationApiDefaults {
  $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
  $languageBaseUrl = if ([string]::IsNullOrWhiteSpace($env:LANGUAGE_API_BASE_URL)) { "http://127.0.0.1:18081" } else { [string]$env:LANGUAGE_API_BASE_URL }
  $revenueBaseUrl = if ([string]::IsNullOrWhiteSpace($env:REVENUE_API_BASE_URL)) { "http://127.0.0.1:18082" } else { [string]$env:REVENUE_API_BASE_URL }
  $apiKey = if ([string]::IsNullOrWhiteSpace($env:SANCTUM_API_KEY)) { "dev-local-key" } else { [string]$env:SANCTUM_API_KEY }

  return [pscustomobject]@{
    repo_root = $repoRoot
    language_base_url = $languageBaseUrl
    revenue_base_url = $revenueBaseUrl
    api_key = $apiKey
    start_script = Join-Path $repoRoot "scripts\dev\start_both_apis.ps1"
    stop_script = Join-Path $repoRoot "scripts\dev\stop_both_apis.ps1"
    state_path = Join-Path $repoRoot "scripts\dev\.both_apis_state.integration.json"
  }
}

function Ensure-IntegrationApisRunning {
  $defaults = Get-IntegrationApiDefaults

  $languageReady = $false
  $revenueReady = $false
  try {
    $lr = Invoke-HttpJsonRequest -Method "GET" -Url ($defaults.language_base_url + "/ready") -TimeoutSec 2
    $languageReady = ($lr.status_code -eq 200)
  } catch {}
  try {
    $rr = Invoke-HttpJsonRequest -Method "GET" -Url ($defaults.revenue_base_url + "/ready") -TimeoutSec 2
    $revenueReady = ($rr.status_code -eq 200)
  } catch {}

  $owned = $false
  if (-not ($languageReady -and $revenueReady)) {
    if (-not (Test-Path -Path $defaults.start_script -PathType Leaf)) { throw "Missing start script: $($defaults.start_script)" }
    if (-not (Test-Path -Path $defaults.stop_script -PathType Leaf)) { throw "Missing stop script: $($defaults.stop_script)" }

    $languagePort = ([uri]$defaults.language_base_url).Port
    $revenuePort = ([uri]$defaults.revenue_base_url).Port

    & $defaults.start_script -LanguagePort $languagePort -RevenuePort $revenuePort -ApiKey $defaults.api_key -StatePath $defaults.state_path
    $startExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($startExit -ne 0) {
      throw "start_both_apis.ps1 failed with exit code $startExit."
    }

    $owned = $true
  }

  $env:LANGUAGE_API_BASE_URL = $defaults.language_base_url
  $env:REVENUE_API_BASE_URL = $defaults.revenue_base_url
  $env:SANCTUM_API_KEY = $defaults.api_key

  return [pscustomobject]@{
    owned = $owned
    state_path = $defaults.state_path
    stop_script = $defaults.stop_script
    language_base_url = $defaults.language_base_url
    revenue_base_url = $defaults.revenue_base_url
    api_key = $defaults.api_key
  }
}

function Stop-IntegrationApisIfOwned {
  param([Parameter(Mandatory = $true)][object]$Context)

  if ($null -eq $Context) { return }
  if (-not [bool]$Context.owned) { return }

  if (Test-Path -Path $Context.stop_script -PathType Leaf) {
    & $Context.stop_script -StatePath ([string]$Context.state_path) | Out-Null
  }
}
