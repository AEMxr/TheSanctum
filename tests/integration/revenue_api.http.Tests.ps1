# tests/integration/revenue_api.http.Tests.ps1
# Pester 3.x / 5.x compatible

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool]$Condition,[string]$Message = "Assertion failed.")
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Actual,$Expected,[string]$Message = "Values are not equal.")
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-Contains {
  param([object[]]$Collection,$Value,[string]$Message = "Collection missing value.")
  if (-not ($Collection -contains $Value)) {
    throw "$Message`nExpected value: $Value"
  }
}

Describe "revenue API localhost HTTP integration" {
  BeforeAll {
    . (Join-Path $PSScriptRoot "common_http_test_utils.ps1")
    $script:Ctx = Ensure-IntegrationApisRunning
    $script:BaseUrl = [string]$script:Ctx.revenue_base_url
    $script:ApiKey = [string]$script:Ctx.api_key

    $script:HappyTask = [pscustomobject]@{
      task_id = "rev-http-task-001"
      task_type = "lead_enrich"
      payload = [pscustomobject]@{
        source_channel = "reddit"
        campaign_id = "camp-http-001"
        language_code = "en"
        leads = @([pscustomobject]@{ lead_id = "lead-http-001"; segment = "saas"; budget = 1200; engagement_score = 88 })
      }
      created_at_utc = "2026-01-01T00:00:00Z"
    }
  }

  AfterAll {
    Stop-IntegrationApisIfOwned -Context $script:Ctx
  }

  It "returns health and ready envelopes" {
    $health = Invoke-HttpJsonRequest -Method "GET" -Url ($script:BaseUrl + "/health")
    Assert-Equal -Actual $health.status_code -Expected 200 -Message "Revenue /health should return 200."
    Assert-True -Condition ($null -ne $health.json) -Message "Revenue /health should return JSON."
    Assert-True -Condition ($health.json.PSObject.Properties.Name -contains "request_id") -Message "Revenue /health missing request_id."
    Assert-Equal -Actual ([string]$health.json.result.service) -Expected "revenue_automation" -Message "Revenue service mismatch."

    $ready = Invoke-HttpJsonRequest -Method "GET" -Url ($script:BaseUrl + "/ready")
    Assert-Equal -Actual $ready.status_code -Expected 200 -Message "Revenue /ready should return 200."
    Assert-Equal -Actual ([bool]$ready.json.result.ready) -Expected $true -Message "Revenue /ready ready mismatch."
  }

  It "rejects missing api key with problem+json" {
    $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Body $script:HappyTask
    Assert-Equal -Actual $resp.status_code -Expected 401 -Message "Missing API key should return 401."
    Assert-True -Condition ($null -ne $resp.json) -Message "401 response should be JSON problem payload."
    Assert-Equal -Actual ([int]$resp.json.status) -Expected 401 -Message "Problem payload status mismatch for missing API key."
  }

  It "returns 400 problem+json for invalid task payload" {
    $headers = @{ "X-API-Key" = $script:ApiKey }
    $invalidTask = [pscustomobject]@{ task_type = "lead_enrich" }
    $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Headers $headers -Body $invalidTask
    Assert-Equal -Actual $resp.status_code -Expected 400 -Message "Invalid payload should return 400."
    Assert-Equal -Actual ([int]$resp.json.status) -Expected 400 -Message "Problem payload status mismatch for invalid task payload."
    Assert-True -Condition ($resp.json.detail -like "*task_id is required*") -Message "Expected task_id validation detail."
  }

  It "executes happy path for both execute aliases" {
    $headers = @{ "X-API-Key" = $script:ApiKey }

    $marketing = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Headers $headers -Body $script:HappyTask
    Assert-Equal -Actual $marketing.status_code -Expected 200 -Message "Marketing execute should return 200."
    Assert-Equal -Actual ([string]$marketing.json.result.task_id) -Expected "rev-http-task-001" -Message "Marketing execute task_id mismatch."
    Assert-Contains -Collection @("SUCCESS", "FAILED", "SKIPPED") -Value ([string]$marketing.json.result.status) -Message "Marketing execute status invalid."

    $aliasTask = [pscustomobject]@{
      task_id = "rev-http-task-002"
      task_type = "followup_draft"
      payload = [pscustomobject]@{ lead_id = "lead-http-002" }
      created_at_utc = "2026-01-01T00:00:00Z"
    }

    $alias = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/revenue/task/execute") -Headers $headers -Body $aliasTask
    Assert-Equal -Actual $alias.status_code -Expected 200 -Message "Revenue alias execute should return 200."
    Assert-Equal -Actual ([string]$alias.json.result.task_id) -Expected "rev-http-task-002" -Message "Revenue alias execute task_id mismatch."
    Assert-Contains -Collection @("SUCCESS", "FAILED", "SKIPPED") -Value ([string]$alias.json.result.status) -Message "Revenue alias execute status invalid."
  }

  It "replays identical response for idempotency key reuse" {
    $headers = @{ "X-API-Key" = $script:ApiKey; "Idempotency-Key" = ("rev-idem-" + [guid]::NewGuid().ToString("N")) }
    $task = [pscustomobject]@{
      task_id = "rev-http-idem-001"
      task_type = "lead_enrich"
      payload = [pscustomobject]@{
        source_channel = "reddit"
        campaign_id = "camp-http-idem-001"
        language_code = "en"
        leads = @([pscustomobject]@{ lead_id = "lead-http-idem-001"; segment = "saas"; budget = 1100; engagement_score = 80 })
      }
      created_at_utc = "2026-01-01T00:00:00Z"
    }

    $first = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Headers $headers -Body $task
    $second = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Headers $headers -Body $task

    Assert-Equal -Actual $first.status_code -Expected 200 -Message "Revenue idempotency first request should return 200."
    Assert-Equal -Actual $second.status_code -Expected 200 -Message "Revenue idempotency replay should return 200."
    Assert-Equal -Actual ([string]$first.content) -Expected ([string]$second.content) -Message "Revenue idempotency replay body mismatch."
  }

  It "enforces per-key rate limit with 429" {
    $headers = @{ "X-API-Key" = $script:ApiKey }
    $task = [pscustomobject]@{
      task_id = "rev-http-rate-001"
      task_type = "followup_draft"
      payload = [pscustomobject]@{ lead_id = "lead-http-rate-001" }
      created_at_utc = "2026-01-01T00:00:00Z"
    }

    $hit429 = $false
    for ($i = 0; $i -lt 150; $i++) {
      $task.task_id = "rev-http-rate-$i"
      $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Headers $headers -Body $task
      if ($resp.status_code -eq 429) {
        $hit429 = $true
        break
      }
    }

    Assert-True -Condition $hit429 -Message "Expected 429 rate-limit response was not observed for revenue API."
  }
}
