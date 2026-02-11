param(
  [string]$InputText = "",
  [string]$SourceChannel = "unknown",
  [string]$InputJsonPath = "",
  [string]$OutFile = "",
  [string]$Mode = "detect",
  [string]$SourceLanguage = "",
  [string]$TargetLanguage = "",
  [switch]$Health,
  [switch]$Serve,
  [string]$ConfigPath = "",
  [string]$HttpHost = "",
  [int]$Port = 0
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$apiRepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..\..")).Path
. (Join-Path $apiRepoRoot "scripts\lib\http_service_common.ps1")

function Get-LanguageDetectionContract {
  $contractPath = Join-Path $PSScriptRoot "contracts/language_detection.contract.json"
  if (-not (Test-Path -Path $contractPath -PathType Leaf)) {
    throw "Missing contract file: $contractPath"
  }
  return Get-Content -Path $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-LanguageTokenMap {
  return [ordered]@{
    de = @("hallo", "danke", "angebot", "kunde", "dienst", "automatisierung", "unternehmen")
    en = @("hello", "thanks", "offer", "client", "service", "automation", "business")
    es = @("hola", "gracias", "oferta", "cliente", "servicio", "automatizacion", "negocio")
    fr = @("bonjour", "merci", "offre", "client", "service", "automatisation", "entreprise")
    pt = @("ola", "obrigado", "oferta", "cliente", "servico", "automacao", "negocio")
  }
}

function Get-LanguageConceptMap {
  return @{
    hello = @{ en = "hello"; es = "hola"; pt = "ola"; fr = "bonjour"; de = "hallo" }
    thanks = @{ en = "thanks"; es = "gracias"; pt = "obrigado"; fr = "merci"; de = "danke" }
    offer = @{ en = "offer"; es = "oferta"; pt = "oferta"; fr = "offre"; de = "angebot" }
    client = @{ en = "client"; es = "cliente"; pt = "cliente"; fr = "client"; de = "kunde" }
    service = @{ en = "service"; es = "servicio"; pt = "servico"; fr = "service"; de = "dienst" }
    automation = @{ en = "automation"; es = "automatizacion"; pt = "automacao"; fr = "automatisation"; de = "automatisierung" }
    business = @{ en = "business"; es = "negocio"; pt = "negocio"; fr = "entreprise"; de = "unternehmen" }
  }
}

function Get-SupportedLanguageCodes {
  return @("de", "en", "es", "fr", "pt")
}

function Get-LanguageApiHealthPayload {
  return [pscustomobject]@{
    service = "language_api"
    status = "ok"
    ready = $true
    mode_default = "detect"
    supported_modes = @("detect", "convert", "detect_and_convert")
    supported_languages = @(Get-SupportedLanguageCodes | Sort-Object)
  }
}

function Normalize-LanguageCode {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $parts = ([string]$Value).Trim().ToLowerInvariant() -split "[-_]"
  if ($parts.Count -eq 0) { return "" }
  return [string]$parts[0]
}

function Normalize-ApiMode {
  param([string]$Value)

  $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { "detect" } else { ([string]$Value).Trim().ToLowerInvariant() }
  if ($normalized -notin @("detect", "convert", "detect_and_convert")) {
    throw "mode must be one of: detect|convert|detect_and_convert"
  }
  return $normalized
}

function Get-TokenScore {
  param(
    [string]$Text,
    [string[]]$Tokens
  )
  $score = 0
  foreach ($token in $Tokens) {
    $pattern = "\b{0}\b" -f [regex]::Escape($token)
    if ($Text -match $pattern) {
      $score++
    }
  }
  return $score
}

function Invoke-LanguageDetection {
  param(
    [string]$Text,
    [string]$Channel
  )

  $normalizedText = if ($null -eq $Text) { "" } else { ([string]$Text).ToLowerInvariant() }
  $channelText = if ([string]::IsNullOrWhiteSpace($Channel)) { "unknown" } else { [string]$Channel }

  if ([string]::IsNullOrWhiteSpace($normalizedText)) {
    return [pscustomobject]@{
      input_text = [string]$Text
      source_channel = $channelText
      detected_language = "und"
      confidence_band = "low"
      reason_codes = @("lang_detect_unknown")
    }
  }

  $tokenMap = Get-LanguageTokenMap
  $scores = New-Object System.Collections.Generic.List[object]
  foreach ($lang in $tokenMap.Keys) {
    $score = Get-TokenScore -Text $normalizedText -Tokens $tokenMap[$lang]
    [void]$scores.Add([pscustomobject]@{
      language = $lang
      score = $score
    })
  }

  $orderedScores = @(
    $scores |
      Sort-Object -Property @{ Expression = "score"; Descending = $true }, @{ Expression = "language"; Descending = $false }
  )

  $top = $orderedScores[0]
  $secondScore = if ($orderedScores.Count -gt 1) { [int]$orderedScores[1].score } else { 0 }
  $topScore = [int]$top.score

  if ($topScore -eq 0) {
    return [pscustomobject]@{
      input_text = [string]$Text
      source_channel = $channelText
      detected_language = "und"
      confidence_band = "low"
      reason_codes = @("lang_detect_unknown")
    }
  }

  if ($topScore -eq $secondScore) {
    return [pscustomobject]@{
      input_text = [string]$Text
      source_channel = $channelText
      detected_language = "und"
      confidence_band = "medium"
      reason_codes = @("lang_detect_ambiguous")
    }
  }

  $confidence = "low"
  $reasonCode = "lang_detect_low_conf"
  if ($topScore -ge 3 -or (($topScore - $secondScore) -ge 2)) {
    $confidence = "high"
    $reasonCode = "lang_detect_high_conf"
  }
  elseif ($topScore -ge 2) {
    $confidence = "medium"
    $reasonCode = "lang_detect_medium_conf"
  }

  return [pscustomobject]@{
    input_text = [string]$Text
    source_channel = $channelText
    detected_language = [string]$top.language
    confidence_band = $confidence
    reason_codes = @($reasonCode)
  }
}

function Get-ConceptLookupByLanguage {
  param([Parameter(Mandatory = $true)][string]$LanguageCode)

  $lookup = @{}
  $conceptMap = Get-LanguageConceptMap
  foreach ($concept in $conceptMap.Keys) {
    $tokensByLanguage = $conceptMap[$concept]
    if ($tokensByLanguage.ContainsKey($LanguageCode)) {
      $token = ([string]$tokensByLanguage[$LanguageCode]).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($token)) {
        $lookup[$token] = $concept
      }
    }
  }

  return $lookup
}

function Get-TargetTokensByConcept {
  param([Parameter(Mandatory = $true)][string]$LanguageCode)

  $lookup = @{}
  $conceptMap = Get-LanguageConceptMap
  foreach ($concept in $conceptMap.Keys) {
    $tokensByLanguage = $conceptMap[$concept]
    if ($tokensByLanguage.ContainsKey($LanguageCode)) {
      $token = ([string]$tokensByLanguage[$LanguageCode]).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($token)) {
        $lookup[$concept] = $token
      }
    }
  }

  return $lookup
}

function Convert-DeterministicTextByConcept {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$SourceLanguage,
    [Parameter(Mandatory = $true)][string]$TargetLanguage
  )

  $sourceLookup = Get-ConceptLookupByLanguage -LanguageCode $SourceLanguage
  $targetLookup = Get-TargetTokensByConcept -LanguageCode $TargetLanguage

  $parts = [regex]::Split([string]$Text, "(\W+)")
  $builder = New-Object System.Text.StringBuilder
  foreach ($part in $parts) {
    if ([string]::IsNullOrEmpty($part)) { continue }

    if ($part -match "^\W+$") {
      [void]$builder.Append($part)
      continue
    }

    $token = $part.ToLowerInvariant()
    if ($sourceLookup.ContainsKey($token)) {
      $concept = [string]$sourceLookup[$token]
      if ($targetLookup.ContainsKey($concept)) {
        [void]$builder.Append([string]$targetLookup[$concept])
      }
      else {
        [void]$builder.Append($token)
      }
    }
    else {
      [void]$builder.Append($part)
    }
  }

  return $builder.ToString()
}

function Invoke-LanguageConversion {
  param(
    [string]$Text,
    [string]$SourceLanguage,
    [string]$TargetLanguage
  )

  $supported = Get-SupportedLanguageCodes
  $source = Normalize-LanguageCode -Value $SourceLanguage
  $target = Normalize-LanguageCode -Value $TargetLanguage

  $reasonCodes = New-Object System.Collections.Generic.List[string]

  if ([string]::IsNullOrWhiteSpace($target)) {
    $target = "en"
    [void]$reasonCodes.Add("lang_convert_fallback")
  }

  if ($supported -notcontains $target) {
    $target = "en"
    [void]$reasonCodes.Add("lang_convert_unsupported_target")
  }

  if ([string]::IsNullOrWhiteSpace($source) -or $source -eq "und" -or ($supported -notcontains $source)) {
    $source = "en"
    [void]$reasonCodes.Add("lang_convert_fallback")
  }

  if ($source -eq $target) {
    [void]$reasonCodes.Add("lang_convert_native")
    return [pscustomobject]@{
      source_language = $source
      target_language = $target
      converted_text = [string]$Text
      conversion_applied = $false
      reason_codes = @($reasonCodes | Select-Object -Unique)
    }
  }

  $convertedText = Convert-DeterministicTextByConcept -Text ([string]$Text) -SourceLanguage $source -TargetLanguage $target
  [void]$reasonCodes.Add("lang_convert_fallback")

  return [pscustomobject]@{
    source_language = $source
    target_language = $target
    converted_text = [string]$convertedText
    conversion_applied = $true
    reason_codes = @($reasonCodes | Select-Object -Unique)
  }
}

function Get-LanguageDetectionInput {
  param(
    [string]$JsonPath,
    [string]$FallbackText,
    [string]$FallbackChannel,
    [string]$FallbackMode,
    [string]$FallbackSourceLanguage,
    [string]$FallbackTargetLanguage
  )

  if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    return [pscustomobject]@{
      input_text = $FallbackText
      source_channel = $FallbackChannel
      mode = $FallbackMode
      source_language = $FallbackSourceLanguage
      target_language = $FallbackTargetLanguage
    }
  }

  if (-not (Test-Path -Path $JsonPath -PathType Leaf)) {
    throw "InputJsonPath not found: $JsonPath"
  }

  $obj = Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  return [pscustomobject]@{
    input_text = if ($obj.PSObject.Properties.Name -contains "input_text") { [string]$obj.input_text } else { $FallbackText }
    source_channel = if ($obj.PSObject.Properties.Name -contains "source_channel") { [string]$obj.source_channel } else { $FallbackChannel }
    mode = if ($obj.PSObject.Properties.Name -contains "mode") { [string]$obj.mode } else { $FallbackMode }
    source_language = if ($obj.PSObject.Properties.Name -contains "source_language") { [string]$obj.source_language } else { $FallbackSourceLanguage }
    target_language = if ($obj.PSObject.Properties.Name -contains "target_language") { [string]$obj.target_language } else { $FallbackTargetLanguage }
  }
}

function Invoke-LanguageApi {
  param(
    [string]$Text,
    [string]$Channel,
    [string]$Mode,
    [string]$SourceLanguage,
    [string]$TargetLanguage
  )

  $resolvedMode = Normalize-ApiMode -Value $Mode
  $detected = Invoke-LanguageDetection -Text $Text -Channel $Channel

  $reasonCodes = New-Object System.Collections.Generic.List[string]
  foreach ($rc in @($detected.reason_codes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonCodes.Add([string]$rc)
    }
  }

  $resolvedSourceLanguage = Normalize-LanguageCode -Value $SourceLanguage
  if ([string]::IsNullOrWhiteSpace($resolvedSourceLanguage)) {
    $resolvedSourceLanguage = [string]$detected.detected_language
  }

  $resolvedTargetLanguage = Normalize-LanguageCode -Value $TargetLanguage
  $convertedText = $null
  $conversionApplied = $false

  if ($resolvedMode -in @("convert", "detect_and_convert")) {
    if ($resolvedMode -eq "detect_and_convert") {
      $resolvedSourceLanguage = [string]$detected.detected_language
    }

    $conversion = Invoke-LanguageConversion -Text $Text -SourceLanguage $resolvedSourceLanguage -TargetLanguage $resolvedTargetLanguage
    $resolvedSourceLanguage = [string]$conversion.source_language
    $resolvedTargetLanguage = [string]$conversion.target_language
    $convertedText = [string]$conversion.converted_text
    $conversionApplied = [bool]$conversion.conversion_applied

    foreach ($rc in @($conversion.reason_codes)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
        [void]$reasonCodes.Add([string]$rc)
      }
    }
  }
  else {
    if ([string]::IsNullOrWhiteSpace($resolvedSourceLanguage)) {
      $resolvedSourceLanguage = [string]$detected.detected_language
    }
    $resolvedTargetLanguage = ""
  }

  return [pscustomobject]@{
    input_text = [string]$Text
    source_channel = if ([string]::IsNullOrWhiteSpace($Channel)) { "unknown" } else { [string]$Channel }
    mode = $resolvedMode
    source_language = if ([string]::IsNullOrWhiteSpace($resolvedSourceLanguage)) { "und" } else { $resolvedSourceLanguage }
    target_language = $resolvedTargetLanguage
    detected_language = [string]$detected.detected_language
    confidence_band = [string]$detected.confidence_band
    converted_text = $convertedText
    conversion_applied = $conversionApplied
    reason_codes = @($reasonCodes | Select-Object -Unique)
  }
}

function Get-LanguageApiRuntimeConfig {
  $configObject = $null
  $resolvedConfigPath = $ConfigPath
  if ([string]::IsNullOrWhiteSpace($resolvedConfigPath)) {
    $resolvedConfigPath = Join-Path $apiRepoRoot "apps\api\config.example.json"
  }

  if (-not [string]::IsNullOrWhiteSpace($resolvedConfigPath) -and (Test-Path -Path $resolvedConfigPath -PathType Leaf)) {
    $configObject = Get-Content -Path $resolvedConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
  }

  $defaultLedger = Join-Path $apiRepoRoot "apps\api\artifacts\usage\language_api_usage.jsonl"
  $runtime = Get-ApiHttpConfig `
    -ServiceName "language_api" `
    -ConfigObject $configObject `
    -DefaultPort 8081 `
    -DefaultUsageLedgerPath $defaultLedger `
    -DefaultSchemaVersion "language-api-http-v1"

  if (-not [string]::IsNullOrWhiteSpace($HttpHost)) {
    $runtime.host = ([string]$HttpHost).Trim()
  }
  if ($Port -gt 0) {
    $runtime.port = $Port
  }

  $runtime | Add-Member -NotePropertyName max_input_chars -NotePropertyValue 10000 -Force
  if ($null -ne $configObject -and $configObject.PSObject.Properties.Name -contains "http") {
    $http = $configObject.http
    if ($http.PSObject.Properties.Name -contains "max_input_chars") {
      $tmpMaxChars = 0
      if ([int]::TryParse([string]$http.max_input_chars, [ref]$tmpMaxChars) -and $tmpMaxChars -gt 0) {
        $runtime.max_input_chars = $tmpMaxChars
      }
    }
  }

  return $runtime
}

function New-LanguageApiHttpEnvelope {
  param(
    [string]$RequestId,
    [string]$SchemaVersion,
    [string]$ProviderUsed,
    [object]$Result
  )

  return [pscustomobject]@{
    request_id = $RequestId
    schema_version = $SchemaVersion
    provider_used = $ProviderUsed
    result = $Result
  }
}

function Start-LanguageApiHttpService {
  param([Parameter(Mandatory = $true)][object]$RuntimeConfig)

  $prefix = "http://{0}:{1}/" -f $RuntimeConfig.host, $RuntimeConfig.port
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($prefix)
  $listener.Start()
  Write-Host ("LANGUAGE_API_HTTP_LISTENING={0}" -f $prefix)

  try {
    while ($listener.IsListening) {
      $context = $listener.GetContext()
      Handle-LanguageApiHttpRequest -Context $context -RuntimeConfig $RuntimeConfig
    }
  }
  finally {
    if ($listener.IsListening) {
      $listener.Stop()
    }
    $listener.Close()
  }
}

function Handle-LanguageApiHttpRequest {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
    [Parameter(Mandatory = $true)][object]$RuntimeConfig
  )

  $request = $Context.Request
  $response = $Context.Response
  $requestId = New-ApiRequestId
  $method = ([string]$request.HttpMethod).ToUpperInvariant()
  $path = [string]$request.Url.AbsolutePath
  if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }
  if ($path.Length -gt 1 -and $path.EndsWith("/")) { $path = $path.TrimEnd("/") }
  if ([string]::IsNullOrWhiteSpace($path)) { $path = "/" }
  $instance = "{0} {1}" -f $method, $path
  $endpoint = $instance

  $startedAt = Get-ApiUtcNow
  $statusCode = 500
  $keyId = "anonymous"
  $requestBytes = 0
  $responseBytes = 0
  $idempotencyReplay = $false
  $billableUnits = 0

  try {
    $response.AddHeader("X-Request-Id", $requestId)

    if ($method -eq "GET" -and ($path -eq "/health" -or $path -eq "/ready")) {
      $healthPayload = Get-LanguageApiHealthPayload
      $body = [pscustomobject]@{
        request_id = $requestId
        schema_version = $RuntimeConfig.schema_version
        provider_used = "local"
        result = $healthPayload
      }
      $json = $body | ConvertTo-Json -Depth 20 -Compress
      $statusCode = 200
      $responseBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
      Write-HttpRawResponse -Response $response -StatusCode 200 -Body $json -ContentType "application/json"
      return
    }

    $providedKey = [string]$request.Headers["X-API-Key"]
    $principal = Get-ApiKeyPrincipal -HttpConfig $RuntimeConfig -ProvidedKey $providedKey
    if ($null -eq $principal) {
      $statusCode = 401
      Write-HttpProblemResponse -Response $response -Status 401 -Title "Unauthorized" -Detail "Missing or invalid X-API-Key." -Instance $instance -RequestId $requestId
      return
    }
    $keyId = [string]$principal.key_id

    $rate = Test-ApiRequestAllowedByRateLimit `
      -ServiceName $RuntimeConfig.service_name `
      -KeyId $keyId `
      -Endpoint $endpoint `
      -WindowSeconds ([int]$RuntimeConfig.rate_limit_window_seconds) `
      -MaxRequests ([int]$RuntimeConfig.rate_limit_max_requests)
    if (-not [bool]$rate.allowed) {
      $response.AddHeader("Retry-After", [string]([int]$RuntimeConfig.rate_limit_window_seconds))
      $statusCode = 429
      Write-HttpProblemResponse -Response $response -Status 429 -Title "Too Many Requests" -Detail "Rate limit exceeded for this API key and endpoint window." -Instance $instance -RequestId $requestId
      return
    }

    if ($method -eq "GET" -and $path -eq "/v1/admin/usage") {
      if ([string]$principal.role -ne "admin") {
        $statusCode = 403
        Write-HttpProblemResponse -Response $response -Status 403 -Title "Forbidden" -Detail "Admin role is required for usage export." -Instance $instance -RequestId $requestId
        return
      }

      $query = Get-HttpQueryParameters -Request $request
      $fromUtc = [datetime]::MinValue
      $toUtc = [datetime]::MinValue
      $hasFrom = $false
      $hasTo = $false
      if ($query.ContainsKey("from") -and -not [string]::IsNullOrWhiteSpace([string]$query["from"])) {
        if (-not [datetime]::TryParse([string]$query["from"], [ref]$fromUtc)) {
          $statusCode = 400
          Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "Query parameter 'from' must be ISO8601 datetime." -Instance $instance -RequestId $requestId
          return
        }
        $hasFrom = $true
      }
      if ($query.ContainsKey("to") -and -not [string]::IsNullOrWhiteSpace([string]$query["to"])) {
        if (-not [datetime]::TryParse([string]$query["to"], [ref]$toUtc)) {
          $statusCode = 400
          Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "Query parameter 'to' must be ISO8601 datetime." -Instance $instance -RequestId $requestId
          return
        }
        $hasTo = $true
      }

      $usageRows = if ($hasFrom -and $hasTo) {
        Get-UsageLedgerEntries -LedgerPath ([string]$RuntimeConfig.usage_ledger_path) -FromUtc $fromUtc -ToUtc $toUtc
      }
      elseif ($hasFrom) {
        Get-UsageLedgerEntries -LedgerPath ([string]$RuntimeConfig.usage_ledger_path) -FromUtc $fromUtc
      }
      elseif ($hasTo) {
        Get-UsageLedgerEntries -LedgerPath ([string]$RuntimeConfig.usage_ledger_path) -ToUtc $toUtc
      }
      else {
        Get-UsageLedgerEntries -LedgerPath ([string]$RuntimeConfig.usage_ledger_path)
      }

      $payload = [pscustomobject]@{
        request_id = $requestId
        schema_version = $RuntimeConfig.schema_version
        provider_used = "local"
        result = [pscustomobject]@{
          count = @($usageRows).Count
          rows = @($usageRows)
        }
      }
      $json = $payload | ConvertTo-Json -Depth 20 -Compress
      $statusCode = 200
      $responseBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
      Write-HttpRawResponse -Response $response -StatusCode 200 -Body $json -ContentType "application/json"
      return
    }

    if ($method -ne "POST") {
      $statusCode = 405
      Write-HttpProblemResponse -Response $response -Status 405 -Title "Method Not Allowed" -Detail "Only POST is supported for this endpoint." -Instance $instance -RequestId $requestId
      return
    }

    if ($path -notin @("/v1/language/detect", "/v1/language/translate")) {
      $statusCode = 404
      Write-HttpProblemResponse -Response $response -Status 404 -Title "Not Found" -Detail "Endpoint not found." -Instance $instance -RequestId $requestId
      return
    }

    $rawBody = Read-HttpRequestBodyText -Request $request -MaxBytes ([int]$RuntimeConfig.max_request_bytes)
    $requestBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$rawBody)
    if ([string]::IsNullOrWhiteSpace($rawBody)) {
      $statusCode = 400
      Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "Request body must be valid JSON and non-empty." -Instance $instance -RequestId $requestId
      return
    }

    $idempotencyKey = [string]$request.Headers["Idempotency-Key"]
    $bodyHash = Get-Sha256Hex -Text $rawBody
    if (-not [string]::IsNullOrWhiteSpace($idempotencyKey)) {
      $decision = Get-IdempotencyReplayDecision `
        -ServiceName $RuntimeConfig.service_name `
        -KeyId $keyId `
        -Endpoint $endpoint `
        -IdempotencyKey $idempotencyKey `
        -BodyHash $bodyHash `
        -TtlSeconds ([int]$RuntimeConfig.idempotency_ttl_seconds)
      if ([bool]$decision.conflict) {
        $statusCode = 409
        Write-HttpProblemResponse -Response $response -Status 409 -Title "Conflict" -Detail "Idempotency-Key was reused with a different request body." -Instance $instance -RequestId $requestId
        return
      }
      if ([bool]$decision.replay) {
        $response.AddHeader("Idempotency-Replayed", "true")
        $statusCode = [int]$decision.entry.status_code
        $responseBytes = [System.Text.Encoding]::UTF8.GetByteCount([string]$decision.entry.json_body)
        $idempotencyReplay = $true
        Write-HttpRawResponse -Response $response -StatusCode $statusCode -Body ([string]$decision.entry.json_body) -ContentType ([string]$decision.entry.content_type)
        return
      }
    }

    $body = ConvertFrom-JsonSafe -Raw $rawBody -Label "Language API request body"

    $inputText = if ($body.PSObject.Properties.Name -contains "input_text") { [string]$body.input_text } else { "" }
    $sourceChannel = if ($body.PSObject.Properties.Name -contains "source_channel") { [string]$body.source_channel } else { "" }
    $sourceLanguage = if ($body.PSObject.Properties.Name -contains "source_language") { [string]$body.source_language } else { "" }
    $targetLanguage = if ($body.PSObject.Properties.Name -contains "target_language") { [string]$body.target_language } else { "" }
    $mode = if ($path -eq "/v1/language/translate") { "convert" } else { "detect" }
    if ($body.PSObject.Properties.Name -contains "mode" -and -not [string]::IsNullOrWhiteSpace([string]$body.mode)) {
      $mode = [string]$body.mode
    }

    if ([string]::IsNullOrWhiteSpace($inputText)) {
      $statusCode = 400
      Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "input_text is required." -Instance $instance -RequestId $requestId
      return
    }
    if ($inputText.Length -gt [int]$RuntimeConfig.max_input_chars) {
      $statusCode = 413
      Write-HttpProblemResponse -Response $response -Status 413 -Title "Payload Too Large" -Detail "input_text exceeds max_input_chars limit." -Instance $instance -RequestId $requestId
      return
    }
    if ([string]::IsNullOrWhiteSpace($sourceChannel)) {
      $statusCode = 400
      Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "source_channel is required." -Instance $instance -RequestId $requestId
      return
    }

    $supportedLanguages = @(Get-SupportedLanguageCodes)
    if (-not [string]::IsNullOrWhiteSpace($sourceLanguage)) {
      $normalizedSource = Normalize-LanguageCode -Value $sourceLanguage
      if ($normalizedSource -ne "und" -and ($supportedLanguages -notcontains $normalizedSource)) {
        $statusCode = 400
        Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "source_language must be one of: $($supportedLanguages -join ', '), or omitted." -Instance $instance -RequestId $requestId
        return
      }
    }

    if ($path -eq "/v1/language/translate") {
      if ([string]::IsNullOrWhiteSpace($targetLanguage)) {
        $statusCode = 400
        Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "target_language is required for /v1/language/translate." -Instance $instance -RequestId $requestId
        return
      }
    }
    if (-not [string]::IsNullOrWhiteSpace($targetLanguage)) {
      $normalizedTarget = Normalize-LanguageCode -Value $targetLanguage
      if ($supportedLanguages -notcontains $normalizedTarget) {
        $statusCode = 400
        Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail "target_language must be one of: $($supportedLanguages -join ', ')." -Instance $instance -RequestId $requestId
        return
      }
      $targetLanguage = $normalizedTarget
    }

    $resultStarted = Get-ApiUtcNow
    $result = Invoke-LanguageApi `
      -Text $inputText `
      -Channel $sourceChannel `
      -Mode $mode `
      -SourceLanguage $sourceLanguage `
      -TargetLanguage $targetLanguage
    $resultElapsed = [int]((Get-ApiUtcNow) - $resultStarted).TotalMilliseconds
    if ($resultElapsed -gt [int]$RuntimeConfig.request_timeout_ms) {
      $statusCode = 504
      Write-HttpProblemResponse -Response $response -Status 504 -Title "Gateway Timeout" -Detail "Request processing exceeded timeout window." -Instance $instance -RequestId $requestId
      return
    }

    $payload = New-LanguageApiHttpEnvelope -RequestId $requestId -SchemaVersion ([string]$RuntimeConfig.schema_version) -ProviderUsed "local" -Result $result
    $json = $payload | ConvertTo-Json -Depth 20 -Compress
    $statusCode = 200
    $responseBytes = [System.Text.Encoding]::UTF8.GetByteCount($json)
    Write-HttpRawResponse -Response $response -StatusCode 200 -Body $json -ContentType "application/json"

    if (-not [string]::IsNullOrWhiteSpace($idempotencyKey)) {
      Save-IdempotencyResponse `
        -ServiceName $RuntimeConfig.service_name `
        -KeyId $keyId `
        -Endpoint $endpoint `
        -IdempotencyKey $idempotencyKey `
        -BodyHash $bodyHash `
        -StatusCode 200 `
        -ContentType "application/json" `
        -JsonBody $json
    }

    $billableUnits = [Math]::Max(1, [int][Math]::Ceiling($inputText.Length / 500.0))
  }
  catch {
    if ($statusCode -lt 400) {
      $statusCode = 500
      Write-HttpProblemResponse -Response $response -Status 500 -Title "Internal Server Error" -Detail $_.Exception.Message -Instance $instance -RequestId $requestId
    }
  }
  finally {
    $latencyMs = [int]((Get-ApiUtcNow) - $startedAt).TotalMilliseconds
    Add-UsageLedgerEntry `
      -LedgerPath ([string]$RuntimeConfig.usage_ledger_path) `
      -ServiceName ([string]$RuntimeConfig.service_name) `
      -RequestId $requestId `
      -KeyId $keyId `
      -Endpoint $endpoint `
      -StatusCode $statusCode `
      -LatencyMs $latencyMs `
      -BillableUnits $billableUnits `
      -RequestBytes $requestBytes `
      -ResponseBytes $responseBytes `
      -IdempotencyReplay $idempotencyReplay
    $response.Close()
  }
}

$isDotSourced = $MyInvocation.InvocationName -eq "."
if (-not $isDotSourced) {
  if ($Serve) {
    $runtimeConfig = Get-LanguageApiRuntimeConfig
    Start-LanguageApiHttpService -RuntimeConfig $runtimeConfig
    exit 0
  }

  if ($Health) {
    $healthPayload = Get-LanguageApiHealthPayload
    $healthJson = $healthPayload | ConvertTo-Json -Depth 20
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
      Write-Output $healthJson
    }
    else {
      $healthJson | Set-Content -Path $OutFile -Encoding UTF8
    }
    exit 0
  }

  $input = Get-LanguageDetectionInput `
    -JsonPath $InputJsonPath `
    -FallbackText $InputText `
    -FallbackChannel $SourceChannel `
    -FallbackMode $Mode `
    -FallbackSourceLanguage $SourceLanguage `
    -FallbackTargetLanguage $TargetLanguage

  $result = Invoke-LanguageApi `
    -Text $input.input_text `
    -Channel $input.source_channel `
    -Mode $input.mode `
    -SourceLanguage $input.source_language `
    -TargetLanguage $input.target_language

  $json = $result | ConvertTo-Json -Depth 20
  if ([string]::IsNullOrWhiteSpace($OutFile)) {
    Write-Output $json
  }
  else {
    $json | Set-Content -Path $OutFile -Encoding UTF8
  }
}
