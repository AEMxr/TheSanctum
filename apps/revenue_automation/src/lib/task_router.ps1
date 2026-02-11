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
      }
    }
  }

  $offer = $null
  $proposal = $null
  $templateReasonCodes = @()
  $variant = $null
  $variantReasonCodes = @()
  if ($taskType -eq "lead_enrich" -and [string]$providerResult.status -eq "SUCCESS" -and $null -ne $routing) {
    $offer = Get-DeterministicOfferFromRouting -Routing $routing
    $proposal = Get-DeterministicProposalFromOffer -Offer $offer
    $localizedProposal = Merge-ProposalWithLocalizedTemplates -Task $Task -Proposal $proposal
    $proposal = $localizedProposal.proposal
    $templateReasonCodes = @($localizedProposal.reason_codes | ForEach-Object { [string]$_ })
    $variant = Get-LanguageAwareVariantSelection -Task $Task
    $variantReasonCodes = @($variant.selection_reason_codes | ForEach-Object { [string]$_ })
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
    reason_codes = if ($null -ne $routing) {
      @(
        @($routing.reason_codes | ForEach-Object { [string]$_ }) +
        @($templateReasonCodes | ForEach-Object { [string]$_ }) +
        @($variantReasonCodes | ForEach-Object { [string]$_ })
      ) | Select-Object -Unique
    }
    else {
      @()
    }
    telemetry_event_stub = Get-RevenueTelemetryEventStub -Task $Task -Policy $policy -Routing $routing -Variant $variant
  }
}
