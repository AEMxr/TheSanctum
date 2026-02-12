# tests/integration/language_api.http.Tests.ps1
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

Describe "language API localhost HTTP integration" {
  BeforeAll {
    . (Join-Path $PSScriptRoot "common_http_test_utils.ps1")
    $script:Ctx = Ensure-IntegrationApisRunning
    $script:BaseUrl = [string]$script:Ctx.language_base_url
    $script:ApiKey = [string]$script:Ctx.api_key
  }

  AfterAll {
    Stop-IntegrationApisIfOwned -Context $script:Ctx
  }

  It "returns health and ready envelopes" {
    $health = Invoke-HttpJsonRequest -Method "GET" -Url ($script:BaseUrl + "/health")
    Assert-Equal -Actual $health.status_code -Expected 200 -Message "Language /health should return 200."
    Assert-True -Condition ($null -ne $health.json) -Message "Language /health should return JSON."
    Assert-True -Condition ($health.json.PSObject.Properties.Name -contains "request_id") -Message "Language /health missing request_id."
    Assert-Equal -Actual ([string]$health.json.result.service) -Expected "language_api" -Message "Language service mismatch."

    $ready = Invoke-HttpJsonRequest -Method "GET" -Url ($script:BaseUrl + "/ready")
    Assert-Equal -Actual $ready.status_code -Expected 200 -Message "Language /ready should return 200."
    Assert-Equal -Actual ([bool]$ready.json.result.ready) -Expected $true -Message "Language /ready ready mismatch."
  }

  It "rejects missing api key with problem+json" {
    $payload = [pscustomobject]@{ input_text = "hello offer"; source_channel = "reddit"; mode = "detect" }
    $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Body $payload
    Assert-Equal -Actual $resp.status_code -Expected 401 -Message "Missing API key should return 401."
    Assert-True -Condition ($null -ne $resp.json) -Message "401 response should be JSON problem payload."
    Assert-Equal -Actual ([int]$resp.json.status) -Expected 401 -Message "Problem payload status mismatch for missing API key."
    Assert-True -Condition ($resp.json.PSObject.Properties.Name -contains "request_id") -Message "Problem payload missing request_id."
  }

  It "returns 400 problem+json for invalid payload" {
    $headers = @{ "X-API-Key" = $script:ApiKey }
    $payload = [pscustomobject]@{ source_channel = "reddit" }
    $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Headers $headers -Body $payload
    Assert-Equal -Actual $resp.status_code -Expected 400 -Message "Invalid payload should return 400."
    Assert-Equal -Actual ([int]$resp.json.status) -Expected 400 -Message "Problem payload status mismatch for invalid payload."
    Assert-True -Condition ($resp.json.detail -like "*input_text is required*") -Message "Expected input_text validation message."
  }

  It "returns deterministic detect and translate responses" {
    $headers = @{ "X-API-Key" = $script:ApiKey }

    $detectPayload = [pscustomobject]@{
      input_text = "hola gracias oferta cliente servicio automatizacion"
      source_channel = "reddit"
      mode = "detect"
    }
    $detect = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Headers $headers -Body $detectPayload
    Assert-Equal -Actual $detect.status_code -Expected 200 -Message "Detect should return 200."
    Assert-Equal -Actual ([string]$detect.json.result.detected_language) -Expected "es" -Message "Detect language mismatch."
    Assert-Contains -Collection @($detect.json.result.reason_codes) -Value "lang_detect_high_conf" -Message "Detect reason code mismatch."

    $translatePayload = [pscustomobject]@{
      input_text = "hola gracias oferta cliente"
      source_channel = "reddit"
      source_language = "es"
      target_language = "en"
      mode = "convert"
    }
    $translate = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/translate") -Headers $headers -Body $translatePayload
    Assert-Equal -Actual $translate.status_code -Expected 200 -Message "Translate should return 200."
    Assert-Equal -Actual ([string]$translate.json.result.target_language) -Expected "en" -Message "Translate target mismatch."
    Assert-Equal -Actual ([bool]$translate.json.result.conversion_applied) -Expected $true -Message "Translate conversion_applied mismatch."
  }

  It "replays identical response for idempotency key reuse" {
    $headers = @{ "X-API-Key" = $script:ApiKey; "Idempotency-Key" = ("lang-idem-" + [guid]::NewGuid().ToString("N")) }
    $payload = [pscustomobject]@{
      input_text = "hello thanks offer"
      source_channel = "web"
      mode = "detect"
    }

    $first = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Headers $headers -Body $payload
    $second = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Headers $headers -Body $payload

    Assert-Equal -Actual $first.status_code -Expected 200 -Message "Idempotency first request should return 200."
    Assert-Equal -Actual $second.status_code -Expected 200 -Message "Idempotency replay should return 200."
    Assert-Equal -Actual ([string]$first.content) -Expected ([string]$second.content) -Message "Idempotency replay body mismatch."
  }

  It "enforces per-key rate limit with 429" {
    $headers = @{ "X-API-Key" = $script:ApiKey }
    $payload = [pscustomobject]@{ input_text = "hello offer"; source_channel = "reddit"; mode = "detect" }

    $hit429 = $false
    for ($i = 0; $i -lt 300; $i++) {
      $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Headers $headers -Body $payload
      if ($resp.status_code -eq 429) {
        $hit429 = $true
        break
      }
    }

    Assert-True -Condition $hit429 -Message "Expected 429 rate-limit response was not observed."
  }

  It "enforces shared-state rate limit across two API instances" {
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
    $apiScriptPath = Join-Path $repoRoot "apps\api\src\index.ps1"
    $runtimeDir = Join-Path $repoRoot "artifacts\runtime\integration_shared_state"
    if (-not (Test-Path -Path $runtimeDir -PathType Container)) {
      New-Item -ItemType Directory -Path $runtimeDir -Force | Out-Null
    }

    $unique = [guid]::NewGuid().ToString("N")
    $sharedStatePath = Join-Path $runtimeDir ("language_shared_state_{0}.json" -f $unique)
    $configPath1 = Join-Path $runtimeDir ("language_api_config_{0}_1.json" -f $unique)
    $configPath2 = Join-Path $runtimeDir ("language_api_config_{0}_2.json" -f $unique)
    $ledgerPath1 = "apps/api/artifacts/usage/language_api_usage.shared.{0}.1.jsonl" -f $unique
    $ledgerPath2 = "apps/api/artifacts/usage/language_api_usage.shared.{0}.2.jsonl" -f $unique

    $free1 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $free1.Start()
    $port1 = ([System.Net.IPEndPoint]$free1.LocalEndpoint).Port
    $free1.Stop()
    $free2 = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $free2.Start()
    $port2 = ([System.Net.IPEndPoint]$free2.LocalEndpoint).Port
    $free2.Stop()

    $config1 = [pscustomobject]@{
      http = [pscustomobject]@{
        host = "127.0.0.1"
        port = $port1
        schema_version = "language-api-http-v1"
        max_request_bytes = 65536
        request_timeout_ms = 15000
        idempotency_ttl_seconds = 300
        state_backend = "file"
        shared_state_path = $sharedStatePath
        shared_state_scope = "language_api_integration_shared"
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
      http = [pscustomobject]@{
        host = "127.0.0.1"
        port = $port2
        schema_version = "language-api-http-v1"
        max_request_bytes = 65536
        request_timeout_ms = 15000
        idempotency_ttl_seconds = 300
        state_backend = "file"
        shared_state_path = $sharedStatePath
        shared_state_scope = "language_api_integration_shared"
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
              Assert-Equal -Actual ([string]$readyResp.json.result.state_scope) -Expected "language_api_integration_shared" -Message "Shared-state test instance must expose expected state_scope."
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
        "Idempotency-Key" = ("shared-lang-idem-" + $unique)
      }
      $payload = [pscustomobject]@{
        input_text = "hello offer"
        source_channel = "web"
        mode = "detect"
      }
      $first = Invoke-HttpJsonRequest -Method "POST" -Url ("http://127.0.0.1:$port1/v1/language/detect") -Headers $idempotencyHeaders -Body $payload
      $second = Invoke-HttpJsonRequest -Method "POST" -Url ("http://127.0.0.1:$port2/v1/language/detect") -Headers $idempotencyHeaders -Body $payload

      Assert-Equal -Actual $first.status_code -Expected 200 -Message "First shared-state request should be allowed."
      Assert-Equal -Actual $second.status_code -Expected 200 -Message "Second shared-state request should replay across instances."
      Assert-Equal -Actual ([string]$first.content) -Expected ([string]$second.content) -Message "Shared-state idempotency replay should return identical response body across instances."

      $rateHeaders = @{ "X-API-Key" = $script:ApiKey }
      $third = Invoke-HttpJsonRequest -Method "POST" -Url ("http://127.0.0.1:$port2/v1/language/detect") -Headers $rateHeaders -Body $payload
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
