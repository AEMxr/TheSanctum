Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskRouterScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
. (Join-Path $taskRouterScriptRoot "providers\mock_provider.ps1")
. (Join-Path $taskRouterScriptRoot "providers\http_provider.ps1")
. (Join-Path $taskRouterScriptRoot "multilingual_templates.ps1")
. (Join-Path $taskRouterScriptRoot "variant_selector.ps1")

function Test-ObjectLike {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  return (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject]))
}

function Get-ObjectPropertyNames {
  param([object]$Value)

  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Collections.IDictionary]) {
    return @($Value.Keys | ForEach-Object { [string]$_ })
  }

  return @($Value.PSObject.Properties.Name)
}

function Get-ObjectPropertyValue {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    if ($Value.Contains($Name)) {
      return $Value[$Name]
    }
    return $null
  }

  if (-not ((Get-ObjectPropertyNames -Value $Value) -contains $Name)) {
    return $null
  }

  return $Value.$Name
}

function Resolve-LeadCandidates {
  param([Parameter(Mandatory = $true)][object]$Task)

  $payload = $Task.payload
  if (-not (Test-ObjectLike -Value $payload)) {
    return [pscustomobject]@{
      ok = $false
      error = "payload must be an object."
      leads = @()
    }
  }

  $payloadNames = @(Get-ObjectPropertyNames -Value $payload)
  if ($payloadNames -contains "leads") {
    $rawLeads = Get-ObjectPropertyValue -Value $payload -Name "leads"
    if ($null -eq $rawLeads) {
      return [pscustomobject]@{
        ok = $false
        error = "payload.leads must be an array or object."
        leads = @()
      }
    }

    $leadItems = @()
    if ($rawLeads -is [System.Array]) {
      $leadItems = @($rawLeads)
    }
    elseif ($rawLeads -is [System.Collections.IEnumerable] -and -not ($rawLeads -is [string]) -and -not (Test-ObjectLike -Value $rawLeads)) {
      $leadItems = @($rawLeads)
    }
    elseif (Test-ObjectLike -Value $rawLeads) {
      $leadItems = @($rawLeads)
    }
    else {
      return [pscustomobject]@{
        ok = $false
        error = "payload.leads must be an array or object."
        leads = @()
      }
    }

    if ($leadItems.Count -eq 0) {
      return [pscustomobject]@{
        ok = $false
        error = "payload.leads must contain at least one lead."
        leads = @()
      }
    }

    $normalized = New-Object System.Collections.Generic.List[object]
    for ($i = 0; $i -lt $leadItems.Count; $i++) {
      $lead = $leadItems[$i]
      if (-not (Test-ObjectLike -Value $lead)) {
        return [pscustomobject]@{
          ok = $false
          error = "payload.leads[$i] must be an object."
          leads = @()
        }
      }

      [void]$normalized.Add([pscustomobject]@{
        lead = $lead
        source_index = $i
      })
    }

    return [pscustomobject]@{
      ok = $true
      error = $null
      leads = @($normalized.ToArray())
    }
  }

  return [pscustomobject]@{
    ok = $true
    error = $null
    leads = @(
      [pscustomobject]@{
        lead = $payload
        source_index = 0
      }
    )
  }
}

function Get-LeadId {
  param(
    [Parameter(Mandatory = $true)][object]$Lead,
    [Parameter(Mandatory = $true)][int]$SourceIndex
  )

  $leadId = [string](Get-ObjectPropertyValue -Value $Lead -Name "lead_id")
  if (-not [string]::IsNullOrWhiteSpace($leadId)) { return $leadId.Trim() }
  return ("lead-{0:d4}" -f $SourceIndex)
}

function Get-LeadScoreCard {
  param(
    [Parameter(Mandatory = $true)][object]$Lead,
    [Parameter(Mandatory = $true)][int]$SourceIndex
  )

  $score = 0
  $reasonCodes = New-Object System.Collections.Generic.List[string]

  $segment = ([string](Get-ObjectPropertyValue -Value $Lead -Name "segment")).Trim().ToLowerInvariant()
  if ($segment -in @("saas", "b2b", "agency")) {
    $score += 40
    [void]$reasonCodes.Add("fit_segment")
  }

  $painMatch = $false
  $painFlag = [string](Get-ObjectPropertyValue -Value $Lead -Name "pain_match")
  if ($painFlag.Trim().ToLowerInvariant() -eq "true") { $painMatch = $true }

  $painPoints = Get-ObjectPropertyValue -Value $Lead -Name "pain_points"
  if (-not $painMatch -and $painPoints -is [System.Array] -and @($painPoints).Count -gt 0) {
    $painMatch = $true
  }

  $intent = ([string](Get-ObjectPropertyValue -Value $Lead -Name "intent")).Trim()
  if (-not $painMatch -and -not [string]::IsNullOrWhiteSpace($intent)) {
    $painMatch = $true
  }

  if ($painMatch) {
    $score += 30
    [void]$reasonCodes.Add("pain_match")
  }

  $budget = 0.0
  if ([double]::TryParse(([string](Get-ObjectPropertyValue -Value $Lead -Name "budget")), [ref]$budget) -and $budget -ge 1000) {
    $score += 20
    [void]$reasonCodes.Add("budget_ok")
  }

  $engagement = 0
  if ([int]::TryParse(([string](Get-ObjectPropertyValue -Value $Lead -Name "engagement_score")), [ref]$engagement) -and $engagement -ge 70) {
    $score += 15
    [void]$reasonCodes.Add("engagement_high")
  }

  if ($reasonCodes.Count -eq 0) {
    $score -= 5
    [void]$reasonCodes.Add("low_signal")
  }

  return [pscustomobject]@{
    lead_id = Get-LeadId -Lead $Lead -SourceIndex $SourceIndex
    score = $score
    reason_codes = @($reasonCodes.ToArray())
    source_index = $SourceIndex
  }
}

function Get-DeterministicLeadRouting {
  param([Parameter(Mandatory = $true)][object]$Task)

  $candidateResult = Resolve-LeadCandidates -Task $Task
  if (-not [bool]$candidateResult.ok) {
    return [pscustomobject]@{
      status = "FAILED"
      error = [string]$candidateResult.error
      selected_route = ""
      reason_codes = @()
      ranked_leads = @()
    }
  }

  $scoredLeads = New-Object System.Collections.Generic.List[object]
  foreach ($item in @($candidateResult.leads)) {
    [void]$scoredLeads.Add((Get-LeadScoreCard -Lead $item.lead -SourceIndex ([int]$item.source_index)))
  }

  $ranked = @(
    @($scoredLeads.ToArray()) |
      Sort-Object -Property @{ Expression = { -[int]$_.score } }, @{ Expression = { [string]$_.lead_id } }, @{ Expression = { [int]$_.source_index } }
  )

  if ($ranked.Count -eq 0) {
    return [pscustomobject]@{
      status = "FAILED"
      error = "No lead candidates available for routing."
      selected_route = ""
      reason_codes = @()
      ranked_leads = @()
    }
  }

  $topLead = $ranked[0]
  $selectedRoute = "qualify_later"
  $routeReasons = New-Object System.Collections.Generic.List[string]
  if ([int]$topLead.score -ge 70) {
    $selectedRoute = "priority_outreach"
    [void]$routeReasons.Add("high_priority_score")
  }
  elseif ([int]$topLead.score -ge 40) {
    $selectedRoute = "nurture_sequence"
    [void]$routeReasons.Add("medium_priority_score")
  }
  else {
    [void]$routeReasons.Add("low_priority_score")
  }

  foreach ($reason in @($topLead.reason_codes)) {
    [void]$routeReasons.Add([string]$reason)
  }

  return [pscustomobject]@{
    status = "SUCCESS"
    error = $null
    selected_route = $selectedRoute
    reason_codes = @($routeReasons | Select-Object -Unique)
    ranked_leads = @(
      $ranked | ForEach-Object {
        [pscustomobject]@{
          lead_id = [string]$_.lead_id
          score = [int]$_.score
          reason_codes = @($_.reason_codes | ForEach-Object { [string]$_ })
        }
      }
    )
  }
}

function Get-DeterministicOfferFromRouting {
  param([Parameter(Mandatory = $true)][object]$Routing)

  # Deterministic mapping from selected route to sellable tier/package.
  $tier = "free"
  $monthlyPrice = 0
  $setupFee = 0
  $slaHours = 72
  $offerReason = "offer_free_low_signal"

  $selectedRoute = ([string]$Routing.selected_route).Trim().ToLowerInvariant()
  switch ($selectedRoute) {
    "priority_outreach" {
      $tier = "pro"
      $monthlyPrice = 999
      $setupFee = 499
      $slaHours = 24
      $offerReason = "offer_pro_priority"
    }
    "nurture_sequence" {
      $tier = "starter"
      $monthlyPrice = 299
      $setupFee = 149
      $slaHours = 48
      $offerReason = "offer_starter_nurture"
    }
    default {
      $tier = "free"
      $monthlyPrice = 0
      $setupFee = 0
      $slaHours = 72
      $offerReason = "offer_free_low_signal"
    }
  }

  $reasonCodes = New-Object System.Collections.Generic.List[string]
  [void]$reasonCodes.Add($offerReason)

  $allowedTiers = @("free", "starter", "pro")
  $monthlyCap = 5000
  $setupCap = 2500

  $guardrailViolation = $false
  if ($allowedTiers -notcontains $tier) { $guardrailViolation = $true }
  if ($monthlyPrice -lt 0 -or $setupFee -lt 0) { $guardrailViolation = $true }
  if ($monthlyPrice -gt $monthlyCap -or $setupFee -gt $setupCap) { $guardrailViolation = $true }

  if ($guardrailViolation) {
    $tier = "free"
    $monthlyPrice = 0
    $setupFee = 0
    $slaHours = 72
    [void]$reasonCodes.Add("price_guardrail_applied")
  }

  $topLeadId = "lead-unknown"
  if ($Routing.PSObject.Properties.Name -contains "ranked_leads") {
    $rankedLeads = @($Routing.ranked_leads)
    if ($rankedLeads.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$rankedLeads[0].lead_id)) {
      $topLeadId = [string]$rankedLeads[0].lead_id
    }
  }

  return [pscustomobject]@{
    offer_id = ("offer-{0}-{1}-{2}" -f $tier, $selectedRoute, $topLeadId)
    tier = $tier
    monthly_price_usd = [int]$monthlyPrice
    setup_fee_usd = [int]$setupFee
    sla_hours = [int]$slaHours
    reason_codes = @($reasonCodes | Select-Object -Unique)
  }
}

function Get-DeterministicProposalFromOffer {
  param([Parameter(Mandatory = $true)][object]$Offer)

  $tier = ([string](Get-ObjectPropertyValue -Value $Offer -Name "tier")).Trim().ToLowerInvariant()
  $offerId = ([string](Get-ObjectPropertyValue -Value $Offer -Name "offer_id")).Trim()

  $monthlyPrice = 0
  $setupFee = 0
  $monthlyOk = [int]::TryParse([string](Get-ObjectPropertyValue -Value $Offer -Name "monthly_price_usd"), [ref]$monthlyPrice)
  $setupOk = [int]::TryParse([string](Get-ObjectPropertyValue -Value $Offer -Name "setup_fee_usd"), [ref]$setupFee)

  $allowedTiers = @("free", "starter", "pro")
  $guardrailApplied = $false
  if ($allowedTiers -notcontains $tier) { $guardrailApplied = $true }
  if (-not $monthlyOk -or -not $setupOk) { $guardrailApplied = $true }
  if ($monthlyPrice -lt 0 -or $setupFee -lt 0) { $guardrailApplied = $true }

  if ([string]::IsNullOrWhiteSpace($offerId)) { $guardrailApplied = $true }

  if ($guardrailApplied) {
    $tier = "free"
    $monthlyPrice = 0
    $setupFee = 0
    $offerId = "offer-free-guardrail"
  }

  $headline = switch ($tier) {
    "pro" { "Priority Revenue Automation Plan" }
    "starter" { "Starter Revenue Automation Plan" }
    default { "Free Revenue Automation Plan" }
  }

  $proposalReason = switch ($tier) {
    "pro" { "proposal_from_offer_pro" }
    "starter" { "proposal_from_offer_starter" }
    default { "proposal_from_offer_free" }
  }

  $reasonCodes = New-Object System.Collections.Generic.List[string]
  [void]$reasonCodes.Add($proposalReason)
  if ($guardrailApplied) {
    [void]$reasonCodes.Add("proposal_guardrail_applied")
  }

  $dueNow = [int]($monthlyPrice + $setupFee)
  $checkoutStub = ("stub://checkout/{0}/{1}" -f $tier, $offerId)

  return [pscustomobject]@{
    proposal_id = ("proposal-{0}-{1}" -f $tier, $offerId)
    tier = $tier
    headline = $headline
    monthly_price_usd = [int]$monthlyPrice
    setup_fee_usd = [int]$setupFee
    due_now_usd = [int]$dueNow
    checkout_stub = $checkoutStub
    reason_codes = @($reasonCodes | Select-Object -Unique)
  }
}

function Get-DeterministicPolicyDecision {
  param([Parameter(Mandatory = $true)][object]$Task)

  $payload = $Task.payload
  if (-not (Test-ObjectLike -Value $payload)) {
    return [pscustomobject]@{
      allowed = $false
      context_key = "missing_context"
      reason_codes = @("policy_denied_missing_context")
    }
  }

  $payloadNames = @(Get-ObjectPropertyNames -Value $payload)
  $policySource = $null
  $shouldEvaluate = $false

  if ($payloadNames -contains "policy_context") {
    $policySource = Get-ObjectPropertyValue -Value $payload -Name "policy_context"
    $shouldEvaluate = $true
  }
  else {
    $inlinePolicyKeys = @(
      "platform",
      "account_id",
      "community_id",
      "target_bucket",
      "action_type",
      "window_key",
      "context_cap",
      "actions_in_window",
      "cooldown_seconds",
      "seconds_since_last_action"
    )
    foreach ($k in $inlinePolicyKeys) {
      if ($payloadNames -contains $k) {
        $shouldEvaluate = $true
        break
      }
    }
    if ($shouldEvaluate) {
      $policySource = $payload
    }
  }

  if (-not $shouldEvaluate) {
    return [pscustomobject]@{
      allowed = $true
      context_key = "policy_not_provided"
      reason_codes = @()
    }
  }

  if (-not (Test-ObjectLike -Value $policySource)) {
    return [pscustomobject]@{
      allowed = $false
      context_key = "missing_context"
      reason_codes = @("policy_denied_missing_context")
    }
  }

  $platform = ([string](Get-ObjectPropertyValue -Value $policySource -Name "platform")).Trim().ToLowerInvariant()
  $accountId = ([string](Get-ObjectPropertyValue -Value $policySource -Name "account_id")).Trim()
  $communityId = ([string](Get-ObjectPropertyValue -Value $policySource -Name "community_id")).Trim()
  if ([string]::IsNullOrWhiteSpace($communityId)) {
    $communityId = ([string](Get-ObjectPropertyValue -Value $policySource -Name "target_bucket")).Trim()
  }

  $actionType = ([string](Get-ObjectPropertyValue -Value $policySource -Name "action_type")).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($actionType)) {
    $actionType = "post"
  }

  $windowKey = ([string](Get-ObjectPropertyValue -Value $policySource -Name "window_key")).Trim()
  if ([string]::IsNullOrWhiteSpace($windowKey)) {
    $createdAt = ([string]$Task.created_at_utc).Trim()
    $tmp = [datetime]::MinValue
    if ([datetime]::TryParse($createdAt, [ref]$tmp)) {
      $windowKey = $tmp.ToUniversalTime().ToString("yyyyMMddHH")
    }
  }

  if ([string]::IsNullOrWhiteSpace($platform) -or [string]::IsNullOrWhiteSpace($accountId) -or [string]::IsNullOrWhiteSpace($communityId) -or [string]::IsNullOrWhiteSpace($windowKey)) {
    return [pscustomobject]@{
      allowed = $false
      context_key = "missing_context"
      reason_codes = @("policy_denied_missing_context")
    }
  }

  $contextKey = "{0}|{1}|{2}|{3}|{4}" -f $platform, $accountId, $communityId, $actionType, $windowKey

  $contextCap = 3
  $tmpCap = 0
  if ([int]::TryParse([string](Get-ObjectPropertyValue -Value $policySource -Name "context_cap"), [ref]$tmpCap)) {
    $contextCap = [Math]::Max(0, $tmpCap)
  }

  $actionsInWindow = 0
  $tmpActions = 0
  if ([int]::TryParse([string](Get-ObjectPropertyValue -Value $policySource -Name "actions_in_window"), [ref]$tmpActions)) {
    $actionsInWindow = [Math]::Max(0, $tmpActions)
  }

  $cooldownSeconds = 0
  $tmpCooldown = 0
  if ([int]::TryParse([string](Get-ObjectPropertyValue -Value $policySource -Name "cooldown_seconds"), [ref]$tmpCooldown)) {
    $cooldownSeconds = [Math]::Max(0, $tmpCooldown)
  }

  $secondsSinceLastAction = 2147483647
  $tmpSince = 0
  if ([int]::TryParse([string](Get-ObjectPropertyValue -Value $policySource -Name "seconds_since_last_action"), [ref]$tmpSince)) {
    $secondsSinceLastAction = [Math]::Max(0, $tmpSince)
  }

  $denies = New-Object System.Collections.Generic.List[string]
  if ($actionsInWindow -ge $contextCap) {
    [void]$denies.Add("policy_denied_context_cap")
  }
  if ($cooldownSeconds -gt 0 -and $secondsSinceLastAction -lt $cooldownSeconds) {
    [void]$denies.Add("policy_denied_cooldown")
  }

  return [pscustomobject]@{
    allowed = ($denies.Count -eq 0)
    context_key = $contextKey
    reason_codes = @($denies.ToArray())
    context_cap = $contextCap
    actions_in_window = $actionsInWindow
    cooldown_seconds = $cooldownSeconds
    seconds_since_last_action = $secondsSinceLastAction
  }
}

function Get-RevenueTelemetryEventStub {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [object]$Policy = $null,
    [object]$Routing = $null,
    [object]$Variant = $null
  )

  $payload = $Task.payload
  $languageCode = "und"
  $regionCode = "ZZ"
  $geoCoarse = "unknown"
  $channel = "unknown"
  $campaignId = ""

  if (Test-ObjectLike -Value $payload) {
    $languageCandidates = @(
      [string](Get-ObjectPropertyValue -Value $payload -Name "language_code"),
      [string](Get-ObjectPropertyValue -Value $payload -Name "detected_language"),
      [string](Get-ObjectPropertyValue -Value $payload -Name "language"),
      [string](Get-ObjectPropertyValue -Value $payload -Name "locale")
    )
    foreach ($candidate in $languageCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $languageCode = ($candidate.Trim().ToLowerInvariant() -split "[-_]")[0]
        break
      }
    }

    $regionCandidates = @(
      [string](Get-ObjectPropertyValue -Value $payload -Name "region_code"),
      [string](Get-ObjectPropertyValue -Value $payload -Name "region")
    )
    foreach ($candidate in $regionCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $regionCode = $candidate.Trim().ToUpperInvariant()
        break
      }
    }

    $geoCandidate = [string](Get-ObjectPropertyValue -Value $payload -Name "geo_coarse")
    if (-not [string]::IsNullOrWhiteSpace($geoCandidate)) {
      $geoCoarse = $geoCandidate.Trim()
    }
    elseif (-not [string]::IsNullOrWhiteSpace($regionCode) -and $regionCode -ne "ZZ") {
      $geoCoarse = $regionCode
    }

    $channelCandidates = @(
      [string](Get-ObjectPropertyValue -Value $payload -Name "source_channel"),
      [string](Get-ObjectPropertyValue -Value $payload -Name "channel")
    )
    foreach ($candidate in $channelCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $channel = $candidate.Trim().ToLowerInvariant()
        break
      }
    }

    $campaignId = [string](Get-ObjectPropertyValue -Value $payload -Name "campaign_id")
  }

  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  if ([string]::IsNullOrWhiteSpace($regionCode)) { $regionCode = "ZZ" }
  if ([string]::IsNullOrWhiteSpace($geoCoarse)) { $geoCoarse = "unknown" }
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "unknown" }

  $selectedVariantId = ""
  if ($null -ne $Variant -and (Get-ObjectPropertyNames -Value $Variant) -contains "selected_variant_id") {
    $selectedVariantId = [string](Get-ObjectPropertyValue -Value $Variant -Name "selected_variant_id")
  }

  $selectedRoute = ""
  if ($null -ne $Routing -and (Get-ObjectPropertyNames -Value $Routing) -contains "selected_route") {
    $selectedRoute = [string](Get-ObjectPropertyValue -Value $Routing -Name "selected_route")
  }

  $policyAllowed = $null
  if ($null -ne $Policy -and (Get-ObjectPropertyNames -Value $Policy) -contains "allowed") {
    $policyAllowed = [bool](Get-ObjectPropertyValue -Value $Policy -Name "allowed")
  }

  return [pscustomobject]@{
    language_code = $languageCode
    region_code = $regionCode
    geo_coarse = $geoCoarse
    source_channel = $channel
    campaign_id = $campaignId
    selected_variant_id = $selectedVariantId
    selected_route = $selectedRoute
    policy_allowed = $policyAllowed
  }
}

function New-SafeTelemetryId {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return "none" }
  $v = [regex]::Replace([string]$Value, "[^a-zA-Z0-9_-]", "_")
  if ([string]::IsNullOrWhiteSpace($v)) { return "none" }
  return $v
}

function Get-DeterministicMarketingTelemetryEvent {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$DispatchReceipt,
    [string[]]$ReasonCodes = @()
  )

  $taskIdRaw = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  $taskId = if ([string]::IsNullOrWhiteSpace($taskIdRaw)) { "task-unknown" } else { $taskIdRaw.Trim() }
  $taskType = [string](Get-ObjectPropertyValue -Value $Task -Name "task_type")
  if ([string]::IsNullOrWhiteSpace($taskType)) { $taskType = "unknown" }

  $payload = Get-ObjectPropertyValue -Value $Task -Name "payload"
  $regionCode = "ZZ"
  $geoCoarse = "unknown"
  if (Test-ObjectLike -Value $payload) {
    $regionCandidates = @(
      [string](Get-ObjectPropertyValue -Value $payload -Name "region_code"),
      [string](Get-ObjectPropertyValue -Value $payload -Name "region")
    )
    foreach ($candidate in $regionCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $regionCode = $candidate.Trim().ToUpperInvariant()
        break
      }
    }

    $geoCandidate = [string](Get-ObjectPropertyValue -Value $payload -Name "geo_coarse")
    if (-not [string]::IsNullOrWhiteSpace($geoCandidate)) {
      $geoCoarse = $geoCandidate.Trim()
    }
    elseif ($regionCode -ne "ZZ") {
      $geoCoarse = $regionCode
    }
  }

  $receiptId = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariant = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "dry_run")
  $dispatchStatus = [string](Get-ObjectPropertyValue -Value $DispatchReceipt -Name "status")
  if ([string]::IsNullOrWhiteSpace($dispatchStatus)) { $dispatchStatus = "unknown" }

  $actionsByType = @{}
  foreach ($a in @((Get-ObjectPropertyValue -Value $DispatchReceipt -Name "accepted_actions"))) {
    if ($null -eq $a) { continue }
    $actionType = ([string](Get-ObjectPropertyValue -Value $a -Name "action_type")).Trim()
    if ([string]::IsNullOrWhiteSpace($actionType)) { continue }
    $actionsByType[$actionType] = $true
  }

  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionsByType.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $eventId = "mte-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariant), `
    (New-SafeTelemetryId -Value $receiptId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("telemetry_event_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $DispatchReceipt -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    event_id = $eventId
    event_type = "dispatch_receipt"
    task_id = $taskId
    task_type = $taskType
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    source_channel = $channel
    language_code = $languageCode
    region_code = $regionCode
    geo_coarse = $geoCoarse
    selected_variant_id = $selectedVariant
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $dispatchStatus
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicAuditRecord {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$TelemetryEvent,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $eventId = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $TelemetryEvent -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $TelemetryEvent -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  # Action type ordering is contractual for downstream compliance/evidence exporters.
  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $recordId = "audit-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $eventId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("audit_record_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $TelemetryEvent -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicEvidenceEnvelope {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$AuditRecord,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $recordId = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $AuditRecord -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $AuditRecord -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $AuditRecord -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  # Accepted action type ordering is contractual for downstream retention/signing/export workflows.
  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $envelopeId = "evidence-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $recordId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("evidence_envelope_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $AuditRecord -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicRetentionManifest {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$EvidenceEnvelope,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $envelopeId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  # Accepted action type ordering is contractual for downstream retention/archival/immutability pipelines.
  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $manifestId = "retention-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $envelopeId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("retention_manifest_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $EvidenceEnvelope -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicImmutabilityReceipt {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$RetentionManifest,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $manifestId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $RetentionManifest -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $RetentionManifest -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $RetentionManifest -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  # Accepted action type ordering is contractual for downstream notarization/attestation/append-only ledger workflows.
  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $immutabilityId = "immutability-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $manifestId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("immutability_receipt_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $RetentionManifest -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicLedgerAttestation {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$ImmutabilityReceipt,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $immutabilityId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "immutability_id")
  if ([string]::IsNullOrWhiteSpace($immutabilityId)) { $immutabilityId = "immutability-unknown" }
  $manifestId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  # Accepted action type ordering is contractual for downstream anchoring/indexing/proof-verification workflows.
  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $attestationId = "attestation-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $immutabilityId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("ledger_attestation_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $ImmutabilityReceipt -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    attestation_id = $attestationId
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicProofVerification {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$LedgerAttestation,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $attestationId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "attestation_id")
  if ([string]::IsNullOrWhiteSpace($attestationId)) { $attestationId = "attestation-unknown" }
  $immutabilityId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "immutability_id")
  if ([string]::IsNullOrWhiteSpace($immutabilityId)) { $immutabilityId = "immutability-unknown" }
  $manifestId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $LedgerAttestation -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $LedgerAttestation -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $verificationId = "verify-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $attestationId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("proof_verification_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $LedgerAttestation -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    verification_id = $verificationId
    attestation_id = $attestationId
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicAnchorRecord {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$ProofVerification,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $verificationId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "verification_id")
  if ([string]::IsNullOrWhiteSpace($verificationId)) { $verificationId = "verify-unknown" }
  $attestationId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "attestation_id")
  if ([string]::IsNullOrWhiteSpace($attestationId)) { $attestationId = "attestation-unknown" }
  $immutabilityId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "immutability_id")
  if ([string]::IsNullOrWhiteSpace($immutabilityId)) { $immutabilityId = "immutability-unknown" }
  $manifestId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $ProofVerification -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $ProofVerification -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $ProofVerification -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $anchorId = "anchor-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $verificationId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("anchor_record_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $ProofVerification -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    anchor_id = $anchorId
    verification_id = $verificationId
    attestation_id = $attestationId
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicIndexReceipt {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$AnchorRecord,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $anchorId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "anchor_id")
  if ([string]::IsNullOrWhiteSpace($anchorId)) { $anchorId = "anchor-unknown" }
  $verificationId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "verification_id")
  if ([string]::IsNullOrWhiteSpace($verificationId)) { $verificationId = "verify-unknown" }
  $attestationId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "attestation_id")
  if ([string]::IsNullOrWhiteSpace($attestationId)) { $attestationId = "attestation-unknown" }
  $immutabilityId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "immutability_id")
  if ([string]::IsNullOrWhiteSpace($immutabilityId)) { $immutabilityId = "immutability-unknown" }
  $manifestId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $AnchorRecord -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $AnchorRecord -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $AnchorRecord -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $indexId = "index-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $anchorId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("index_receipt_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $AnchorRecord -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    index_id = $indexId
    anchor_id = $anchorId
    verification_id = $verificationId
    attestation_id = $attestationId
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicArchiveManifest {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$IndexReceipt,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $indexId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "index_id")
  if ([string]::IsNullOrWhiteSpace($indexId)) { $indexId = "index-unknown" }
  $anchorId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "anchor_id")
  if ([string]::IsNullOrWhiteSpace($anchorId)) { $anchorId = "anchor-unknown" }
  $verificationId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "verification_id")
  if ([string]::IsNullOrWhiteSpace($verificationId)) { $verificationId = "verify-unknown" }
  $attestationId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "attestation_id")
  if ([string]::IsNullOrWhiteSpace($attestationId)) { $attestationId = "attestation-unknown" }
  $immutabilityId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "immutability_id")
  if ([string]::IsNullOrWhiteSpace($immutabilityId)) { $immutabilityId = "immutability-unknown" }
  $manifestId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $IndexReceipt -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $IndexReceipt -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $IndexReceipt -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $archiveId = "archive-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $indexId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("archive_manifest_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $IndexReceipt -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    archive_id = $archiveId
    index_id = $indexId
    anchor_id = $anchorId
    verification_id = $verificationId
    attestation_id = $attestationId
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicNotarizationTicket {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$ArchiveManifest,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $archiveId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "archive_id")
  if ([string]::IsNullOrWhiteSpace($archiveId)) { $archiveId = "archive-unknown" }
  $indexId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "index_id")
  if ([string]::IsNullOrWhiteSpace($indexId)) { $indexId = "index-unknown" }
  $anchorId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "anchor_id")
  if ([string]::IsNullOrWhiteSpace($anchorId)) { $anchorId = "anchor-unknown" }
  $verificationId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "verification_id")
  if ([string]::IsNullOrWhiteSpace($verificationId)) { $verificationId = "verify-unknown" }
  $attestationId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "attestation_id")
  if ([string]::IsNullOrWhiteSpace($attestationId)) { $attestationId = "attestation-unknown" }
  $immutabilityId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "immutability_id")
  if ([string]::IsNullOrWhiteSpace($immutabilityId)) { $immutabilityId = "immutability-unknown" }
  $manifestId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "manifest_id")
  if ([string]::IsNullOrWhiteSpace($manifestId)) { $manifestId = "retention-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "evidence-unknown" }
  $recordId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "record_id")
  if ([string]::IsNullOrWhiteSpace($recordId)) { $recordId = "audit-unknown" }
  $eventId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "event_id")
  if ([string]::IsNullOrWhiteSpace($eventId)) { $eventId = "mte-unknown" }
  $receiptId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "receipt_id")
  if ([string]::IsNullOrWhiteSpace($receiptId)) { $receiptId = "receipt-unknown" }
  $requestId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "dry_run")
  $status = [string](Get-ObjectPropertyValue -Value $ArchiveManifest -Name "status")
  if ([string]::IsNullOrWhiteSpace($status)) { $status = "unknown" }

  $actionLookup = @{}
  foreach ($actionType in @((Get-ObjectPropertyValue -Value $ArchiveManifest -Name "accepted_action_types"))) {
    $typeValue = ([string]$actionType).Trim()
    if ([string]::IsNullOrWhiteSpace($typeValue)) { continue }
    $actionLookup[$typeValue] = $true
  }

  $acceptedActionTypes = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if ($actionLookup.Contains($actionType)) {
      $acceptedActionTypes += $actionType
    }
  }

  $notarizationId = "notary-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $archiveId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("notarization_ticket_emitted")
  foreach ($rc in @((Get-ObjectPropertyValue -Value $ArchiveManifest -Name "reason_codes"))) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    notarization_id = $notarizationId
    archive_id = $archiveId
    index_id = $indexId
    anchor_id = $anchorId
    verification_id = $verificationId
    attestation_id = $attestationId
    immutability_id = $immutabilityId
    manifest_id = $manifestId
    envelope_id = $envelopeId
    record_id = $recordId
    event_id = $eventId
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_action_types = @($acceptedActionTypes)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicCampaignPacket {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$Routing,
    [Parameter(Mandatory = $true)][object]$Offer,
    [Parameter(Mandatory = $true)][object]$Proposal,
    [object]$Variant = $null,
    [string[]]$ReasonCodes = @()
  )

  $payload = Get-ObjectPropertyValue -Value $Task -Name "payload"
  $campaignId = ""
  $sourceChannel = "web"
  if (Test-ObjectLike -Value $payload) {
    $campaignId = [string](Get-ObjectPropertyValue -Value $payload -Name "campaign_id")
    $sourceChannel = [string](Get-ObjectPropertyValue -Value $payload -Name "source_channel")
    if ([string]::IsNullOrWhiteSpace($sourceChannel)) {
      $sourceChannel = [string](Get-ObjectPropertyValue -Value $payload -Name "channel")
    }
  }
  if ([string]::IsNullOrWhiteSpace($sourceChannel)) { $sourceChannel = "web" }

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }
  $offerId = [string](Get-ObjectPropertyValue -Value $Offer -Name "offer_id")
  if ([string]::IsNullOrWhiteSpace($offerId)) { $offerId = "offer-unknown" }
  $tier = [string](Get-ObjectPropertyValue -Value $Offer -Name "tier")
  if ([string]::IsNullOrWhiteSpace($tier)) { $tier = "free" }

  if ([string]::IsNullOrWhiteSpace($campaignId)) {
    $campaignId = "campaign-{0}-{1}" -f (New-SafeTelemetryId -Value $taskId), (New-SafeTelemetryId -Value $tier)
  }

  $selectedVariantId = ""
  if ($null -ne $Variant -and (Get-ObjectPropertyNames -Value $Variant) -contains "selected_variant_id") {
    $selectedVariantId = [string](Get-ObjectPropertyValue -Value $Variant -Name "selected_variant_id")
  }

  $adCopy = [string](Get-ObjectPropertyValue -Value $Proposal -Name "ad_copy")
  $replyTemplates = @((Get-ObjectPropertyValue -Value $Proposal -Name "short_reply_templates"))
  $copyVariants = @(
    [pscustomobject]@{
      variant_key = "primary_ad_copy"
      text = $adCopy
    },
    [pscustomobject]@{
      variant_key = "short_reply_primary"
      text = if ($replyTemplates.Count -gt 0) { [string]$replyTemplates[0] } else { "" }
    }
  )

  $buyStub = [string](Get-ObjectPropertyValue -Value $Proposal -Name "checkout_stub")
  if ([string]::IsNullOrWhiteSpace($buyStub)) {
    $buyStub = "stub://checkout/{0}/{1}" -f $tier, (New-SafeTelemetryId -Value $offerId)
  }
  $subscribeStub = "stub://subscribe/{0}/{1}" -f (New-SafeTelemetryId -Value $campaignId), $tier

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("campaign_dual_cta_emitted")
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    campaign_id = $campaignId
    tier = $tier
    channels = @([string]$sourceChannel)
    copy_variants = @($copyVariants)
    cta_buy_stub = $buyStub
    cta_subscribe_stub = $subscribeStub
    selected_variant_id = $selectedVariantId
    selected_route = [string](Get-ObjectPropertyValue -Value $Routing -Name "selected_route")
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicDispatchPlan {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$CampaignPacket,
    [Parameter(Mandatory = $true)][object]$Proposal,
    [object]$Variant = $null,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $campaignId = [string](Get-ObjectPropertyValue -Value $CampaignPacket -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }

  $channel = "web"
  $channels = @((Get-ObjectPropertyValue -Value $CampaignPacket -Name "channels"))
  if ($channels.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$channels[0])) {
    $channel = [string]$channels[0]
  }

  $languageCode = [string](Get-ObjectPropertyValue -Value $Proposal -Name "template_language")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }

  $selectedVariantId = ""
  if ($null -ne $Variant -and (Get-ObjectPropertyNames -Value $Variant) -contains "selected_variant_id") {
    $selectedVariantId = [string](Get-ObjectPropertyValue -Value $Variant -Name "selected_variant_id")
  }

  $adCopy = [string](Get-ObjectPropertyValue -Value $Proposal -Name "ad_copy")
  $replyTemplate = ""
  $shortReplies = @((Get-ObjectPropertyValue -Value $Proposal -Name "short_reply_templates"))
  if ($shortReplies.Count -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$shortReplies[0])) {
    $replyTemplate = [string]$shortReplies[0]
  }

  $buyStub = [string](Get-ObjectPropertyValue -Value $CampaignPacket -Name "cta_buy_stub")
  if ([string]::IsNullOrWhiteSpace($buyStub)) {
    $buyStub = [string](Get-ObjectPropertyValue -Value $Proposal -Name "checkout_stub")
  }
  $subscribeStub = [string](Get-ObjectPropertyValue -Value $CampaignPacket -Name "cta_subscribe_stub")

  $dispatchId = "dispatch-{0}-{1}-{2}-{3}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("dispatch_plan_emitted")
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    dispatch_id = $dispatchId
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    ad_copy = $adCopy
    reply_template = $replyTemplate
    cta_buy_stub = $buyStub
    cta_subscribe_stub = $subscribeStub
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicDeliveryManifest {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$DispatchPlan,
    [Parameter(Mandatory = $true)][object]$Config,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $dispatchId = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "dispatch_id")
  if ([string]::IsNullOrWhiteSpace($dispatchId)) { $dispatchId = "dispatch-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "selected_variant_id")

  $buyStub = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "cta_buy_stub")
  $subscribeStub = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "cta_subscribe_stub")
  $adCopy = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "ad_copy")
  $replyTemplate = [string](Get-ObjectPropertyValue -Value $DispatchPlan -Name "reply_template")

  $deliveryId = "delivery-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $dispatchId)

  # Action ordering is contractual and deterministic for downstream sender adapters.
  $actions = @(
    [pscustomobject]@{
      action_type = "cta_buy"
      action_stub = $buyStub
      ad_copy = $adCopy
      reply_template = $replyTemplate
    },
    [pscustomobject]@{
      action_type = "cta_subscribe"
      action_stub = $subscribeStub
      ad_copy = $adCopy
      reply_template = $replyTemplate
    }
  )

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("delivery_manifest_emitted")
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    delivery_id = $deliveryId
    dispatch_id = $dispatchId
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = [string]$Config.provider_mode
    dry_run = [bool]$Config.dry_run
    actions = @($actions)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicSenderEnvelope {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$DeliveryManifest,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $deliveryId = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "delivery_id")
  if ([string]::IsNullOrWhiteSpace($deliveryId)) { $deliveryId = "delivery-unknown" }
  $dispatchId = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "dispatch_id")
  if ([string]::IsNullOrWhiteSpace($dispatchId)) { $dispatchId = "dispatch-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $DeliveryManifest -Name "dry_run")

  $actionsByType = @{}
  foreach ($a in @((Get-ObjectPropertyValue -Value $DeliveryManifest -Name "actions"))) {
    if ($null -eq $a) { continue }
    $actionType = ([string](Get-ObjectPropertyValue -Value $a -Name "action_type")).Trim()
    if ([string]::IsNullOrWhiteSpace($actionType)) { continue }
    $actionsByType[$actionType] = $a
  }

  # Scheduled actions must stay stable and deterministic for downstream sender adapters.
  $scheduledActions = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if (-not $actionsByType.Contains($actionType)) {
      continue
    }
    $sourceAction = $actionsByType[$actionType]
    $scheduledActions += [pscustomobject]@{
      action_type = $actionType
      action_stub = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "action_stub")
      ad_copy = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "ad_copy")
      reply_template = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "reply_template")
    }
  }

  $envelopeId = "sender-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $deliveryId)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("sender_envelope_emitted")
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    envelope_id = $envelopeId
    delivery_id = $deliveryId
    dispatch_id = $dispatchId
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    scheduled_actions = @($scheduledActions)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicAdapterRequest {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$SenderEnvelope,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $envelopeId = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "sender-unknown" }
  $deliveryId = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "delivery_id")
  if ([string]::IsNullOrWhiteSpace($deliveryId)) { $deliveryId = "delivery-unknown" }
  $dispatchId = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "dispatch_id")
  if ([string]::IsNullOrWhiteSpace($dispatchId)) { $dispatchId = "dispatch-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $SenderEnvelope -Name "dry_run")

  $actionsByType = @{}
  foreach ($a in @((Get-ObjectPropertyValue -Value $SenderEnvelope -Name "scheduled_actions"))) {
    if ($null -eq $a) { continue }
    $actionType = ([string](Get-ObjectPropertyValue -Value $a -Name "action_type")).Trim()
    if ([string]::IsNullOrWhiteSpace($actionType)) { continue }
    $actionsByType[$actionType] = $a
  }

  $scheduledActions = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if (-not $actionsByType.Contains($actionType)) {
      continue
    }
    $sourceAction = $actionsByType[$actionType]
    $scheduledActions += [pscustomobject]@{
      action_type = $actionType
      action_stub = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "action_stub")
      ad_copy = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "ad_copy")
      reply_template = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "reply_template")
    }
  }

  $requestId = "adapter-{0}-{1}-{2}-{3}-{4}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $envelopeId)

  $actionTypeBasis = @($scheduledActions | ForEach-Object { [string]$_.action_type }) -join "-"

  $idempotencyKey = "idem-{0}-{1}-{2}-{3}-{4}-{5}" -f `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $languageCode), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $dispatchId), `
    (New-SafeTelemetryId -Value $actionTypeBasis)

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("adapter_request_emitted")
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    request_id = $requestId
    idempotency_key = $idempotencyKey
    envelope_id = $envelopeId
    delivery_id = $deliveryId
    dispatch_id = $dispatchId
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    scheduled_actions = @($scheduledActions)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Get-DeterministicDispatchReceipt {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$AdapterRequest,
    [string[]]$ReasonCodes = @()
  )

  $taskId = [string](Get-ObjectPropertyValue -Value $Task -Name "task_id")
  if ([string]::IsNullOrWhiteSpace($taskId)) { $taskId = "task-unknown" }

  $requestId = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "request_id")
  if ([string]::IsNullOrWhiteSpace($requestId)) { $requestId = "adapter-unknown" }
  $idempotencyKey = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "idempotency_key")
  if ([string]::IsNullOrWhiteSpace($idempotencyKey)) { $idempotencyKey = "idem-unknown" }
  $envelopeId = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "envelope_id")
  if ([string]::IsNullOrWhiteSpace($envelopeId)) { $envelopeId = "sender-unknown" }
  $deliveryId = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "delivery_id")
  if ([string]::IsNullOrWhiteSpace($deliveryId)) { $deliveryId = "delivery-unknown" }
  $dispatchId = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "dispatch_id")
  if ([string]::IsNullOrWhiteSpace($dispatchId)) { $dispatchId = "dispatch-unknown" }
  $campaignId = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "campaign_id")
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign-unknown" }
  $channel = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "channel")
  if ([string]::IsNullOrWhiteSpace($channel)) { $channel = "web" }
  $languageCode = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "language_code")
  if ([string]::IsNullOrWhiteSpace($languageCode)) { $languageCode = "und" }
  $selectedVariantId = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "selected_variant_id")
  $providerMode = [string](Get-ObjectPropertyValue -Value $AdapterRequest -Name "provider_mode")
  if ([string]::IsNullOrWhiteSpace($providerMode)) { $providerMode = "mock" }
  $dryRun = [bool](Get-ObjectPropertyValue -Value $AdapterRequest -Name "dry_run")

  $actionsByType = @{}
  foreach ($a in @((Get-ObjectPropertyValue -Value $AdapterRequest -Name "scheduled_actions"))) {
    if ($null -eq $a) { continue }
    $actionType = ([string](Get-ObjectPropertyValue -Value $a -Name "action_type")).Trim()
    if ([string]::IsNullOrWhiteSpace($actionType)) { continue }
    $actionsByType[$actionType] = $a
  }

  # Accepted action ordering is contractual for downstream retry/telemetry/audit workflows.
  $acceptedActions = @()
  foreach ($actionType in @("cta_buy", "cta_subscribe")) {
    if (-not $actionsByType.Contains($actionType)) {
      continue
    }
    $sourceAction = $actionsByType[$actionType]
    $acceptedActions += [pscustomobject]@{
      action_type = $actionType
      action_stub = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "action_stub")
      ad_copy = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "ad_copy")
      reply_template = [string](Get-ObjectPropertyValue -Value $sourceAction -Name "reply_template")
    }
  }

  $receiptId = "receipt-{0}-{1}-{2}-{3}-{4}-{5}" -f `
    (New-SafeTelemetryId -Value $taskId), `
    (New-SafeTelemetryId -Value $campaignId), `
    (New-SafeTelemetryId -Value $channel), `
    (New-SafeTelemetryId -Value $selectedVariantId), `
    (New-SafeTelemetryId -Value $dispatchId), `
    (New-SafeTelemetryId -Value $requestId)

  $status = if ($dryRun) { "simulated" } else { "accepted" }

  $reasonList = New-Object System.Collections.Generic.List[string]
  [void]$reasonList.Add("dispatch_receipt_emitted")
  if ($dryRun) {
    [void]$reasonList.Add("dispatch_receipt_dry_run")
  }
  foreach ($rc in @($ReasonCodes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonList.Add([string]$rc)
    }
  }

  return [pscustomobject]@{
    receipt_id = $receiptId
    request_id = $requestId
    idempotency_key = $idempotencyKey
    envelope_id = $envelopeId
    delivery_id = $deliveryId
    dispatch_id = $dispatchId
    campaign_id = $campaignId
    channel = $channel
    language_code = $languageCode
    selected_variant_id = $selectedVariantId
    provider_mode = $providerMode
    dry_run = $dryRun
    status = $status
    accepted_actions = @($acceptedActions)
    reason_codes = @($reasonList | Select-Object -Unique)
  }
}

function Invoke-RevenueTaskRoute {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$Config
  )

  $taskType = [string]$Task.task_type
  $supportedTaskTypes = @(
    "lead_enrich",
    "followup_draft",
    "calendar_proposal"
  )
  $policy = Get-DeterministicPolicyDecision -Task $Task

  if ($supportedTaskTypes -notcontains $taskType) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "none"
      error = "Unsupported task_type: $taskType"
      artifacts = @()
      policy = $policy
      route = $null
      offer = $null
      proposal = $null
      reason_codes = @()
      telemetry_event_stub = Get-RevenueTelemetryEventStub -Task $Task -Policy $policy
      telemetry_event = $null
      campaign_packet = $null
      dispatch_plan = $null
      delivery_manifest = $null
      sender_envelope = $null
      adapter_request = $null
      dispatch_receipt = $null
      audit_record = $null
      evidence_envelope = $null
      retention_manifest = $null
      immutability_receipt = $null
      ledger_attestation = $null
      proof_verification = $null
      anchor_record = $null
      index_receipt = $null
      archive_manifest = $null
      notarization_ticket = $null
    }
  }

  if (-not [bool]$policy.allowed) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "none"
      error = "Policy denied action for context: $($policy.context_key)"
      artifacts = @()
      policy = $policy
      route = $null
      offer = $null
      proposal = $null
      reason_codes = @($policy.reason_codes | ForEach-Object { [string]$_ })
      telemetry_event_stub = Get-RevenueTelemetryEventStub -Task $Task -Policy $policy
      telemetry_event = $null
      campaign_packet = $null
      dispatch_plan = $null
      delivery_manifest = $null
      sender_envelope = $null
      adapter_request = $null
      dispatch_receipt = $null
      audit_record = $null
      evidence_envelope = $null
      retention_manifest = $null
      immutability_receipt = $null
      ledger_attestation = $null
      proof_verification = $null
      anchor_record = $null
      index_receipt = $null
      archive_manifest = $null
      notarization_ticket = $null
    }
  }

  $routing = $null
  if ($taskType -eq "lead_enrich") {
    $routing = Get-DeterministicLeadRouting -Task $Task
    if ([string]$routing.status -eq "FAILED") {
      return [pscustomobject]@{
        status = "FAILED"
        provider_used = "none"
        error = [string]$routing.error
        artifacts = @()
        route = [pscustomobject]@{
          selected_route = $null
          reason_codes = @()
          ranked_leads = @()
        }
        offer = $null
        proposal = $null
        reason_codes = @()
        telemetry_event_stub = Get-RevenueTelemetryEventStub -Task $Task -Policy $policy -Routing $routing
        telemetry_event = $null
        campaign_packet = $null
        dispatch_plan = $null
        delivery_manifest = $null
        sender_envelope = $null
        adapter_request = $null
        dispatch_receipt = $null
        audit_record = $null
        evidence_envelope = $null
        retention_manifest = $null
        immutability_receipt = $null
        ledger_attestation = $null
        proof_verification = $null
        anchor_record = $null
        index_receipt = $null
        archive_manifest = $null
        notarization_ticket = $null
      }
    }
  }

  $providerResult = $null
  $providerMode = [string]$Config.provider_mode
  switch ($providerMode) {
    "mock" {
      $providerResult = Invoke-MockProvider -Task $Task -Config $Config
    }
    "http" {
      $providerResult = Invoke-HttpProvider -Task $Task -Config $Config
    }
    default {
      return [pscustomobject]@{
        status = "SKIPPED"
        provider_used = "none"
        error = "Unsupported provider_mode: $providerMode"
        artifacts = @()
        policy = $policy
        route = $null
        offer = $null
        proposal = $null
        reason_codes = @()
        telemetry_event_stub = Get-RevenueTelemetryEventStub -Task $Task -Policy $policy
        telemetry_event = $null
        campaign_packet = $null
        dispatch_plan = $null
        delivery_manifest = $null
        sender_envelope = $null
        adapter_request = $null
        dispatch_receipt = $null
        audit_record = $null
        evidence_envelope = $null
        retention_manifest = $null
        immutability_receipt = $null
        ledger_attestation = $null
        proof_verification = $null
        anchor_record = $null
        index_receipt = $null
        archive_manifest = $null
        notarization_ticket = $null
      }
    }
  }

  $offer = $null
  $proposal = $null
  $templateReasonCodes = @()
  $variant = $null
  $variantReasonCodes = @()
  $resultReasonCodes = @()
  $telemetryEvent = $null
  $campaignPacket = $null
  $dispatchPlan = $null
  $deliveryManifest = $null
  $senderEnvelope = $null
  $adapterRequest = $null
  $dispatchReceipt = $null
  $auditRecord = $null
  $evidenceEnvelope = $null
  $retentionManifest = $null
  $immutabilityReceipt = $null
  $ledgerAttestation = $null
  $proofVerification = $null
  $anchorRecord = $null
  $indexReceipt = $null
  $archiveManifest = $null
  $notarizationTicket = $null

  if ($taskType -eq "lead_enrich" -and [string]$providerResult.status -eq "SUCCESS" -and $null -ne $routing) {
    $offer = Get-DeterministicOfferFromRouting -Routing $routing
    $proposal = Get-DeterministicProposalFromOffer -Offer $offer
    $localizedProposal = Merge-ProposalWithLocalizedTemplates -Task $Task -Proposal $proposal
    $proposal = $localizedProposal.proposal
    $templateReasonCodes = @(
      $localizedProposal.reason_codes |
        ForEach-Object { [string]$_ } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
    # Variant selection is deterministic and language-aware; tie-break behavior is enforced in variant_selector.ps1.
    $variant = Get-LanguageAwareVariantSelection -Task $Task
    $variantReasonCodes = @($variant.selection_reason_codes | ForEach-Object { [string]$_ })

    $resultReasonCodes = @(
      @($routing.reason_codes | ForEach-Object { [string]$_ }) +
      @($templateReasonCodes | ForEach-Object { [string]$_ }) +
      @($variantReasonCodes | ForEach-Object { [string]$_ })
    ) | Select-Object -Unique

    $campaignPacket = Get-DeterministicCampaignPacket `
      -Task $Task `
      -Routing $routing `
      -Offer $offer `
      -Proposal $proposal `
      -Variant $variant `
      -ReasonCodes $resultReasonCodes

    $dispatchPlan = Get-DeterministicDispatchPlan `
      -Task $Task `
      -CampaignPacket $campaignPacket `
      -Proposal $proposal `
      -Variant $variant `
      -ReasonCodes $resultReasonCodes

    $deliveryManifest = Get-DeterministicDeliveryManifest `
      -Task $Task `
      -DispatchPlan $dispatchPlan `
      -Config $Config `
      -ReasonCodes $resultReasonCodes

    $senderEnvelope = Get-DeterministicSenderEnvelope `
      -Task $Task `
      -DeliveryManifest $deliveryManifest `
      -ReasonCodes $resultReasonCodes

    $adapterRequest = Get-DeterministicAdapterRequest `
      -Task $Task `
      -SenderEnvelope $senderEnvelope `
      -ReasonCodes $resultReasonCodes

    $dispatchReceipt = Get-DeterministicDispatchReceipt `
      -Task $Task `
      -AdapterRequest $adapterRequest `
      -ReasonCodes $resultReasonCodes

    $telemetryEvent = Get-DeterministicMarketingTelemetryEvent `
      -Task $Task `
      -DispatchReceipt $dispatchReceipt `
      -ReasonCodes $resultReasonCodes

    $auditRecord = Get-DeterministicAuditRecord `
      -Task $Task `
      -TelemetryEvent $telemetryEvent `
      -ReasonCodes $resultReasonCodes

    $evidenceEnvelope = Get-DeterministicEvidenceEnvelope `
      -Task $Task `
      -AuditRecord $auditRecord `
      -ReasonCodes $resultReasonCodes

    $retentionManifest = Get-DeterministicRetentionManifest `
      -Task $Task `
      -EvidenceEnvelope $evidenceEnvelope `
      -ReasonCodes $resultReasonCodes

    $immutabilityReceipt = Get-DeterministicImmutabilityReceipt `
      -Task $Task `
      -RetentionManifest $retentionManifest `
      -ReasonCodes $resultReasonCodes

    $ledgerAttestation = Get-DeterministicLedgerAttestation `
      -Task $Task `
      -ImmutabilityReceipt $immutabilityReceipt `
      -ReasonCodes $resultReasonCodes

    $proofVerification = Get-DeterministicProofVerification `
      -Task $Task `
      -LedgerAttestation $ledgerAttestation `
      -ReasonCodes $resultReasonCodes

    $anchorRecord = Get-DeterministicAnchorRecord `
      -Task $Task `
      -ProofVerification $proofVerification `
      -ReasonCodes $resultReasonCodes

    $indexReceipt = Get-DeterministicIndexReceipt `
      -Task $Task `
      -AnchorRecord $anchorRecord `
      -ReasonCodes $resultReasonCodes

    $archiveManifest = Get-DeterministicArchiveManifest `
      -Task $Task `
      -IndexReceipt $indexReceipt `
      -ReasonCodes $resultReasonCodes

    $notarizationTicket = Get-DeterministicNotarizationTicket `
      -Task $Task `
      -ArchiveManifest $archiveManifest `
      -ReasonCodes $resultReasonCodes
  }
  elseif ($null -ne $routing) {
    $resultReasonCodes = @($routing.reason_codes | ForEach-Object { [string]$_ })
  }

  return [pscustomobject]@{
    status = [string]$providerResult.status
    provider_used = [string]$providerResult.provider_used
    error = [string]$providerResult.error
    artifacts = @($providerResult.artifacts | ForEach-Object { [string]$_ })
    policy = $policy
    route = if ($null -ne $routing) {
      [pscustomobject]@{
        selected_route = [string]$routing.selected_route
        reason_codes = @($routing.reason_codes | ForEach-Object { [string]$_ })
        ranked_leads = @($routing.ranked_leads)
        variant = $variant
      }
    }
    else {
      $null
    }
    offer = $offer
    proposal = $proposal
    reason_codes = @($resultReasonCodes)
    telemetry_event_stub = Get-RevenueTelemetryEventStub -Task $Task -Policy $policy -Routing $routing -Variant $variant
    telemetry_event = $telemetryEvent
    campaign_packet = $campaignPacket
    dispatch_plan = $dispatchPlan
    delivery_manifest = $deliveryManifest
    sender_envelope = $senderEnvelope
    adapter_request = $adapterRequest
    dispatch_receipt = $dispatchReceipt
    audit_record = $auditRecord
    evidence_envelope = $evidenceEnvelope
    retention_manifest = $retentionManifest
    immutability_receipt = $immutabilityReceipt
    ledger_attestation = $ledgerAttestation
    proof_verification = $proofVerification
    anchor_record = $anchorRecord
    index_receipt = $indexReceipt
    archive_manifest = $archiveManifest
    notarization_ticket = $notarizationTicket
  }
}
