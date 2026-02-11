param(
  [string]$ConfigPath = "",
  [string]$TaskPath = "",
  [string]$OutputPath = "",
  [switch]$Health,
  [switch]$Serve,
  [string]$HttpHost = "",
  [int]$Port = 0
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$scriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$appRoot = (Resolve-Path (Join-Path $scriptRoot "..")).Path
$repoRoot = (Resolve-Path (Join-Path $appRoot "..\\..")).Path

. (Join-Path $scriptRoot "lib\task_router.ps1")
. (Join-Path $scriptRoot "lib\telemetry.ps1")
. (Join-Path $repoRoot "scripts\lib\http_service_common.ps1")

function Read-JsonFile {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][string]$Label
  )

  if (-not (Test-Path -Path $Path -PathType Leaf)) {
    throw "$Label not found: $Path"
  }

  try {
    return (Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json)
  }
  catch {
    throw "$Label is not valid JSON: $($_.Exception.Message)"
  }
}

function Parse-StrictBool {
  param(
    [object]$Value,
    [bool]$DefaultValue,
    [string]$FieldName
  )

  if ($null -eq $Value) { return $DefaultValue }
  if ($Value -is [bool]) { return [bool]$Value }

  $s = ([string]$Value).Trim().ToLowerInvariant()
  switch ($s) {
    "true" { return $true }
    "false" { return $false }
    default { throw "Config field '$FieldName' must be boolean true/false." }
  }
}

function Normalize-Config {
  param([Parameter(Mandatory = $true)][object]$RawConfig)

  $providerMode = "mock"
  if ($RawConfig.PSObject.Properties.Name -contains "provider_mode" -and -not [string]::IsNullOrWhiteSpace([string]$RawConfig.provider_mode)) {
    $providerMode = ([string]$RawConfig.provider_mode).Trim().ToLowerInvariant()
  }

  if ($providerMode -notin @("mock", "http")) {
    throw "Config field 'provider_mode' must be one of: mock|http."
  }

  return [pscustomobject]@{
    enable_revenue_automation = Parse-StrictBool -Value $RawConfig.enable_revenue_automation -DefaultValue $false -FieldName "enable_revenue_automation"
    provider_mode = $providerMode
    emit_telemetry = Parse-StrictBool -Value $RawConfig.emit_telemetry -DefaultValue $true -FieldName "emit_telemetry"
    safe_mode = Parse-StrictBool -Value $RawConfig.safe_mode -DefaultValue $true -FieldName "safe_mode"
    dry_run = Parse-StrictBool -Value $RawConfig.dry_run -DefaultValue $true -FieldName "dry_run"
  }
}

function Get-RevenueAutomationHealthPayload {
  return [pscustomobject]@{
    service = "revenue_automation"
    status = "ok"
    ready = $true
    provider_mode_default = "mock"
    supported_provider_modes = @("http", "mock")
    supports_safe_mode = $true
    supports_dry_run = $true
  }
}

function Get-TaskValidationErrors {
  param([Parameter(Mandatory = $true)][object]$Task)

  $errors = New-Object System.Collections.Generic.List[string]
  $names = @($Task.PSObject.Properties.Name)

  if ($names -notcontains "task_id" -or [string]::IsNullOrWhiteSpace([string]$Task.task_id)) {
    [void]$errors.Add("task_id is required and must be a non-empty string.")
  }

  if ($names -notcontains "task_type" -or [string]::IsNullOrWhiteSpace([string]$Task.task_type)) {
    [void]$errors.Add("task_type is required and must be a non-empty string.")
  }

  if ($names -notcontains "payload") {
    [void]$errors.Add("payload is required and must be an object.")
  }
  else {
    $payload = $Task.payload
    $isObjectLike = ($payload -is [System.Collections.IDictionary]) -or ($payload -is [pscustomobject])
    if (-not $isObjectLike) {
      [void]$errors.Add("payload must be an object.")
    }
  }

  if ($names -notcontains "created_at_utc" -or [string]::IsNullOrWhiteSpace([string]$Task.created_at_utc)) {
    [void]$errors.Add("created_at_utc is required and must be ISO8601.")
  }
  else {
    $tmpDate = [datetime]::MinValue
    if (-not [datetime]::TryParse([string]$Task.created_at_utc, [ref]$tmpDate)) {
      [void]$errors.Add("created_at_utc must be parseable as ISO8601 datetime.")
    }
  }

  return @($errors.ToArray())
}

function Convert-ToRevenueResult {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$RouteResult,
    [Parameter(Mandatory = $true)][datetime]$StartedAt,
    [Parameter(Mandatory = $true)][datetime]$FinishedAt
  )

  $taskId = if ($Task.PSObject.Properties.Name -contains "task_id") { [string]$Task.task_id } else { "" }
  $durationMs = [int](($FinishedAt - $StartedAt).TotalMilliseconds)

  return [pscustomobject]@{
    task_id = $taskId
    status = [string]$RouteResult.status
    provider_used = [string]$RouteResult.provider_used
    started_at_utc = $StartedAt.ToUniversalTime().ToString("o")
    finished_at_utc = $FinishedAt.ToUniversalTime().ToString("o")
    duration_ms = $durationMs
    error = if ([string]::IsNullOrWhiteSpace([string]$RouteResult.error)) { $null } else { [string]$RouteResult.error }
    artifacts = @($RouteResult.artifacts | ForEach-Object { [string]$_ })
    reason_codes = if ($RouteResult.PSObject.Properties.Name -contains "reason_codes") { @($RouteResult.reason_codes | ForEach-Object { [string]$_ }) } else { @() }
    policy = if ($RouteResult.PSObject.Properties.Name -contains "policy") { $RouteResult.policy } else { $null }
    route = if ($RouteResult.PSObject.Properties.Name -contains "route") { $RouteResult.route } else { $null }
    offer = if ($RouteResult.PSObject.Properties.Name -contains "offer") { $RouteResult.offer } else { $null }
    proposal = if ($RouteResult.PSObject.Properties.Name -contains "proposal") { $RouteResult.proposal } else { $null }
    telemetry_event_stub = if ($RouteResult.PSObject.Properties.Name -contains "telemetry_event_stub") { $RouteResult.telemetry_event_stub } else { $null }
    telemetry_event = if ($RouteResult.PSObject.Properties.Name -contains "telemetry_event") { $RouteResult.telemetry_event } else { $null }
    campaign_packet = if ($RouteResult.PSObject.Properties.Name -contains "campaign_packet") { $RouteResult.campaign_packet } else { $null }
    dispatch_plan = if ($RouteResult.PSObject.Properties.Name -contains "dispatch_plan") { $RouteResult.dispatch_plan } else { $null }
    delivery_manifest = if ($RouteResult.PSObject.Properties.Name -contains "delivery_manifest") { $RouteResult.delivery_manifest } else { $null }
    sender_envelope = if ($RouteResult.PSObject.Properties.Name -contains "sender_envelope") { $RouteResult.sender_envelope } else { $null }
    adapter_request = if ($RouteResult.PSObject.Properties.Name -contains "adapter_request") { $RouteResult.adapter_request } else { $null }
    dispatch_receipt = if ($RouteResult.PSObject.Properties.Name -contains "dispatch_receipt") { $RouteResult.dispatch_receipt } else { $null }
    audit_record = if ($RouteResult.PSObject.Properties.Name -contains "audit_record") { $RouteResult.audit_record } else { $null }
    evidence_envelope = if ($RouteResult.PSObject.Properties.Name -contains "evidence_envelope") { $RouteResult.evidence_envelope } else { $null }
    retention_manifest = if ($RouteResult.PSObject.Properties.Name -contains "retention_manifest") { $RouteResult.retention_manifest } else { $null }
    immutability_receipt = if ($RouteResult.PSObject.Properties.Name -contains "immutability_receipt") { $RouteResult.immutability_receipt } else { $null }
    ledger_attestation = if ($RouteResult.PSObject.Properties.Name -contains "ledger_attestation") { $RouteResult.ledger_attestation } else { $null }
    proof_verification = if ($RouteResult.PSObject.Properties.Name -contains "proof_verification") { $RouteResult.proof_verification } else { $null }
    anchor_record = if ($RouteResult.PSObject.Properties.Name -contains "anchor_record") { $RouteResult.anchor_record } else { $null }
    index_receipt = if ($RouteResult.PSObject.Properties.Name -contains "index_receipt") { $RouteResult.index_receipt } else { $null }
    archive_manifest = if ($RouteResult.PSObject.Properties.Name -contains "archive_manifest") { $RouteResult.archive_manifest } else { $null }
    notarization_ticket = if ($RouteResult.PSObject.Properties.Name -contains "notarization_ticket") { $RouteResult.notarization_ticket } else { $null }
  }
}

function Invoke-RevenueExecution {
  param(
    [Parameter(Mandatory = $true)][object]$Config,
    [Parameter(Mandatory = $true)][object]$Task
  )

  $taskType = if ($Task.PSObject.Properties.Name -contains "task_type") { [string]$Task.task_type } else { "" }
  $started = Get-Date

  $routeResult = $null
  $validationErrors = @(Get-TaskValidationErrors -Task $Task)
  if ($validationErrors.Count -gt 0) {
    $routeResult = [pscustomobject]@{
      status = "FAILED"
      provider_used = "none"
      error = ($validationErrors -join " ")
      artifacts = @()
    }
  }
  else {
    $routeResult = Invoke-RevenueTaskRoute -Task $Task -Config $Config
  }

  $finished = Get-Date
  $result = Convert-ToRevenueResult -Task $Task -RouteResult $routeResult -StartedAt $started -FinishedAt $finished

  if ($Config.emit_telemetry) {
    $telemetryPath = Join-Path $appRoot "artifacts\telemetry\revenue_events.jsonl"
    Write-RevenueTelemetryEvent `
      -TelemetryPath $telemetryPath `
      -TaskId $result.task_id `
      -TaskType $taskType `
      -Status $result.status `
      -ProviderMode $Config.provider_mode `
      -DurationMs $result.duration_ms
  }

  return $result
}

function Get-RevenueApiRuntimeConfig {
  param([object]$ConfigRaw)

  $defaultLedger = Join-Path $appRoot "artifacts\usage\revenue_api_usage.jsonl"
  $runtime = Get-ApiHttpConfig `
    -ServiceName "marketing_revenue_api" `
    -ConfigObject $ConfigRaw `
    -DefaultPort 8082 `
    -DefaultUsageLedgerPath $defaultLedger `
    -DefaultSchemaVersion "marketing-revenue-api-http-v1"

  if (-not [string]::IsNullOrWhiteSpace($HttpHost)) {
    $runtime.host = ([string]$HttpHost).Trim()
  }
  if ($Port -gt 0) {
    $runtime.port = $Port
  }

  return $runtime
}

function Start-RevenueApiHttpService {
  param(
    [Parameter(Mandatory = $true)][object]$RuntimeConfig,
    [Parameter(Mandatory = $true)][object]$Config
  )

  $prefix = "http://{0}:{1}/" -f $RuntimeConfig.host, $RuntimeConfig.port
  $listener = New-Object System.Net.HttpListener
  $listener.Prefixes.Add($prefix)
  $listener.Start()
  Write-Host ("REVENUE_API_HTTP_LISTENING={0}" -f $prefix)

  try {
    while ($listener.IsListening) {
      $context = $listener.GetContext()
      Handle-RevenueApiHttpRequest -Context $context -RuntimeConfig $RuntimeConfig -Config $Config
    }
  }
  finally {
    if ($listener.IsListening) {
      $listener.Stop()
    }
    $listener.Close()
  }
}

function Handle-RevenueApiHttpRequest {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerContext]$Context,
    [Parameter(Mandatory = $true)][object]$RuntimeConfig,
    [Parameter(Mandatory = $true)][object]$Config
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
      $healthPayload = Get-RevenueAutomationHealthPayload
      $healthPayload | Add-Member -NotePropertyName enable_revenue_automation -NotePropertyValue ([bool]$Config.enable_revenue_automation) -Force
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

      $rows = if ($hasFrom -and $hasTo) {
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
          count = @($rows).Count
          rows = @($rows)
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

    if ($path -notin @("/v1/marketing/task/execute", "/v1/revenue/task/execute")) {
      $statusCode = 404
      Write-HttpProblemResponse -Response $response -Status 404 -Title "Not Found" -Detail "Endpoint not found." -Instance $instance -RequestId $requestId
      return
    }

    if (-not [bool]$Config.enable_revenue_automation) {
      $statusCode = 503
      Write-HttpProblemResponse -Response $response -Status 503 -Title "Service Unavailable" -Detail "Revenue automation is disabled by configuration." -Instance $instance -RequestId $requestId
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

    $task = ConvertFrom-JsonSafe -Raw $rawBody -Label "Revenue API request body"
    $validationErrors = @(Get-TaskValidationErrors -Task $task)
    if ($validationErrors.Count -gt 0) {
      $statusCode = 400
      Write-HttpProblemResponse -Response $response -Status 400 -Title "Bad Request" -Detail ($validationErrors -join " ") -Instance $instance -RequestId $requestId
      return
    }

    $execStarted = Get-ApiUtcNow
    $result = Invoke-RevenueExecution -Config $Config -Task $task
    $elapsed = [int]((Get-ApiUtcNow) - $execStarted).TotalMilliseconds
    if ($elapsed -gt [int]$RuntimeConfig.request_timeout_ms) {
      $statusCode = 504
      Write-HttpProblemResponse -Response $response -Status 504 -Title "Gateway Timeout" -Detail "Request processing exceeded timeout window." -Instance $instance -RequestId $requestId
      return
    }

    $providerUsed = if ([string]::IsNullOrWhiteSpace([string]$result.provider_used)) { "none" } else { [string]$result.provider_used }
    $payload = [pscustomobject]@{
      request_id = $requestId
      schema_version = $RuntimeConfig.schema_version
      provider_used = $providerUsed
      result = $result
    }
    $json = $payload | ConvertTo-Json -Depth 40 -Compress
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

    $billableUnits = if ([string]$result.status -eq "SUCCESS") { 1 } else { 0 }
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

if ($Health -and -not $Serve) {
  $healthPayload = Get-RevenueAutomationHealthPayload
  $healthJson = $healthPayload | ConvertTo-Json -Depth 20
  if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
    $outDir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
      New-Item -ItemType Directory -Path $outDir -Force | Out-Null
    }
    Set-Content -Path $OutputPath -Value $healthJson -Encoding UTF8
  }
  else {
    Write-Output $healthJson
  }
  exit 0
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $appRoot "config.example.json"
}

try {
  $configRaw = Read-JsonFile -Path $ConfigPath -Label "Config"
  $config = Normalize-Config -RawConfig $configRaw
}
catch {
  Write-Error $_.Exception.Message
  exit 2
}

if ($Serve) {
  $runtimeConfig = Get-RevenueApiRuntimeConfig -ConfigRaw $configRaw
  Start-RevenueApiHttpService -RuntimeConfig $runtimeConfig -Config $config
  exit 0
}

if (-not $config.enable_revenue_automation) {
  Write-Host "Revenue automation disabled (enable_revenue_automation=false). Exiting with no side effects."
  exit 0
}

if ([string]::IsNullOrWhiteSpace($TaskPath)) {
  Write-Error "TaskPath is required when enable_revenue_automation=true."
  exit 2
}

$task = $null
try {
  $task = Read-JsonFile -Path $TaskPath -Label "Task envelope"
}
catch {
  Write-Error $_.Exception.Message
  exit 2
}

$result = Invoke-RevenueExecution -Config $config -Task $task
$json = $result | ConvertTo-Json -Depth 40 -Compress

if (-not [string]::IsNullOrWhiteSpace($OutputPath)) {
  $outDir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  Set-Content -Path $OutputPath -Value $json -Encoding UTF8
}

Write-Output $json

if ($result.status -eq "FAILED") { exit 1 }
exit 0
