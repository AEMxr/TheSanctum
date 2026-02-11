Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-VariantObjectPropertyValue {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )

  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    if ($Value.Contains($Name)) { return $Value[$Name] }
    return $null
  }
  $names = @($Value.PSObject.Properties.Name)
  if ($names -contains $Name) { return $Value.$Name }
  return $null
}

function Normalize-VariantLanguageCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "und" }
  $parts = ([string]$Value).Trim().ToLowerInvariant() -split "[-_]"
  if ($parts.Count -eq 0 -or [string]::IsNullOrWhiteSpace($parts[0])) { return "und" }
  return [string]$parts[0]
}

function Normalize-VariantRegionCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "ZZ" }
  $trimmed = ([string]$Value).Trim().ToUpperInvariant()
  if ([string]::IsNullOrWhiteSpace($trimmed)) { return "ZZ" }
  return $trimmed
}

function Get-VariantSelectionDefaults {
  return @{
    en = "variant_en_core"
    es = "variant_es_core"
    pt = "variant_pt_core"
    fr = "variant_fr_core"
    de = "variant_de_core"
  }
}

function Get-VariantSelectionInput {
  param([Parameter(Mandatory = $true)][object]$Task)

  $payload = $Task.payload
  $languageCode = "und"
  $regionCode = "ZZ"
  $segments = @()

  if ($null -ne $payload) {
    $languageCandidates = @(
      [string](Get-VariantObjectPropertyValue -Value $payload -Name "language_code"),
      [string](Get-VariantObjectPropertyValue -Value $payload -Name "detected_language"),
      [string](Get-VariantObjectPropertyValue -Value $payload -Name "language"),
      [string](Get-VariantObjectPropertyValue -Value $payload -Name "locale")
    )
    foreach ($candidate in $languageCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $languageCode = Normalize-VariantLanguageCode -Value $candidate
        break
      }
    }

    $regionCandidates = @(
      [string](Get-VariantObjectPropertyValue -Value $payload -Name "region_code"),
      [string](Get-VariantObjectPropertyValue -Value $payload -Name "region")
    )
    foreach ($candidate in $regionCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $regionCode = Normalize-VariantRegionCode -Value $candidate
        break
      }
    }

    $trendSummary = Get-VariantObjectPropertyValue -Value $payload -Name "trend_summary"
    if ($null -ne $trendSummary) {
      if ($trendSummary.PSObject.Properties.Name -contains "segments") {
        $segments = @($trendSummary.segments)
      }
      elseif ($trendSummary -is [System.Array]) {
        $segments = @($trendSummary)
      }
    }
  }

  return [pscustomobject]@{
    language_code = $languageCode
    region_code = $regionCode
    segments = @($segments)
  }
}

function Get-LanguageAwareVariantSelection {
  param([Parameter(Mandatory = $true)][object]$Task)

  $input = Get-VariantSelectionInput -Task $Task
  $languageCode = [string]$input.language_code
  $regionCode = [string]$input.region_code
  $segments = @($input.segments)

  $defaultMap = Get-VariantSelectionDefaults
  $fallbackVariant = if ($defaultMap.ContainsKey($languageCode)) { [string]$defaultMap[$languageCode] } else { [string]$defaultMap["en"] }

  $candidates = New-Object System.Collections.Generic.List[object]
  foreach ($s in $segments) {
    if ($null -eq $s) { continue }
    $segLang = Normalize-VariantLanguageCode -Value ([string]$s.language_code)
    $segRegion = Normalize-VariantRegionCode -Value ([string]$s.region_code)
    if ($segLang -ne $languageCode) { continue }
    if ($segRegion -ne "ZZ" -and $regionCode -ne "ZZ" -and $segRegion -ne $regionCode) { continue }

    $variantId = ([string]$s.variant_id).Trim()
    if ([string]::IsNullOrWhiteSpace($variantId)) { continue }

    $ctrBps = 0
    [void][int]::TryParse([string]$s.ctr_bps, [ref]$ctrBps)
    $conversionBps = 0
    [void][int]::TryParse([string]$s.conversion_bps, [ref]$conversionBps)
    $impressions = 0
    [void][int]::TryParse([string]$s.impressions, [ref]$impressions)

    $score = ([int]$conversionBps * 1000) + ([int]$ctrBps * 10) + [int]$impressions
    [void]$candidates.Add([pscustomobject]@{
      variant_id = $variantId
      score = [int]$score
    })
  }

  if ($candidates.Count -eq 0) {
    return [pscustomobject]@{
      selected_variant_id = $fallbackVariant
      selection_reason_codes = @("variant_lang_tiebreak")
      confidence_band = "low"
      language_code = $languageCode
      region_code = $regionCode
    }
  }

  # Stable sort order is part of the contract: higher score wins, ties break by variant_id ascending.
  $ordered = @(
    @($candidates.ToArray()) |
      Sort-Object -Property @{ Expression = { -[int]$_.score } }, @{ Expression = { [string]$_.variant_id } }
  )

  $top = $ordered[0]
  $topScore = [int]$top.score
  $secondScore = if ($ordered.Count -gt 1) { [int]$ordered[1].score } else { -2147483648 }
  $tied = ($ordered.Count -gt 1 -and $topScore -eq $secondScore)

  $reasonCodes = New-Object System.Collections.Generic.List[string]
  if ($tied) {
    [void]$reasonCodes.Add("variant_lang_tiebreak")
  }
  else {
    [void]$reasonCodes.Add("variant_lang_perf_win")
  }

  $confidenceBand = "low"
  if ($topScore -gt 0 -and ($topScore - $secondScore) -ge 1000) {
    $confidenceBand = "high"
  }
  elseif ($topScore -gt 0) {
    $confidenceBand = "medium"
  }

  return [pscustomobject]@{
    selected_variant_id = [string]$top.variant_id
    selection_reason_codes = @($reasonCodes.ToArray())
    confidence_band = $confidenceBand
    language_code = $languageCode
    region_code = $regionCode
  }
}
