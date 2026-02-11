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
    for ($i = 0; $i -lt 90; $i++) {
      $resp = Invoke-HttpJsonRequest -Method "POST" -Url ($script:BaseUrl + "/v1/language/detect") -Headers $headers -Body $payload
      if ($resp.status_code -eq 429) {
        $hit429 = $true
        break
      }
    }

    Assert-True -Condition $hit429 -Message "Expected 429 rate-limit response was not observed."
  }
}
