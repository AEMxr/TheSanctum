param(
  [ValidateSet("dryrun", "live")][string]$Mode = "dryrun",
  [ValidateSet("", "mock", "http")][string]$PublishTransport = "",
  [string]$CampaignId = "sample",
  [string]$Languages = "all",
  [double]$DailyBudget = 0,
  [int]$MaxPostsPerDay = 0,
  [string]$LandingUrl = "",
  [string]$ConfigPath = "",
  [string]$AllowlistPath = "",
  [string]$CampaignPath = "",
  [string]$StateDir = "",
  [string]$ArtifactsDir = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Directory {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -Path $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

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

function Read-OptionalJsonArrayFile {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -Path $Path -PathType Leaf)) {
    return @()
  }

  try {
    $raw = Get-Content -Path $Path -Raw -Encoding UTF8
    if ([string]::IsNullOrWhiteSpace($raw)) { return @() }
    $obj = $raw | ConvertFrom-Json
    return @($obj)
  }
  catch {
    return @()
  }
}

function Get-StableHash {
  param([Parameter(Mandatory = $true)][string]$Value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
    $hash = $sha.ComputeHash($bytes)
    return ([BitConverter]::ToString($hash) -replace "-", "").ToLowerInvariant()
  }
  finally {
    $sha.Dispose()
  }
}

# Phase 2: adapter contract + channel bindings.
$devScriptDir = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) { $PSScriptRoot } elseif (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$adapterLibPath = Join-Path $devScriptDir "..\\lib\\growth_autopilot_adapters.ps1"
if (-not (Test-Path -Path $adapterLibPath -PathType Leaf)) {
  throw "Missing adapter library: $adapterLibPath"
}
. $adapterLibPath

$ledgerLibPath = Join-Path $devScriptDir "..\\lib\\growth_autopilot_ledger.ps1"
if (-not (Test-Path -Path $ledgerLibPath -PathType Leaf)) {
  throw "Missing ledger library: $ledgerLibPath"
}
. $ledgerLibPath

function Convert-ToLanguageCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "en" }
  $parts = ([string]$Value).Trim().ToLowerInvariant() -split "[-_]"
  if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$parts[0])) { return "en" }
  return [string]$parts[0]
}

function Get-LanguageSet {
  param(
    [string]$RawLanguages,
    [object]$Campaign
  )

  $campaignLanguages = @()
  if ($null -ne $Campaign -and $Campaign.PSObject.Properties.Name -contains "target_languages") {
    $campaignLanguages = @($Campaign.target_languages | ForEach-Object { Convert-ToLanguageCode -Value ([string]$_) })
  }
  if ($campaignLanguages.Count -eq 0) {
    $campaignLanguages = @("en")
  }

  if ([string]::IsNullOrWhiteSpace($RawLanguages) -or ([string]$RawLanguages).Trim().ToLowerInvariant() -eq "all") {
    return @($campaignLanguages | Select-Object -Unique)
  }

  $parsed = @(
    ([string]$RawLanguages).Split(",") |
      ForEach-Object { Convert-ToLanguageCode -Value $_ } |
      Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
      Select-Object -Unique
  )
  if ($parsed.Count -eq 0) {
    return @($campaignLanguages | Select-Object -Unique)
  }
  return $parsed
}

function Get-LocalizationBundle {
  param(
    [Parameter(Mandatory = $true)][string]$LanguageCode,
    [Parameter(Mandatory = $true)][string]$Keyword,
    [Parameter(Mandatory = $true)][string]$Tone,
    [Parameter(Mandatory = $true)][string]$DefaultDisclosure
  )

  $lang = Convert-ToLanguageCode -Value $LanguageCode
  $catalog = @{
    en = @{
      ad_prefix = "Scale outcomes with"
      reply_prefix = "If helpful, we can automate"
      cta_buy = "Start pilot now"
      cta_subscribe = "Get updates"
      disclosure = "Sponsored content. Reply STOP to opt out."
      reason = "template_lang_native"
    }
    es = @{
      ad_prefix = "Acelera resultados con"
      reply_prefix = "Si te sirve, podemos automatizar"
      cta_buy = "Iniciar piloto ahora"
      cta_subscribe = "Recibir novedades"
      disclosure = "Contenido patrocinado. Responde STOP para salir."
      reason = "template_lang_native"
    }
    fr = @{
      ad_prefix = "Accélérez les résultats avec"
      reply_prefix = "Si utile, nous pouvons automatiser"
      cta_buy = "Lancer le pilote"
      cta_subscribe = "Recevoir les nouveautés"
      disclosure = "Contenu sponsorisé. Répondez STOP pour vous désinscrire."
      reason = "template_lang_native"
    }
    de = @{
      ad_prefix = "Mehr Wirkung mit"
      reply_prefix = "Wenn hilfreich, automatisieren wir"
      cta_buy = "Pilot jetzt starten"
      cta_subscribe = "Updates erhalten"
      disclosure = "Gesponserter Inhalt. Mit STOP abmelden."
      reason = "template_lang_native"
    }
    pt = @{
      ad_prefix = "Acelere resultados com"
      reply_prefix = "Se fizer sentido, podemos automatizar"
      cta_buy = "Iniciar piloto agora"
      cta_subscribe = "Receber atualizações"
      disclosure = "Conteudo patrocinado. Responda STOP para cancelar."
      reason = "template_lang_native"
    }
  }

  $template = $null
  if ($catalog.ContainsKey($lang)) {
    $template = $catalog[$lang]
  }
  else {
    $template = $catalog["en"].Clone()
    $template.reason = "template_lang_fallback_en"
  }

  $tonePrefix = switch (($Tone.Trim().ToLowerInvariant())) {
    "direct" { "Direct:" }
    "conversational" { "Conversational:" }
    default { "Professional:" }
  }

  $disclosure = [string]$template.disclosure
  if ([string]::IsNullOrWhiteSpace($disclosure)) {
    $disclosure = $DefaultDisclosure
  }

  return [pscustomobject]@{
    ad_copy = ("{0} {1} {2}" -f $tonePrefix, [string]$template.ad_prefix, $Keyword).Trim()
    reply_template = ("{0} {1} workflows." -f $tonePrefix, [string]$template.reply_prefix).Trim()
    cta_buy_text = [string]$template.cta_buy
    cta_subscribe_text = [string]$template.cta_subscribe
    disclosure_text = $disclosure
    reason_codes = @([string]$template.reason)
  }
}

function Get-PolicyForChannel {
  param(
    [Parameter(Mandatory = $true)][object]$Allowlist,
    [Parameter(Mandatory = $true)][string]$Channel
  )

  $items = @()
  if ($Allowlist.PSObject.Properties.Name -contains "channels") {
    $items = @($Allowlist.channels)
  }

  foreach ($item in $items) {
    $name = ([string]$item.channel).Trim().ToLowerInvariant()
    if ($name -eq $Channel.Trim().ToLowerInvariant()) {
      return [pscustomobject]@{
        known = $true
        channel = $name
        autopost_allowed = [bool]$item.autopost_allowed
        requires_human_review = [bool]$item.requires_human_review
        posting_rate_limit_per_day = [int]$item.posting_rate_limit_per_day
        policy_confidence = [double]$item.policy_confidence
        required_disclosures = @($item.required_disclosures | ForEach-Object { [string]$_ })
      }
    }
  }

  return [pscustomobject]@{
    known = $false
    channel = $Channel.Trim().ToLowerInvariant()
    autopost_allowed = $false
    requires_human_review = $true
    posting_rate_limit_per_day = 0
    policy_confidence = 0.0
    required_disclosures = @()
  }
}

function New-TrackedUrl {
  param(
    [Parameter(Mandatory = $true)][string]$LandingUrl,
    [Parameter(Mandatory = $true)][string]$Template,
    [Parameter(Mandatory = $true)][string]$Channel,
    [Parameter(Mandatory = $true)][string]$CampaignId,
    [Parameter(Mandatory = $true)][string]$LanguageCode,
    [Parameter(Mandatory = $true)][string]$CreativeId
  )

  $query = $Template
  $query = $query.Replace("{channel}", [uri]::EscapeDataString($Channel))
  $query = $query.Replace("{campaign_id}", [uri]::EscapeDataString($CampaignId))
  $query = $query.Replace("{language_code}", [uri]::EscapeDataString($LanguageCode))
  $query = $query.Replace("{creative_id}", [uri]::EscapeDataString($CreativeId))

  if ($LandingUrl.Contains("?")) {
    return "$LandingUrl&$query"
  }
  return "$LandingUrl`?$query"
}

function Get-OpportunityScore {
  param(
    [int]$KeywordIndex,
    [string]$Channel,
    [string]$LanguageCode,
    [object]$Policy
  )

  $channelWeight = switch ($Channel) {
    "x" { 14 }
    "discourse" { 10 }
    "reddit" { 7 }
    default { 3 }
  }
  $langWeight = switch ($LanguageCode) {
    "en" { 8 }
    "es" { 7 }
    "fr" { 6 }
    "de" { 5 }
    "pt" { 5 }
    default { 4 }
  }
  $policyWeight = if ([bool]$Policy.known) { [int][Math]::Round([double]$Policy.policy_confidence * 10) } else { 0 }
  return [int](60 + ($KeywordIndex * 4) + $channelWeight + $langWeight + $policyWeight)
}

function Get-Opportunities {
  param(
    [Parameter(Mandatory = $true)][object]$Campaign,
    [Parameter(Mandatory = $true)][object]$Allowlist,
    [Parameter(Mandatory = $true)][string[]]$LanguageCodes
  )

  $keywords = @($Campaign.keywords | ForEach-Object { ([string]$_).Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
  if ($keywords.Count -eq 0) {
    $keywords = @("growth automation")
  }

  $channels = New-Object System.Collections.Generic.List[string]

  # Prefer explicit campaign seed channels when provided; allowlist remains policy metadata only.
  $seedChannels = @()
  if ($Campaign.PSObject.Properties.Name -contains "discovery_seed_channels") {
    $seedChannels = @(
      $Campaign.discovery_seed_channels |
        ForEach-Object { ([string]$_).Trim().ToLowerInvariant() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Select-Object -Unique
    )
  }

  if ($seedChannels.Count -gt 0) {
    foreach ($name in $seedChannels) {
      if (-not $channels.Contains($name)) {
        [void]$channels.Add($name)
      }
    }
  }
  else {
    if ($Allowlist.PSObject.Properties.Name -contains "channels") {
      foreach ($entry in @($Allowlist.channels)) {
        $name = ([string]$entry.channel).Trim().ToLowerInvariant()
        if (-not [string]::IsNullOrWhiteSpace($name) -and -not $channels.Contains($name)) {
          [void]$channels.Add($name)
        }
      }
    }
  }

  if ($channels.Count -eq 0) {
    [void]$channels.Add("x")
  }

  $results = New-Object System.Collections.Generic.List[object]
  $campaignId = ([string]$Campaign.campaign_id).Trim()
  if ([string]::IsNullOrWhiteSpace($campaignId)) {
    $campaignId = "campaign"
  }

  for ($i = 0; $i -lt $keywords.Count; $i++) {
    foreach ($channel in @($channels.ToArray())) {
      $policy = Get-PolicyForChannel -Allowlist $Allowlist -Channel $channel
      foreach ($language in @($LanguageCodes)) {
        $creativeId = "kw{0:d2}-{1}-{2}" -f ($i + 1), $language, $channel
        $score = Get-OpportunityScore -KeywordIndex $i -Channel $channel -LanguageCode $language -Policy $policy
        $opportunityId = "opp-{0}" -f (Get-StableHash -Value ("{0}|{1}|{2}|{3}|{4}" -f $campaignId, $channel, $language, $keywords[$i], $creativeId)).Substring(0, 16)
        [void]$results.Add([pscustomobject]@{
          opportunity_id = $opportunityId
          channel = $channel
          thread_or_target = ("{0}-{1}" -f $channel, ("topic-{0:d2}" -f ($i + 1)))
          language_code = $language
          keyword = $keywords[$i]
          keyword_index = $i
          creative_id = $creativeId
          audience_fit = $score
          expected_conversion_score = [int]([Math]::Max(1, [Math]::Min(100, $score)))
          policy_confidence = [double]$policy.policy_confidence
          autopost_allowed = [bool]$policy.autopost_allowed
          requires_human_review = [bool]$policy.requires_human_review
          policy_known = [bool]$policy.known
          policy = $policy
        })
      }
    }
  }

  return @(
    $results |
      Sort-Object -Property @{ Expression = { -[int]$_.expected_conversion_score } }, @{ Expression = { [string]$_.channel } }, @{ Expression = { [string]$_.language_code } }, @{ Expression = { [string]$_.creative_id } }
  )
}

function New-ActionRecord {
  param(
    [Parameter(Mandatory = $true)][object]$Opportunity,
    [Parameter(Mandatory = $true)][object]$Localization,
    [Parameter(Mandatory = $true)][string]$CampaignId,
    [Parameter(Mandatory = $true)][string]$LandingUrl,
    [Parameter(Mandatory = $true)][string]$UtmTemplate,
    [Parameter(Mandatory = $true)][string[]]$ReasonCodes,
    [Parameter(Mandatory = $true)][string]$Status,
    [Parameter(Mandatory = $true)][string]$ExecutionMode,
    [string[]]$Disclosures = @()
  )

  $trackedUrl = New-TrackedUrl `
    -LandingUrl $LandingUrl `
    -Template $UtmTemplate `
    -Channel ([string]$Opportunity.channel) `
    -CampaignId $CampaignId `
    -LanguageCode ([string]$Opportunity.language_code) `
    -CreativeId ([string]$Opportunity.creative_id)

  $recordId = "plan-{0}" -f (Get-StableHash -Value ("{0}|{1}|{2}|{3}" -f $CampaignId, $Opportunity.opportunity_id, $Status, $ExecutionMode)).Substring(0, 16)
  $reason = @(
    @($ReasonCodes | ForEach-Object { [string]$_ }) +
    @($Localization.reason_codes | ForEach-Object { [string]$_ })
  ) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique

  return [pscustomobject]@{
    plan_id = $recordId
    campaign_id = $CampaignId
    opportunity_id = [string]$Opportunity.opportunity_id
    channel = [string]$Opportunity.channel
    thread_or_target = [string]$Opportunity.thread_or_target
    language_code = [string]$Opportunity.language_code
    creative_id = [string]$Opportunity.creative_id
    keyword = [string]$Opportunity.keyword
    quality_score = [int]$Opportunity.expected_conversion_score
    execution_mode = $ExecutionMode
    status = $Status
    tracked_url = $trackedUrl
    ad_copy = [string]$Localization.ad_copy
    reply_template = [string]$Localization.reply_template
    cta_buy_stub = ("stub://buy/{0}/{1}" -f $CampaignId, $Opportunity.creative_id)
    cta_subscribe_stub = ("stub://subscribe/{0}/{1}" -f $CampaignId, $Opportunity.creative_id)
    disclosure = [string]$Localization.disclosure_text
    required_disclosures = @($Disclosures | ForEach-Object { [string]$_ } | Select-Object -Unique)
    reason_codes = @($reason)
  }
}

function Get-DispatchPlan {
  param(
    [Parameter(Mandatory = $true)][string]$Mode,
    [Parameter(Mandatory = $true)][string]$PublishTransport,
    [Parameter(Mandatory = $true)][bool]$SafeMode,
    [Parameter(Mandatory = $true)][object]$Config,
    [Parameter(Mandatory = $true)][object]$Campaign,
    [Parameter(Mandatory = $true)][string]$RunSignature,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Opportunities,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$ExistingPublishLedger,
    [Parameter(Mandatory = $true)][double]$DailyBudget,
    [Parameter(Mandatory = $true)][int]$MaxPostsPerDay,
    [Parameter(Mandatory = $true)][string]$LandingUrl
  )

  $campaignId = ([string]$Campaign.campaign_id).Trim()
  if ([string]::IsNullOrWhiteSpace($campaignId)) { $campaignId = "campaign" }
  $tone = if ($Campaign.PSObject.Properties.Name -contains "tone") { [string]$Campaign.tone } else { "professional" }
  $utmTemplate = [string]$Config.utm_template
  if ([string]::IsNullOrWhiteSpace($utmTemplate)) {
    $utmTemplate = "utm_source={channel}&utm_medium=autopilot&utm_campaign={campaign_id}&utm_content={language_code}-{creative_id}"
  }

  $defaultDisclosure = ""
  if ($Config.PSObject.Properties.Name -contains "compliance" -and $null -ne $Config.compliance) {
    if ($Config.compliance.PSObject.Properties.Name -contains "default_disclosure") {
      $defaultDisclosure = [string]$Config.compliance.default_disclosure
    }
  }
  if ([string]::IsNullOrWhiteSpace($defaultDisclosure)) {
    $defaultDisclosure = "Sponsored content. Reply STOP to opt out."
  }

  $posts = New-Object System.Collections.Generic.List[object]
  $drafts = New-Object System.Collections.Generic.List[object]
  $adapterRequests = New-Object System.Collections.Generic.List[object]
  $publishReceipts = New-Object System.Collections.Generic.List[object]
  $errors = New-Object System.Collections.Generic.List[object]
  $channelCounts = @{}
  $postedCount = 0
  $budgetUsed = 0.0
  $costPerPost = 1.0
  $tmpCost = 0.0
  if ([double]::TryParse([string]$Campaign.cost_per_post_usd, [ref]$tmpCost) -and $tmpCost -gt 0) {
    $costPerPost = $tmpCost
  }

  $registry = Get-GrowthAutopilotAdapterRegistry

  $ledgerIndex = @{}
  foreach ($entry in @($ExistingPublishLedger)) {
    if ($null -eq $entry) { continue }
    $k = [string]$entry.dedupe_key
    if (-not [string]::IsNullOrWhiteSpace($k)) {
      $ledgerIndex[$k] = $entry
    }
  }

  $selfPromotionMode = "explicit_only"
  if ($Config.PSObject.Properties.Name -contains "self_promotion_mode") {
    $selfPromotionMode = [string]$Config.self_promotion_mode
  }
  if ([string]::IsNullOrWhiteSpace($selfPromotionMode)) { $selfPromotionMode = "explicit_only" }
  $selfPromotionMode = $selfPromotionMode.Trim().ToLowerInvariant()

  $campaignSelfPromotionAllowed = $false
  if ($Campaign.PSObject.Properties.Name -contains "self_promotion_allowed") {
    $campaignSelfPromotionAllowed = [bool]$Campaign.self_promotion_allowed
  }

  $httpTimeoutSec = 10
  $tmpTimeout = 0
  if ($Config.PSObject.Properties.Name -contains "adapter_http_timeout_sec" -and [int]::TryParse([string]$Config.adapter_http_timeout_sec, [ref]$tmpTimeout) -and $tmpTimeout -gt 0) {
    $httpTimeoutSec = $tmpTimeout
  }

  $retryScheduleMs = @(200)
  if ($Config.PSObject.Properties.Name -contains "adapter_retry_schedule_ms") {
    $raw = $Config.adapter_retry_schedule_ms
    $items = @()
    if ($raw -is [System.Collections.IEnumerable] -and -not ($raw -is [string])) { $items = @($raw) } else { $items = @($raw) }

    $parsed = New-Object System.Collections.Generic.List[int]
    foreach ($v in @($items)) {
      $tmp = 0
      if ([int]::TryParse([string]$v, [ref]$tmp) -and $tmp -ge 0) { [void]$parsed.Add($tmp) }
    }
    if ($parsed.Count -gt 0) { $retryScheduleMs = @($parsed.ToArray()) }
  }

  $ledgerRetentionDays = 30
  $tmpRet = 0
  if ($Config.PSObject.Properties.Name -contains "publish_ledger_retention_days" -and [int]::TryParse([string]$Config.publish_ledger_retention_days, [ref]$tmpRet) -and $tmpRet -ge 0) {
    $ledgerRetentionDays = $tmpRet
  }
  $ledgerMaxEntries = 5000
  $tmpMax = 0
  if ($Config.PSObject.Properties.Name -contains "publish_ledger_max_entries" -and [int]::TryParse([string]$Config.publish_ledger_max_entries, [ref]$tmpMax) -and $tmpMax -gt 0) {
    $ledgerMaxEntries = $tmpMax
  }

  $firstSeenDayUtc = (Get-Date).ToUniversalTime().ToString("yyyy-MM-dd")

  foreach ($op in @($Opportunities)) {
    $channel = [string]$op.channel
    if (-not $channelCounts.ContainsKey($channel)) {
      $channelCounts[$channel] = 0
    }

    $policy = $op.policy
    $localization = Get-LocalizationBundle `
      -LanguageCode ([string]$op.language_code) `
      -Keyword ([string]$op.keyword) `
      -Tone $tone `
      -DefaultDisclosure $defaultDisclosure

    $requiredDisclosures = @($policy.required_disclosures | ForEach-Object { [string]$_ })
    $isDryrun = ([string]::IsNullOrWhiteSpace($Mode) -or $Mode -eq "dryrun")
    if ($isDryrun) {
      # Dryrun: never autopost, but still emit deterministic policy lineage reasons.
      $reasonCodes = New-Object System.Collections.Generic.List[string]
      [void]$reasonCodes.Add("dryrun_mode")
      if ($SafeMode) {
        [void]$reasonCodes.Add("safe_mode_forced_draft")
      }
      elseif ($selfPromotionMode -eq "explicit_only" -and -not $campaignSelfPromotionAllowed) {
        [void]$reasonCodes.Add("self_promotion_explicit_only")
      }
      elseif (-not [bool]$policy.known) {
        [void]$reasonCodes.Add("policy_unknown_draft_only")
      }
      elseif ([bool]$policy.requires_human_review -or -not [bool]$policy.autopost_allowed) {
        [void]$reasonCodes.Add("channel_requires_human_review")
      }
      else {
        [void]$reasonCodes.Add("autopost_allowed")
      }

      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @($reasonCodes.ToArray()) `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    if ($SafeMode) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("safe_mode_forced_draft") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    if ($selfPromotionMode -eq "explicit_only" -and -not $campaignSelfPromotionAllowed) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("self_promotion_explicit_only") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    if (-not [bool]$policy.known) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("policy_unknown_draft_only") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    if ([bool]$policy.requires_human_review -or -not [bool]$policy.autopost_allowed) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("channel_requires_human_review") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    if ($postedCount -ge $MaxPostsPerDay) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("daily_post_cap_reached") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    $channelLimit = [int]$policy.posting_rate_limit_per_day
    if ($channelLimit -gt 0 -and [int]$channelCounts[$channel] -ge $channelLimit) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("channel_rate_limit_reached") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    if (($budgetUsed + $costPerPost) -gt $DailyBudget) {
      $record = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("daily_budget_exceeded") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($record)
      continue
    }

    # Eligible for live adapter execution (policy known + allowlisted + not safe mode + within caps).
    $record = New-ActionRecord `
      -Opportunity $op `
      -Localization $localization `
      -CampaignId $campaignId `
      -LandingUrl $LandingUrl `
      -UtmTemplate $utmTemplate `
      -ReasonCodes @("autopost_allowed", "adapter_executed") `
      -Status "published" `
      -ExecutionMode "live_autopost" `
      -Disclosures $requiredDisclosures

    $dedupeKey = "{0}|{1}|{2}|{3}" -f $campaignId, $RunSignature, ([string]$record.plan_id), $channel
    if ($ledgerIndex.ContainsKey($dedupeKey)) {
      $replay = $ledgerIndex[$dedupeKey]
      if ($null -ne $replay.adapter_request) { [void]$adapterRequests.Add($replay.adapter_request) }
      if ($null -ne $replay.publish_receipt) { [void]$publishReceipts.Add($replay.publish_receipt) }
      $ar = $replay.action_record
      if ($null -ne $ar -and [string]$ar.status -eq "published") {
        [void]$posts.Add($ar)
        $postedCount++
        $channelCounts[$channel] = [int]$channelCounts[$channel] + 1
        $budgetUsed += $costPerPost
      }
      elseif ($null -ne $ar) {
        [void]$drafts.Add($ar)
      }
      continue
    }

    $adapterName = ""
    if ($registry.ContainsKey($channel)) {
      $adapterName = [string]$registry[$channel]
    }
    if ([string]::IsNullOrWhiteSpace($adapterName)) {
      $fallback = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("adapter_not_registered") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($fallback)
      $ledgerIndex[$dedupeKey] = [pscustomobject]@{
        dedupe_key = $dedupeKey
        campaign_id = $campaignId
        run_signature = $RunSignature
        first_seen_day_utc = $firstSeenDayUtc
        plan_id = [string]$record.plan_id
        channel = $channel
        adapter_request = $null
        publish_receipt = $null
        action_record = $fallback
      }
      continue
    }

    $adapterResult = Invoke-GrowthAutopilotAdapterPublish `
      -CampaignId $campaignId `
      -RunSignature $RunSignature `
      -Channel $channel `
      -AdapterName $adapterName `
      -Transport $PublishTransport `
      -ActionRecord $record `
      -Policy $policy `
      -MaxAttempts 2 `
      -RetryScheduleMs $retryScheduleMs `
      -HttpTimeoutSec $httpTimeoutSec

    if ($null -ne $adapterResult.adapter_request) { [void]$adapterRequests.Add($adapterResult.adapter_request) }
    if ($null -ne $adapterResult.publish_receipt) { [void]$publishReceipts.Add($adapterResult.publish_receipt) }

    if ($null -ne $adapterResult.publish_receipt -and [string]$adapterResult.publish_receipt.status -eq "failed") {
      $fallback = New-ActionRecord `
        -Opportunity $op `
        -Localization $localization `
        -CampaignId $campaignId `
        -LandingUrl $LandingUrl `
        -UtmTemplate $utmTemplate `
        -ReasonCodes @("autopost_allowed", "adapter_publish_failed") `
        -Status "queued_for_review" `
        -ExecutionMode "draft_only" `
        -Disclosures $requiredDisclosures
      [void]$drafts.Add($fallback)

      $ledgerIndex[$dedupeKey] = [pscustomobject]@{
        dedupe_key = $dedupeKey
        campaign_id = $campaignId
        run_signature = $RunSignature
        first_seen_day_utc = $firstSeenDayUtc
        plan_id = [string]$record.plan_id
        channel = $channel
        adapter_request = $adapterResult.adapter_request
        publish_receipt = $adapterResult.publish_receipt
        action_record = $fallback
      }
      continue
    }

    # Attach adapter receipt summary to the published action record (backward compatible extra fields).
    if ($null -ne $adapterResult.publish_receipt) {
      $record | Add-Member -NotePropertyName adapter_status -NotePropertyValue ([string]$adapterResult.publish_receipt.status) -Force
      $record | Add-Member -NotePropertyName adapter_external_ref -NotePropertyValue ([string]$adapterResult.publish_receipt.external_ref) -Force
      $record | Add-Member -NotePropertyName adapter_attempt_count -NotePropertyValue ([int]$adapterResult.publish_receipt.attempt_count) -Force
    }
    $record | Add-Member -NotePropertyName adapter -NotePropertyValue $adapterName -Force
    $record | Add-Member -NotePropertyName publish_transport -NotePropertyValue $PublishTransport -Force

    [void]$posts.Add($record)
    $postedCount++
    $channelCounts[$channel] = [int]$channelCounts[$channel] + 1
    $budgetUsed += $costPerPost

    $ledgerIndex[$dedupeKey] = [pscustomobject]@{
      dedupe_key = $dedupeKey
      campaign_id = $campaignId
      run_signature = $RunSignature
      first_seen_day_utc = $firstSeenDayUtc
      plan_id = [string]$record.plan_id
      channel = $channel
      adapter_request = $adapterResult.adapter_request
      publish_receipt = $adapterResult.publish_receipt
      action_record = $record
    }
  }

  $ledgerOut = @()
  if ([string]$Mode -eq "live") {
    $ledgerOut = Compact-GrowthPublishLedger -Entries @($ledgerIndex.Values) -CurrentRunSignature $RunSignature -RetentionDays $ledgerRetentionDays -MaxEntries $ledgerMaxEntries -Errors $errors
  }
  else {
    $ledgerOut = @(
      $ledgerIndex.Values |
        Sort-Object -Property @{ Expression = { [string]$_.dedupe_key } }
    )
  }

  return [pscustomobject]@{
    posts = @($posts.ToArray())
    drafts = @($drafts.ToArray())
    adapter_requests = @($adapterRequests.ToArray())
    publish_receipts = @($publishReceipts.ToArray())
    publish_ledger = @(
      @($ledgerOut)
    )
    errors = @($errors.ToArray())
    budget_used_usd = [double]([Math]::Round($budgetUsed, 2))
    cost_per_post_usd = [double]([Math]::Round($costPerPost, 2))
    posted_count = $postedCount
  }
}

function Get-Metrics {
  param(
    [Parameter(Mandatory = $true)][object]$Campaign,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Posts,
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Drafts
  )

  $saleValue = 100
  $tmpSale = 0
  if ([int]::TryParse([string]$Campaign.estimated_sale_value_usd, [ref]$tmpSale) -and $tmpSale -gt 0) {
    $saleValue = $tmpSale
  }

  $channelLang = @{}
  $totalClicks = 0
  $totalSignups = 0
  $totalPurchases = 0
  $totalRevenue = 0

  foreach ($post in @($Posts)) {
    $quality = [int]$post.quality_score
    $clicks = [int]([Math]::Max(1, [Math]::Floor($quality / 10)))
    $signups = [int]([Math]::Floor($clicks * 0.25))
    $purchases = [int]([Math]::Floor($signups * 0.2))
    $revenue = [int]($purchases * $saleValue)

    $key = "{0}|{1}" -f ([string]$post.channel), ([string]$post.language_code)
    if (-not $channelLang.ContainsKey($key)) {
      $channelLang[$key] = [ordered]@{
        channel = [string]$post.channel
        language_code = [string]$post.language_code
        posts = 0
        clicks = 0
        signups = 0
        purchases = 0
        revenue_usd = 0
      }
    }

    $channelLang[$key].posts += 1
    $channelLang[$key].clicks += $clicks
    $channelLang[$key].signups += $signups
    $channelLang[$key].purchases += $purchases
    $channelLang[$key].revenue_usd += $revenue

    $totalClicks += $clicks
    $totalSignups += $signups
    $totalPurchases += $purchases
    $totalRevenue += $revenue
  }

  $summary = @(
    $channelLang.Values |
      Sort-Object -Property @{ Expression = { [string]$_.channel } }, @{ Expression = { [string]$_.language_code } }
  )

  $winner = $null
  if ($summary.Count -gt 0) {
    $winner = @(
      $summary |
        Sort-Object -Property @{ Expression = { -[int]$_.purchases } }, @{ Expression = { -[int]$_.clicks } }, @{ Expression = { [string]$_.channel } }, @{ Expression = { [string]$_.language_code } }
    )[0]
  }

  return [pscustomobject]@{
    campaign_id = [string]$Campaign.campaign_id
    totals = [pscustomobject]@{
      posts = @($Posts).Count
      drafts = @($Drafts).Count
      clicks = $totalClicks
      signups = $totalSignups
      purchases = $totalPurchases
      revenue_usd = $totalRevenue
    }
    channel_language_summary = @($summary)
    top_segment = if ($null -eq $winner) { $null } else { [pscustomobject]$winner }
  }
}

function Save-Json {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)]$Value
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir)) {
    Ensure-Directory -Path $dir
  }
  # Avoid pipeline semantics so empty arrays still produce "[]", and files are always created.
  $json = ConvertTo-Json -InputObject $Value -Depth 40
  if ($null -eq $json) { $json = "null" }
  Set-Content -Path $Path -Value $json -Encoding UTF8
}

$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$repoRoot = (Resolve-Path (Join-Path $scriptDir "..\..")).Path

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $repoRoot "config\growth_autopilot.json"
}
if ([string]::IsNullOrWhiteSpace($AllowlistPath)) {
  $AllowlistPath = Join-Path $repoRoot "data\growth\allowlist.json"
}
if ([string]::IsNullOrWhiteSpace($CampaignPath)) {
  $CampaignPath = Join-Path $repoRoot ("data\growth\campaigns\{0}.json" -f $CampaignId)
}
if ([string]::IsNullOrWhiteSpace($StateDir)) {
  $StateDir = Join-Path $repoRoot "data\growth\state"
}
if ([string]::IsNullOrWhiteSpace($ArtifactsDir)) {
  $ArtifactsDir = Join-Path $repoRoot "artifacts\runtime"
}

$errors = New-Object System.Collections.Generic.List[object]

try {
  $config = Read-JsonFile -Path $ConfigPath -Label "Growth autopilot config"
  $allowlist = Read-JsonFile -Path $AllowlistPath -Label "Growth allowlist"
  if (-not (Test-Path -Path $CampaignPath -PathType Leaf)) {
    $CampaignPath = Join-Path $repoRoot "data\growth\campaigns\sample.json"
  }
  $campaign = Read-JsonFile -Path $CampaignPath -Label "Growth campaign"

  if ([string]::IsNullOrWhiteSpace([string]$campaign.campaign_id)) {
    $campaign | Add-Member -NotePropertyName campaign_id -NotePropertyValue $CampaignId -Force
  }

  if ([string]::IsNullOrWhiteSpace($LandingUrl)) {
    $LandingUrl = [string]$campaign.landing_url
  }
  if ([string]::IsNullOrWhiteSpace($LandingUrl)) {
    $LandingUrl = "https://example.com"
  }

  if ($DailyBudget -le 0) {
    $tmpBudget = 0.0
    if ([double]::TryParse([string]$campaign.daily_budget_usd, [ref]$tmpBudget) -and $tmpBudget -gt 0) {
      $DailyBudget = $tmpBudget
    }
    else {
      $tmpConfigBudget = 0.0
      if ([double]::TryParse([string]$config.default_daily_budget, [ref]$tmpConfigBudget) -and $tmpConfigBudget -gt 0) {
        $DailyBudget = $tmpConfigBudget
      }
      else {
        $DailyBudget = 50
      }
    }
  }
  if ($MaxPostsPerDay -le 0) {
    $tmpPosts = 0
    if ([int]::TryParse([string]$campaign.max_posts_per_day, [ref]$tmpPosts) -and $tmpPosts -gt 0) {
      $MaxPostsPerDay = $tmpPosts
    }
    else {
      $tmpConfigPosts = 0
      if ([int]::TryParse([string]$config.default_max_posts_per_day, [ref]$tmpConfigPosts) -and $tmpConfigPosts -gt 0) {
        $MaxPostsPerDay = $tmpConfigPosts
      }
      else {
        $MaxPostsPerDay = 10
      }
    }
  }

  if ([string]$config.delivery_mode -ne "tenant_only") {
    throw "Config delivery_mode must remain tenant_only."
  }
  if ([bool]$config.cross_sell_allowed) {
    throw "Config cross_sell_allowed must remain false."
  }

  $safeMode = [bool]$config.safe_mode
  if ([bool]$config.global_emergency_stop) {
    $safeMode = $true
    [void]$errors.Add([pscustomobject]@{
      code = "global_emergency_stop"
      detail = "Global emergency stop is active; forcing draft-only mode."
    })
  }

  $resolvedTransport = $PublishTransport
  if ([string]::IsNullOrWhiteSpace($resolvedTransport)) {
    if ($config.PSObject.Properties.Name -contains "publish_transport_default") {
      $resolvedTransport = [string]$config.publish_transport_default
    }
  }
  if ([string]::IsNullOrWhiteSpace($resolvedTransport)) { $resolvedTransport = "mock" }
  $resolvedTransport = $resolvedTransport.Trim().ToLowerInvariant()
  if ($resolvedTransport -ne "mock" -and $resolvedTransport -ne "http") { $resolvedTransport = "mock" }

  $languageSet = Get-LanguageSet -RawLanguages $Languages -Campaign $campaign

  $runSignature = (Get-StableHash -Value ("{0}|{1}|{2}|{3}|{4}|{5}|{6}|{7}" -f `
      [string]$campaign.campaign_id, `
      $Mode, `
      $resolvedTransport, `
      ($languageSet -join ","), `
      $DailyBudget, `
      $MaxPostsPerDay, `
      $LandingUrl, `
      [string]$safeMode)).Substring(0, 16)

  $ledgerPath = Join-Path $StateDir ("publish_ledger.{0}.json" -f ([string]$campaign.campaign_id))
  $existingLedger = @(Read-OptionalJsonArrayFile -Path $ledgerPath)

  $opportunities = Get-Opportunities -Campaign $campaign -Allowlist $allowlist -LanguageCodes $languageSet
  $plan = Get-DispatchPlan `
    -Mode $Mode `
    -PublishTransport $resolvedTransport `
    -SafeMode $safeMode `
    -Config $config `
    -Campaign $campaign `
    -RunSignature $runSignature `
    -Opportunities $opportunities `
    -ExistingPublishLedger $existingLedger `
    -DailyBudget $DailyBudget `
    -MaxPostsPerDay $MaxPostsPerDay `
    -LandingUrl $LandingUrl

  foreach ($e in @($plan.errors)) {
    [void]$errors.Add($e)
  }

  $metrics = Get-Metrics -Campaign $campaign -Posts $plan.posts -Drafts $plan.drafts

  $nextActions = New-Object System.Collections.Generic.List[string]
  if (@($plan.drafts).Count -gt 0) {
    [void]$nextActions.Add("Review queued drafts for channels requiring manual posting.")
  }
  else {
    [void]$nextActions.Add("No draft queue pending.")
  }
  if (@($plan.posts).Count -eq 0) {
    [void]$nextActions.Add("No autopost actions executed; verify allowlist or disable safe mode in non-production dry runs.")
  }
  else {
    [void]$nextActions.Add("Monitor conversion metrics and keep policy boundaries unchanged.")
  }

  $summary = [pscustomobject]@{
    verdict = if ($errors.Count -eq 0) { "PASS" } else { "FAIL" }
    campaign_id = [string]$campaign.campaign_id
    mode = $Mode
    safe_mode = $safeMode
    delivery_mode = [string]$config.delivery_mode
    cross_sell_allowed = [bool]$config.cross_sell_allowed
    run_signature = $runSignature
    publish_transport = $resolvedTransport
    language_codes = @($languageSet)
    landing_url = $LandingUrl
    daily_budget_usd = [double]([Math]::Round($DailyBudget, 2))
    max_posts_per_day = [int]$MaxPostsPerDay
    discovery_count = @($opportunities).Count
    posts_count = @($plan.posts).Count
    drafts_count = @($plan.drafts).Count
    adapter_requests_count = @($plan.adapter_requests).Count
    publish_receipts_count = @($plan.publish_receipts).Count
    budget_used_usd = [double]([Math]::Round($plan.budget_used_usd, 2))
    metrics = $metrics.totals
    next_actions = @($nextActions.ToArray())
  }

  Ensure-Directory -Path $ArtifactsDir
  Ensure-Directory -Path $StateDir

  $summaryPath = Join-Path $ArtifactsDir "growth_autopilot.summary.json"
  $postsPath = Join-Path $ArtifactsDir "growth_autopilot.posts.json"
  $draftsPath = Join-Path $ArtifactsDir "growth_autopilot.drafts.json"
  $metricsPath = Join-Path $ArtifactsDir "growth_autopilot.metrics.json"
  $errorsPath = Join-Path $ArtifactsDir "growth_autopilot.errors.json"
  $adapterRequestsPath = Join-Path $ArtifactsDir "growth_autopilot.adapter_requests.json"
  $publishReceiptsPath = Join-Path $ArtifactsDir "growth_autopilot.publish_receipts.json"
  $statePath = Join-Path $StateDir ("{0}.{1}.json" -f ([string]$campaign.campaign_id), $runSignature)

  Save-Json -Path $summaryPath -Value $summary
  Save-Json -Path $postsPath -Value @($plan.posts)
  Save-Json -Path $draftsPath -Value @($plan.drafts)
  Save-Json -Path $metricsPath -Value $metrics
  Save-Json -Path $adapterRequestsPath -Value @($plan.adapter_requests)
  Save-Json -Path $publishReceiptsPath -Value @($plan.publish_receipts)
  Save-Json -Path $errorsPath -Value @($errors.ToArray())
  Save-Json -Path $ledgerPath -Value @($plan.publish_ledger)
  Save-Json -Path $statePath -Value ([pscustomobject]@{
    campaign_id = [string]$campaign.campaign_id
    run_signature = $runSignature
    mode = $Mode
    publish_transport = $resolvedTransport
    safe_mode = $safeMode
    posts_count = @($plan.posts).Count
    drafts_count = @($plan.drafts).Count
    artifacts = [pscustomobject]@{
      summary = $summaryPath
      posts = $postsPath
      drafts = $draftsPath
      metrics = $metricsPath
      adapter_requests = $adapterRequestsPath
      publish_receipts = $publishReceiptsPath
      errors = $errorsPath
      publish_ledger = $ledgerPath
    }
  })

  Write-Output ($summary | ConvertTo-Json -Depth 20 -Compress)
  if ($summary.verdict -ne "PASS") {
    exit 1
  }
  exit 0
}
catch {
  $fallback = [pscustomobject]@{
    verdict = "FAIL"
    error = $_.Exception.Message
    campaign_id = $CampaignId
    mode = $Mode
  }
  try {
    Ensure-Directory -Path $ArtifactsDir
    $errorsPath = Join-Path $ArtifactsDir "growth_autopilot.errors.json"
    Save-Json -Path $errorsPath -Value @([pscustomobject]@{ code = "runtime_failure"; detail = $_.Exception.Message })
    $summaryPath = Join-Path $ArtifactsDir "growth_autopilot.summary.json"
    Save-Json -Path $summaryPath -Value $fallback
  }
  catch {}
  Write-Error $_.Exception.Message
  Write-Output ($fallback | ConvertTo-Json -Depth 10 -Compress)
  exit 1
}
