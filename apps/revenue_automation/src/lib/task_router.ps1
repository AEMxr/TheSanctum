Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskRouterScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
. (Join-Path $taskRouterScriptRoot "providers\mock_provider.ps1")
. (Join-Path $taskRouterScriptRoot "providers\http_provider.ps1")

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

  if ($supportedTaskTypes -notcontains $taskType) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "none"
      error = "Unsupported task_type: $taskType"
      artifacts = @()
      route = $null
      offer = $null
      reason_codes = @()
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
        reason_codes = @()
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
        route = $null
        offer = $null
        reason_codes = @()
      }
    }
  }

  $offer = $null
  if ($taskType -eq "lead_enrich" -and [string]$providerResult.status -eq "SUCCESS" -and $null -ne $routing) {
    $offer = Get-DeterministicOfferFromRouting -Routing $routing
  }

  return [pscustomobject]@{
    status = [string]$providerResult.status
    provider_used = [string]$providerResult.provider_used
    error = [string]$providerResult.error
    artifacts = @($providerResult.artifacts | ForEach-Object { [string]$_ })
    route = if ($null -ne $routing) {
      [pscustomobject]@{
        selected_route = [string]$routing.selected_route
        reason_codes = @($routing.reason_codes | ForEach-Object { [string]$_ })
        ranked_leads = @($routing.ranked_leads)
      }
    }
    else {
      $null
    }
    offer = $offer
    reason_codes = if ($null -ne $routing) { @($routing.reason_codes | ForEach-Object { [string]$_ }) } else { @() }
  }
}
