function Get-GrowthAutopilotAdapterRegistry {
  # Returns a deterministic registry mapping channel -> adapter name.
  return @{
    "x" = "x"
    "discourse" = "discourse"
    # reddit remains draft-only by allowlist policy unless explicitly changed.
    "reddit" = "reddit"
  }
}

function Get-GrowthAutopilotPolicySnapshot {
  param([Parameter(Mandatory = $true)][object]$Policy)
  return [pscustomobject]@{
    known = [bool]$Policy.known
    channel = [string]$Policy.channel
    autopost_allowed = [bool]$Policy.autopost_allowed
    requires_human_review = [bool]$Policy.requires_human_review
    posting_rate_limit_per_day = [int]$Policy.posting_rate_limit_per_day
    policy_confidence = [double]$Policy.policy_confidence
    required_disclosures = @($Policy.required_disclosures | ForEach-Object { [string]$_ })
  }
}

function Split-GrowthCsv {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
  return @(
    $Value.Split(",") |
      ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
}

function New-GrowthAutopilotAdapterRequest {
  param(
    [Parameter(Mandatory = $true)][string]$CampaignId,
    [Parameter(Mandatory = $true)][string]$RunSignature,
    [Parameter(Mandatory = $true)][string]$Channel,
    [Parameter(Mandatory = $true)][string]$AdapterName,
    [Parameter(Mandatory = $true)][string]$Transport,
    [Parameter(Mandatory = $true)][object]$ActionRecord,
    [Parameter(Mandatory = $true)][object]$PolicySnapshot
  )

  $requestId = "req-{0}" -f (Get-StableHash -Value ("{0}|{1}|{2}|{3}|{4}" -f $CampaignId, $RunSignature, $Channel, $AdapterName, $ActionRecord.plan_id)).Substring(0, 16)

  return [pscustomobject]@{
    request_id = $requestId
    campaign_id = $CampaignId
    run_signature = $RunSignature
    channel = $Channel
    adapter = $AdapterName
    transport = $Transport
    plan_id = [string]$ActionRecord.plan_id
    payload = [pscustomobject]@{
      thread_or_target = [string]$ActionRecord.thread_or_target
      ad_copy = [string]$ActionRecord.ad_copy
      reply_template = [string]$ActionRecord.reply_template
      tracked_url = [string]$ActionRecord.tracked_url
      disclosure = [string]$ActionRecord.disclosure
      required_disclosures = @($ActionRecord.required_disclosures | ForEach-Object { [string]$_ })
    }
    policy_snapshot = $PolicySnapshot
  }
}

function Invoke-GrowthAutopilotMockPublish {
  param(
    [Parameter(Mandatory = $true)][object]$AdapterRequest,
    [Parameter(Mandatory = $true)][int]$Attempt,
    [string]$Channel
  )

  $failChannels = Split-GrowthCsv -Value $env:SANCTUM_GROWTH_MOCK_FAIL_CHANNELS
  $queueChannels = Split-GrowthCsv -Value $env:SANCTUM_GROWTH_MOCK_QUEUE_CHANNELS

  if ($failChannels -contains ([string]$Channel).Trim().ToLowerInvariant()) {
    return [pscustomobject]@{
      status = "failed"
      external_ref = ""
      reason_codes = @("adapter_transport_mock", "adapter_mock_forced_failure")
      error = "mock_forced_failure"
    }
  }

  if ($queueChannels -contains ([string]$Channel).Trim().ToLowerInvariant()) {
    $ext = "mock:{0}:{1}" -f $Channel, (Get-StableHash -Value ("queued|{0}|{1}|{2}" -f $AdapterRequest.request_id, $Attempt, $Channel)).Substring(0, 12)
    return [pscustomobject]@{
      status = "queued"
      external_ref = $ext
      reason_codes = @("adapter_transport_mock", "adapter_mock_queued")
      error = ""
    }
  }

  $external = "mock:{0}:{1}" -f $Channel, (Get-StableHash -Value ("published|{0}|{1}|{2}" -f $AdapterRequest.request_id, $Attempt, $Channel)).Substring(0, 12)
  return [pscustomobject]@{
    status = "published"
    external_ref = $external
    reason_codes = @("adapter_transport_mock", "adapter_mock_published")
    error = ""
  }
}

function Invoke-GrowthAutopilotHttpPublish {
  param(
    [Parameter(Mandatory = $true)][object]$AdapterRequest,
    [Parameter(Mandatory = $true)][string]$AdapterName
  )

  # This uses operator-provided HTTP endpoints for actual posting. No secrets are stored in-repo.
  $endpointEnv = switch ($AdapterName) {
    "x" { "SANCTUM_GROWTH_X_ENDPOINT" }
    "discourse" { "SANCTUM_GROWTH_DISCOURSE_ENDPOINT" }
    default { "" }
  }
  $apiKeyEnv = switch ($AdapterName) {
    "x" { "SANCTUM_GROWTH_X_API_KEY" }
    "discourse" { "SANCTUM_GROWTH_DISCOURSE_API_KEY" }
    default { "" }
  }

  if ([string]::IsNullOrWhiteSpace($endpointEnv)) {
    return [pscustomobject]@{
      status = "failed"
      external_ref = ""
      reason_codes = @("adapter_transport_http", "adapter_http_unsupported_adapter")
      error = "unsupported_adapter"
    }
  }

  $endpoint = [string]([Environment]::GetEnvironmentVariable($endpointEnv))
  if ([string]::IsNullOrWhiteSpace($endpoint)) {
    return [pscustomobject]@{
      status = "failed"
      external_ref = ""
      reason_codes = @("adapter_transport_http", "adapter_http_endpoint_missing")
      error = "endpoint_missing"
    }
  }

  $apiKey = ""
  if (-not [string]::IsNullOrWhiteSpace($apiKeyEnv)) {
    $apiKey = [string]([Environment]::GetEnvironmentVariable($apiKeyEnv))
  }

  $headers = @{ "Content-Type" = "application/json" }
  if (-not [string]::IsNullOrWhiteSpace($apiKey)) {
    $headers["Authorization"] = ("Bearer {0}" -f $apiKey)
  }

  try {
    $resp = Invoke-RestMethod -Method Post -Uri $endpoint -Headers $headers -Body ($AdapterRequest | ConvertTo-Json -Depth 20)
    $status = if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains "status") { [string]$resp.status } else { "" }
    if ($status -ne "published" -and $status -ne "queued") {
      $status = "published"
    }
    $ext = if ($null -ne $resp -and $resp.PSObject.Properties.Name -contains "external_ref") { [string]$resp.external_ref } else { "" }
    if ([string]::IsNullOrWhiteSpace($ext)) {
      $ext = "http:{0}:{1}" -f $AdapterName, (Get-StableHash -Value ("{0}|{1}" -f $endpoint, $AdapterRequest.request_id)).Substring(0, 12)
    }
    return [pscustomobject]@{
      status = $status
      external_ref = $ext
      reason_codes = @("adapter_transport_http", "adapter_http_publish_ok")
      error = ""
    }
  }
  catch {
    return [pscustomobject]@{
      status = "failed"
      external_ref = ""
      reason_codes = @("adapter_transport_http", "adapter_http_exception")
      error = $_.Exception.Message
    }
  }
}

function Invoke-GrowthAutopilotAdapterPublish {
  param(
    [Parameter(Mandatory = $true)][string]$CampaignId,
    [Parameter(Mandatory = $true)][string]$RunSignature,
    [Parameter(Mandatory = $true)][string]$Channel,
    [Parameter(Mandatory = $true)][string]$AdapterName,
    [Parameter(Mandatory = $true)][string]$Transport,
    [Parameter(Mandatory = $true)][object]$ActionRecord,
    [Parameter(Mandatory = $true)][object]$Policy,
    [Parameter(Mandatory = $true)][int]$MaxAttempts,
    [int[]]$RetryScheduleMs = @(200)
  )

  $policySnapshot = Get-GrowthAutopilotPolicySnapshot -Policy $Policy
  $adapterRequest = New-GrowthAutopilotAdapterRequest `
    -CampaignId $CampaignId `
    -RunSignature $RunSignature `
    -Channel $Channel `
    -AdapterName $AdapterName `
    -Transport $Transport `
    -ActionRecord $ActionRecord `
    -PolicySnapshot $policySnapshot

  $attempt = 0
  $last = $null
  while ($attempt -lt $MaxAttempts) {
    $attempt++
    $last = if ($Transport -eq "http") {
      Invoke-GrowthAutopilotHttpPublish -AdapterRequest $adapterRequest -AdapterName $AdapterName
    } else {
      Invoke-GrowthAutopilotMockPublish -AdapterRequest $adapterRequest -Attempt $attempt -Channel $Channel
    }

    if ($null -ne $last -and ([string]$last.status -eq "published" -or [string]$last.status -eq "queued")) {
      break
    }
  }

  $status = if ($null -ne $last) { [string]$last.status } else { "failed" }
  $extRef = if ($null -ne $last) { [string]$last.external_ref } else { "" }
  $reasons = @()
  if ($null -ne $last) { $reasons = @($last.reason_codes | ForEach-Object { [string]$_ }) }

  if ($status -ne "published" -and $status -ne "queued") {
    $status = "failed"
    $reasons = @($reasons + @("adapter_attempts_exhausted")) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique
  }

  return [pscustomobject]@{
    adapter_request = $adapterRequest
    publish_receipt = [pscustomobject]@{
      status = $status
      channel = $Channel
      adapter = $AdapterName
      transport = $Transport
      external_ref = $extRef
      reason_codes = @($reasons | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
      policy_snapshot = $policySnapshot
      attempt_count = $attempt
      planned_retry_delays_ms = @($RetryScheduleMs)
    }
  }
}

