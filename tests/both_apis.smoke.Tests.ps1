# tests/both_apis.smoke.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester tests/both_apis.smoke.Tests.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message = "Assertion failed."
  )
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param(
    $Actual,
    $Expected,
    [string]$Message = "Values are not equal."
  )
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-Contains {
  param(
    [object[]]$Collection,
    $Value,
    [string]$Message = "Collection does not contain expected value."
  )
  if (-not ($Collection -contains $Value)) {
    throw "$Message`nExpected value: $Value"
  }
}

function Invoke-HttpJson {
  param(
    [Parameter(Mandatory = $true)][string]$Method,
    [Parameter(Mandatory = $true)][string]$Url,
    [hashtable]$Headers,
    [object]$Body,
    [int]$TimeoutSec = 10
  )

  $bodyJson = $null
  if ($PSBoundParameters.ContainsKey("Body") -and $null -ne $Body) {
    $bodyJson = $Body | ConvertTo-Json -Depth 40 -Compress
  }

  try {
    $resp = Invoke-WebRequest -Method $Method -Uri $Url -Headers $Headers -Body $bodyJson -ContentType "application/json" -UseBasicParsing -TimeoutSec $TimeoutSec
    $content = [string]$resp.Content
    $json = $null
    try { if (-not [string]::IsNullOrWhiteSpace($content)) { $json = $content | ConvertFrom-Json } } catch {}
    return [pscustomobject]@{
      status_code = [int]$resp.StatusCode
      headers = $resp.Headers
      content = $content
      json = $json
    }
  }
  catch {
    $webResp = $null
    if ($_.Exception.PSObject.Properties.Name -contains "Response") {
      $webResp = $_.Exception.Response
    }

    if ($null -ne $webResp) {
      $statusCode = [int]$webResp.StatusCode
      $reader = New-Object System.IO.StreamReader($webResp.GetResponseStream())
      try {
        $content = $reader.ReadToEnd()
      }
      finally {
        $reader.Dispose()
      }
      $json = $null
      try { if (-not [string]::IsNullOrWhiteSpace($content)) { $json = $content | ConvertFrom-Json } } catch {}

      return [pscustomobject]@{
        status_code = $statusCode
        headers = $webResp.Headers
        content = [string]$content
        json = $json
      }
    }

    throw
  }
}

Describe "dual API smoke contract" {
  BeforeAll {
    $script:LanguageBaseUrl = if ([string]::IsNullOrWhiteSpace($env:LANGUAGE_API_BASE_URL)) { "http://127.0.0.1:8081" } else { [string]$env:LANGUAGE_API_BASE_URL }
    $script:RevenueBaseUrl = if ([string]::IsNullOrWhiteSpace($env:REVENUE_API_BASE_URL)) { "http://127.0.0.1:8082" } else { [string]$env:REVENUE_API_BASE_URL }
    $script:ApiKey = if ([string]::IsNullOrWhiteSpace($env:SANCTUM_API_KEY)) { "dev-local-key" } else { [string]$env:SANCTUM_API_KEY }

    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = (Resolve-Path (Join-Path $here "..")).Path
    $script:StartScript = Join-Path $script:RepoRoot "scripts\dev\start_both_apis.ps1"
    $script:StopScript = Join-Path $script:RepoRoot "scripts\dev\stop_both_apis.ps1"
    $script:OwnedStatePath = Join-Path $script:RepoRoot "scripts\dev\.both_apis_state.tests.json"
    $script:OwnedApis = $false

    $languageReady = $false
    $revenueReady = $false
    try {
      $lr = Invoke-HttpJson -Method "GET" -Url ($script:LanguageBaseUrl + "/ready") -TimeoutSec 2
      $languageReady = ($lr.status_code -eq 200)
    } catch {}
    try {
      $rr = Invoke-HttpJson -Method "GET" -Url ($script:RevenueBaseUrl + "/ready") -TimeoutSec 2
      $revenueReady = ($rr.status_code -eq 200)
    } catch {}

    if (-not ($languageReady -and $revenueReady)) {
      if (-not (Test-Path -Path $script:StartScript -PathType Leaf)) { throw "Missing start script: $script:StartScript" }
      if (-not (Test-Path -Path $script:StopScript -PathType Leaf)) { throw "Missing stop script: $script:StopScript" }

      $languagePort = ([uri]$script:LanguageBaseUrl).Port
      $revenuePort = ([uri]$script:RevenueBaseUrl).Port
      & $script:StartScript -LanguagePort $languagePort -RevenuePort $revenuePort -ApiKey $script:ApiKey -StatePath $script:OwnedStatePath
      $startExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      Assert-Equal -Actual $startExit -Expected 0 -Message "start_both_apis.ps1 should exit 0 when bootstrapping smoke dependencies."
      $script:OwnedApis = $true
    }
  }

  AfterAll {
    if ($script:OwnedApis) {
      & $script:StopScript -StatePath $script:OwnedStatePath | Out-Null
    }
  }

  It "language API health and ready endpoints are reachable with stable envelope keys" {
    $health = Invoke-HttpJson -Method "GET" -Url ($script:LanguageBaseUrl + "/health")
    Assert-Equal -Actual $health.status_code -Expected 200 -Message "Language /health should return 200."
    Assert-True -Condition ($null -ne $health.json) -Message "Language /health should return JSON body."

    $requiredTopLevel = @("request_id", "schema_version", "provider_used", "result")
    foreach ($field in $requiredTopLevel) {
      Assert-True -Condition ($health.json.PSObject.Properties.Name -contains $field) -Message "Language /health missing top-level field: $field"
    }

    $result = $health.json.result
    $requiredResult = @("service", "status", "ready", "supported_modes", "supported_languages")
    foreach ($field in $requiredResult) {
      Assert-True -Condition ($result.PSObject.Properties.Name -contains $field) -Message "Language /health result missing field: $field"
    }
    Assert-Equal -Actual ([string]$result.service) -Expected "language_api" -Message "Language service mismatch."
    Assert-Equal -Actual ([bool]$result.ready) -Expected $true -Message "Language readiness mismatch."

    $ready = Invoke-HttpJson -Method "GET" -Url ($script:LanguageBaseUrl + "/ready")
    Assert-Equal -Actual $ready.status_code -Expected 200 -Message "Language /ready should return 200."
    Assert-Equal -Actual ([bool]$ready.json.result.ready) -Expected $true -Message "Language /ready result.ready mismatch."
  }

  It "revenue API health and execute endpoint are reachable with deterministic envelope keys" {
    $health = Invoke-HttpJson -Method "GET" -Url ($script:RevenueBaseUrl + "/health")
    Assert-Equal -Actual $health.status_code -Expected 200 -Message "Revenue /health should return 200."
    Assert-True -Condition ($null -ne $health.json) -Message "Revenue /health should return JSON body."

    $requiredTopLevel = @("request_id", "schema_version", "provider_used", "result")
    foreach ($field in $requiredTopLevel) {
      Assert-True -Condition ($health.json.PSObject.Properties.Name -contains $field) -Message "Revenue /health missing top-level field: $field"
    }
    Assert-Equal -Actual ([string]$health.json.result.service) -Expected "revenue_automation" -Message "Revenue service mismatch."
    Assert-Equal -Actual ([bool]$health.json.result.ready) -Expected $true -Message "Revenue readiness mismatch."

    $task = [pscustomobject]@{
      task_id = "smoke-task-001"
      task_type = "lead_enrich"
      payload = [pscustomobject]@{
        source_channel = "reddit"
        campaign_id = "camp-smoke-001"
        language_code = "en"
        leads = @([pscustomobject]@{ lead_id = "lead-smoke-001"; segment = "saas"; budget = 500; engagement_score = 50 })
      }
      created_at_utc = "2026-01-01T00:00:00Z"
    }

    $headers = @{ "X-API-Key" = $script:ApiKey }
    $exec = Invoke-HttpJson -Method "POST" -Url ($script:RevenueBaseUrl + "/v1/revenue/task/execute") -Headers $headers -Body $task
    Assert-Equal -Actual $exec.status_code -Expected 200 -Message "Revenue execute endpoint should return 200."

    $execRequired = @("request_id", "schema_version", "provider_used", "result")
    foreach ($field in $execRequired) {
      Assert-True -Condition ($exec.json.PSObject.Properties.Name -contains $field) -Message "Revenue execute missing top-level field: $field"
    }

    $result = $exec.json.result
    $resultRequired = @("task_id", "status", "provider_used", "reason_codes")
    foreach ($field in $resultRequired) {
      Assert-True -Condition ($result.PSObject.Properties.Name -contains $field) -Message "Revenue execute result missing field: $field"
    }
    Assert-Equal -Actual ([string]$result.task_id) -Expected "smoke-task-001" -Message "Revenue task_id mismatch."
    Assert-Contains -Collection @("SUCCESS", "FAILED", "SKIPPED") -Value ([string]$result.status) -Message "Revenue status must be SUCCESS|FAILED|SKIPPED."
  }
}
