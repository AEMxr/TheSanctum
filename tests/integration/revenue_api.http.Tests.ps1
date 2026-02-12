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
    for ($i = 0; $i -lt 300; $i++) {
      $task.task_id = "rev-http-rate-$i"
      $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/marketing/task/execute") -Headers $headers -Body $task
      if ($resp.status_code -eq 429) {
        $hit429 = $true
        break
      }
    }

    Assert-True -Condition $hit429 -Message "Expected 429 rate-limit response was not observed for revenue API."
  }

  It "enforces shared-state rate limit across two API instances" {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $apiScriptPath = Join-Path $repoRoot "apps\revenue_automation\src\index.ps1"
    $runtimeDir = Join-Path $repoRoot "artifacts\runtime\integration_shared_state"
    if (-not (Test-Path -Path $runtimeDir -PathType Container)) {
      New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }

    $unique = [guid]::NewGuid().ToString("N")
    $sharedStatePath = Join-Path $runtimeDir ("revenue_shared_state_{0}.json" -f $unique)
    $configPath1 = Join-Path $runtimeDir ("revenue_api_config_{0}_1.json" -f $unique)
    $configPath2 = Join-Path $runtimeDir ("revenue_api_config_{0}_2.json" -f $unique)
    $ledgerPath1 = "apps/revenue_automation/artifacts/usage/revenue_api_usage.shared.{0}.1.jsonl" -f $unique
    $ledgerPath2 = "apps/revenue_automation/artifacts/usage/revenue_api_usage.shared.{0}.2.jsonl" -f $unique

    $free1 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $free1.Start()
    $port1 = ([System.Net.IPEndPoint]$free1.LocalEndpoint).Port
    $free1.Stop()
    $free2 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $free2.Start()
    $port2 = ([System.Net.IPEndPoint]$free2.LocalEndpoint).Port
    $free2.Stop()

    $config1 = [pscustomobject]@{
      enable_revenue_automation = $true
      provider_mode = "mock"
      emit_telemetry = $false
      safe_mode = $true
      dry_run = $true
      http = [pscustomobject]@{
        host = "127.0.0.1"
        port = $port1
        schema_version = "marketing-revenue-api-http-v1"
        max_request_bytes = 131072
        request_timeout_ms = 20000
        idempotency_ttl_seconds = 300
        state_backend = "file"
        shared_state_path = $sharedStatePath
        shared_state_scope = "revenue_api_integration_shared"
        rate_limit = [pscustomobject]@{
          max_requests = 2
          window_seconds = 86400
        }
        api_keys = @([pscustomobject]@{
          key_id = "shared-state-key"
          key = $script:ApiKey
          role = "admin"
        })
        usage_ledger_path = $ledgerPath1
      }
    }

    $config2 = [pscustomobject]@{
      enable_revenue_automation = $true
      provider_mode = "mock"
      emit_telemetry = $false
      safe_mode = $true
      dry_run = $true
      http = [pscustomobject]@{
        host = "127.0.0.1"
        port = $port2
        schema_version = "marketing-revenue-api-http-v1"
        max_request_bytes = 131072
        request_timeout_ms = 20000
        idempotency_ttl_seconds = 300
        state_backend = "file"
        shared_state_path = $sharedStatePath
        shared_state_scope = "revenue_api_integration_shared"
        rate_limit = [pscustomobject]@{
          max_requests = 2
          window_seconds = 86400
        }
        api_keys = @([pscustomobject]@{
          key_id = "shared-state-key"
          key = $script:ApiKey
          role = "admin"
        })
        usage_ledger_path = $ledgerPath2
      }
    }

    $config1 | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath1 -Encoding UTF8
    $config2 | ConvertTo-Json -Depth 20 | Set-Content -Path $configPath2 -Encoding UTF8

    $shellPath = (Get-Process -Id $PID).Path
    $proc1 = $null
    $proc2 = $null
    try {
      $args1 = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$apiScriptPath,"-Serve","-ConfigPath",$configPath1)
      $args2 = @("-NoProfile","-ExecutionPolicy","Bypass","-File",$apiScriptPath,"-Serve","-ConfigPath",$configPath2)
      $proc1 = Start-Process -FilePath $shellPath -ArgumentList $args1 -PassThru -WindowStyle Hidden
      $proc2 = Start-Process -FilePath $shellPath -ArgumentList $args2 -PassThru -WindowStyle Hidden

      $readyUrls = @("http://127.0.0.1:$port1/ready", "http://127.0.0.1:$port2/ready")
      foreach ($readyUrl in $readyUrls) {
        $isReady = $false
        for ($i = 0; $i -lt 30; $i++) {
          try {
            $readyResp = Invoke-HttpJsonRequest -Method "GET" -Url $readyUrl -TimeoutSec 2
            if ($readyResp.status_code -eq 200 -and $null -ne $readyResp.json -and $readyResp.json.PSObject.Properties.Name -contains "result" -and [bool]$readyResp.json.result.ready) {
              Assert-Equal -Actual ([string]$readyResp.json.result.state_backend) -Expected "file" -Message "Shared-state test instance must run with state_backend=file."
              Assert-Equal -Actual ([string]$readyResp.json.result.state_scope) -Expected "revenue_api_integration_shared" -Message "Shared-state test instance must expose expected state_scope."
              $isReady = $true
              break
            }
          }
          catch {}
          Start-Sleep -Milliseconds 500
        }
        Assert-True -Condition $isReady -Message "Timed out waiting for shared-state test API readiness at $readyUrl"
      }

      $idempotencyHeaders = @{
        "X-API-Key" = $script:ApiKey
        "Idempotency-Key" = ("shared-rev-idem-" + $unique)
      }
      $task = [pscustomobject]@{
        task_id = "rev-shared-state-001"
        task_type = "followup_draft"
        payload = [pscustomobject]@{ lead_id = "lead-shared-state-001" }
        created_at_utc = "2026-01-01T00:00:00Z"
      }
      $first = Invoke-HttpJsonRequest -Method "POST" -Url ("http://127.0.0.1:$port1/v1/marketing/task/execute") -Headers $idempotencyHeaders -Body $task
      $second = Invoke-HttpJsonRequest -Method "POST" -Url ("http://127.0.0.1:$port2/v1/marketing/task/execute") -Headers $idempotencyHeaders -Body $task

      Assert-Equal -Actual $first.status_code -Expected 200 -Message "First shared-state request should be allowed."
      Assert-Equal -Actual $second.status_code -Expected 200 -Message "Second shared-state request should replay across instances."
      Assert-Equal -Actual ([string]$first.content) -Expected ([string]$second.content) -Message "Shared-state idempotency replay should return identical response body across instances."

      $rateHeaders = @{ "X-API-Key" = $script:ApiKey }
      $taskRate = [pscustomobject]@{
        task_id = "rev-shared-state-003"
        task_type = "followup_draft"
        payload = [pscustomobject]@{ lead_id = "lead-shared-state-003" }
        created_at_utc = "2026-01-01T00:00:00Z"
      }
      $third = Invoke-HttpJsonRequest -Method "POST" -Url ("http://127.0.0.1:$port2/v1/marketing/task/execute") -Headers $rateHeaders -Body $taskRate
      Assert-Equal -Actual $third.status_code -Expected 429 -Message "Third shared-state request should be rate-limited across instances."
    }
    finally {
      foreach ($proc in @($proc1, $proc2)) {
        if ($null -ne $proc) {
          try {
            $running = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
            if ($null -ne $running) {
              Stop-Process -Id $proc.Id -Force -ErrorAction SilentlyContinue
            }
          }
          catch {}
        }
      }
      foreach ($path in @($configPath1, $configPath2, $sharedStatePath)) {
        if (-not [string]::IsNullOrWhiteSpace($path) -and (Test-Path -Path $path -PathType Leaf)) {
          Remove-Item -Path $path -Force -ErrorAction SilentlyContinue
        }
      }
    }
  }
}
