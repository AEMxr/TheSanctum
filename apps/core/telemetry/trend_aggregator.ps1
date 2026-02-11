param(
  [string]$InputPath = "",
  [string]$OutFile = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-TrendEventSchemaPath {
  return Join-Path $PSScriptRoot "event_schema.json"
}

function Get-TrendEventSchema {
  $path = Get-TrendEventSchemaPath
  if (-not (Test-Path -Path $path -PathType Leaf)) {
    throw "Event schema not found: $path"
  }
  return Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Normalize-LanguageCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "und" }
  $parts = ([string]$Value).Trim().ToLowerInvariant() -split "[-_]"
  if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($parts[0])) { return "und" }
  return [string]$parts[0]
}

function Normalize-RegionCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "ZZ" }
  $trimmed = ([string]$Value).Trim().ToUpperInvariant()
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return "ZZ" }
  return $trimmed
}

function Normalize-GeoCoarse {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
  return ([string]$Value).Trim()
}

function Normalize-Tier {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
  return ([string]$Value).Trim().ToLowerInvariant()
}

function Normalize-Channel {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
  return ([string]$Value).Trim().ToLowerInvariant()
}

function Normalize-EventType {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "unknown" }
  return ([string]$Value).Trim().ToLowerInvariant()
}

function Get-TrendEventsFromInput {
  param([Parameter(Mandatory = $true)][object]$InputObject)

  if ($null -eq $InputObject) { return @() }
  if ($InputObject -is [System.Array]) { return @($InputObject) }
  if ($InputObject.PSObject.Properties.Name -contains "events") {
    return @($InputObject.events)
  }
  return @($InputObject)
}

function Get-NormalizedTrendEvents {
  param([Parameter(Mandatory = $true)][object[]]$Events)

  $normalized = New-Object System.Collections.Generic.List[object]
  foreach ($e in @($Events)) {
    if ($null -eq $e) { continue }

    $eventType = Normalize-EventType -Value ([string]$e.event_type)
    $languageCode = Normalize-LanguageCode -Value ([string]$e.language_code)
    $regionCode = Normalize-RegionCode -Value ([string]$e.region_code)
    $channel = Normalize-Channel -Value ([string]$e.channel)
    $tier = Normalize-Tier -Value ([string]$e.offer_tier)
    $geoCoarse = Normalize-GeoCoarse -Value ([string]$e.geo_coarse)

    [void]$normalized.Add([pscustomobject]@{
      event_id = [string]$e.event_id
      event_type = $eventType
      timestamp_utc = [string]$e.timestamp_utc
      campaign_id = [string]$e.campaign_id
      channel = $channel
      offer_tier = $tier
      language_code = $languageCode
      region_code = $regionCode
      geo_coarse = $geoCoarse
      reason_codes = @("trend_lang_segmented")
    })
  }
  return @($normalized.ToArray())
}

function Get-SafeBps {
  param(
    [int]$Numerator,
    [int]$Denominator
  )
  if ($Denominator -le 0) { return 0 }
  return [int][Math]::Floor((10000.0 * [double]$Numerator) / [double]$Denominator)
}

function Get-RegionBreakdownForEvents {
  param([Parameter(Mandatory = $true)][object[]]$EventsInSegment)

  $regionGroups = @(
    @($EventsInSegment) |
      Group-Object -Property { [string]$_.region_code }
  )

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($g in $regionGroups) {
    $regionCode = [string]$g.Name
    if ([string]::IsNullOrWhiteSpace($regionCode)) { $regionCode = "ZZ" }
    $regionEvents = @($g.Group)

    $impressions = @($regionEvents | Where-Object { $_.event_type -eq "impression" }).Count
    $clickBuy = @($regionEvents | Where-Object { $_.event_type -eq "click_cta_buy" }).Count
    $clickSubscribe = @($regionEvents | Where-Object { $_.event_type -eq "click_cta_subscribe" }).Count
    $purchases = @($regionEvents | Where-Object { $_.event_type -eq "purchase_complete" }).Count
    $clicksTotal = [int]($clickBuy + $clickSubscribe)

    [void]$rows.Add([pscustomobject]@{
      region_code = $regionCode
      counts = [pscustomobject]@{
        events = @($regionEvents).Count
        impressions = $impressions
        click_cta_buy = $clickBuy
        click_cta_subscribe = $clickSubscribe
        purchase_complete = $purchases
      }
      metrics = [pscustomobject]@{
        ctr_bps = (Get-SafeBps -Numerator $clicksTotal -Denominator $impressions)
        conversion_bps = (Get-SafeBps -Numerator $purchases -Denominator $impressions)
      }
      reason_codes = @("trend_lang_segmented")
    })
  }

  return @(
    $rows |
      Sort-Object -Property @{ Expression = "region_code"; Descending = $false }
  )
}

function Get-LanguageSegmentedTrendMetrics {
  param([Parameter(Mandatory = $true)][object[]]$Events)

  $normalized = Get-NormalizedTrendEvents -Events $Events
  $groups = @(
    $normalized |
      Group-Object -Property {
        "{0}|{1}|{2}" -f [string]$_.language_code, [string]$_.offer_tier, [string]$_.channel
      }
  )

  $rows = New-Object System.Collections.Generic.List[object]
  foreach ($g in $groups) {
    $parts = [string]$g.Name -split "\|"
    $language = if ($parts.Length -gt 0) { [string]$parts[0] } else { "und" }
    $tier = if ($parts.Length -gt 1) { [string]$parts[1] } else { "unknown" }
    $channel = if ($parts.Length -gt 2) { [string]$parts[2] } else { "unknown" }
    $eventsInGroup = @($g.Group)

    $impressions = @($eventsInGroup | Where-Object { $_.event_type -eq "impression" }).Count
    $clickBuy = @($eventsInGroup | Where-Object { $_.event_type -eq "click_cta_buy" }).Count
    $clickSubscribe = @($eventsInGroup | Where-Object { $_.event_type -eq "click_cta_subscribe" }).Count
    $proposals = @($eventsInGroup | Where-Object { $_.event_type -eq "proposal_requested" }).Count
    $purchases = @($eventsInGroup | Where-Object { $_.event_type -eq "purchase_complete" }).Count

    $clicksTotal = [int]($clickBuy + $clickSubscribe)
    $ctrBps = Get-SafeBps -Numerator $clicksTotal -Denominator $impressions
    $conversionBps = Get-SafeBps -Numerator $purchases -Denominator $impressions

    [void]$rows.Add([pscustomobject]@{
      language_code = $language
      offer_tier = $tier
      channel = $channel
      counts = [pscustomobject]@{
        events = @($eventsInGroup).Count
        impressions = $impressions
        click_cta_buy = $clickBuy
        click_cta_subscribe = $clickSubscribe
        proposal_requested = $proposals
        purchase_complete = $purchases
      }
      metrics = [pscustomobject]@{
        ctr_bps = $ctrBps
        conversion_bps = $conversionBps
      }
      region_breakdown = @(Get-RegionBreakdownForEvents -EventsInSegment $eventsInGroup)
      reason_codes = @("trend_lang_segmented")
    })
  }

  $orderedRows = @(
    $rows |
      Sort-Object -Property @{ Expression = "language_code"; Descending = $false }, @{ Expression = "offer_tier"; Descending = $false }, @{ Expression = "channel"; Descending = $false }
  )

  return [pscustomobject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    schema_version = "v1"
    grouping_key = @("language_code", "offer_tier", "channel")
    segments = @($orderedRows)
    reason_codes = @("trend_lang_segmented")
  }
}

function Get-TrendEventsFromPath {
  param([Parameter(Mandatory = $true)][string]$Path)
  if (-not (Test-Path -Path $Path -PathType Leaf)) {
    throw "InputPath not found: $Path"
  }
  $obj = Get-Content -Path $Path -Raw -Encoding UTF8 | ConvertFrom-Json
  return Get-TrendEventsFromInput -InputObject $obj
}

$isDotSourced = $MyInvocation.InvocationName -eq "."
if (-not $isDotSourced) {
  if ([string]::IsNullOrWhiteSpace($InputPath)) {
    throw "InputPath is required when running trend_aggregator.ps1 directly."
  }
  $events = Get-TrendEventsFromPath -Path $InputPath
  $summary = Get-LanguageSegmentedTrendMetrics -Events $events
  $json = $summary | ConvertTo-Json -Depth 20
  if ([string]::IsNullOrWhiteSpace($OutFile)) {
    Write-Output $json
  }
  else {
    $outDir = Split-Path -Parent $OutFile
    if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -Path $outDir -PathType Container)) {
      New-Item -Path $outDir -ItemType Directory -Force | Out-Null
    }
    $json | Set-Content -Path $OutFile -Encoding UTF8
  }
}
