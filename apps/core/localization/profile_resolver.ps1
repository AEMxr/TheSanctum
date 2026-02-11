param(
  [string]$LanguageCode = "",
  [string]$RegionCode = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-LocalizationProfilesPath {
  return Join-Path $PSScriptRoot "localization_profiles.json"
}

function Get-LocalizationProfiles {
  $path = Get-LocalizationProfilesPath
  if (-not (Test-Path -Path $path -PathType Leaf)) {
    throw "Localization profile registry not found: $path"
  }
  return Get-Content -Path $path -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Normalize-LanguageCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $lower = ([string]$Value).Trim().ToLowerInvariant()
  $parts = $lower -split "[-_]"
  if ($parts.Count -eq 0) { return "" }
  return $parts[0]
}

function Resolve-LocalizationProfile {
  param(
    [string]$LanguageCodeInput,
    [string]$RegionCodeInput
  )

  $registry = Get-LocalizationProfiles
  $profiles = $registry.profiles
  $defaultProfileKey = [string]$registry.default_profile
  $normalizedLanguage = Normalize-LanguageCode -Value $LanguageCodeInput
  $normalizedRegion = if ([string]::IsNullOrWhiteSpace($RegionCodeInput)) { "" } else { ([string]$RegionCodeInput).Trim().ToUpperInvariant() }

  $selectedKey = ""
  $reasonCodes = New-Object System.Collections.Generic.List[string]

  if (-not [string]::IsNullOrWhiteSpace($normalizedLanguage) -and ($profiles.PSObject.Properties.Name -contains $normalizedLanguage)) {
    $selectedKey = $normalizedLanguage
    [void]$reasonCodes.Add("profile_exact_match")
  }
  elseif (-not [string]::IsNullOrWhiteSpace($normalizedLanguage)) {
    [void]$reasonCodes.Add("profile_language_fallback")
  }

  if ([string]::IsNullOrWhiteSpace($selectedKey)) {
    $selectedKey = $defaultProfileKey
    if (-not ($reasonCodes -contains "profile_global_fallback")) {
      [void]$reasonCodes.Add("profile_global_fallback")
    }
  }

  $selectedProfile = $profiles.$selectedKey
  $profileReasonCodes = @()
  if ($null -ne $selectedProfile -and $selectedProfile.PSObject.Properties.Name -contains "reason_codes") {
    $profileReasonCodes = @($selectedProfile.reason_codes)
  }

  return [pscustomobject]@{
    language_code_input = if ($null -eq $LanguageCodeInput) { "" } else { [string]$LanguageCodeInput }
    region_code_input = if ($null -eq $RegionCodeInput) { "" } else { [string]$RegionCodeInput }
    language_code_normalized = $normalizedLanguage
    region_code_normalized = $normalizedRegion
    profile_key = $selectedKey
    profile = [pscustomobject]@{
      tone_style = [string]$selectedProfile.tone_style
      cta_style = [string]$selectedProfile.cta_style
      prohibited_patterns = @($selectedProfile.prohibited_patterns)
      default_currency = [string]$selectedProfile.default_currency
      reason_codes = @($profileReasonCodes)
    }
    reason_codes = @($reasonCodes.ToArray())
  }
}

$isDotSourced = $MyInvocation.InvocationName -eq "."
if (-not $isDotSourced) {
  $result = Resolve-LocalizationProfile -LanguageCodeInput $LanguageCode -RegionCodeInput $RegionCode
  Write-Output ($result | ConvertTo-Json -Depth 20)
}
