# apps/core/tests/localization_profiles.Tests.ps1
# Pester 3.x / 5.x compatible

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message = "Assertion failed."
  )
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param(
    $Actual,
    $Expected,
    [string]$Message = "Values are not equal."
  )
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-Contains {
  param(
    [object[]]$Collection,
    $Value,
    [string]$Message = "Collection does not contain expected value."
  )
  if (-not ($Collection -contains $Value)) {
    throw "$Message`nExpected value: $Value"
  }
}

Describe "localization profile resolver" {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $coreRoot = Resolve-Path (Join-Path $here "..")
    $script:ResolverPath = Join-Path $coreRoot "localization/profile_resolver.ps1"
    if (-not (Test-Path -Path $script:ResolverPath -PathType Leaf)) {
      throw "Missing resolver: $script:ResolverPath"
    }
    . $script:ResolverPath
  }

  It "contains required base profiles" {
    $registry = Get-LocalizationProfiles
    $keys = @($registry.profiles.PSObject.Properties.Name)
    Assert-Contains -Collection $keys -Value "en" -Message "Missing profile key en."
    Assert-Contains -Collection $keys -Value "es" -Message "Missing profile key es."
    Assert-Contains -Collection $keys -Value "pt" -Message "Missing profile key pt."
    Assert-Contains -Collection $keys -Value "fr" -Message "Missing profile key fr."
    Assert-Contains -Collection $keys -Value "de" -Message "Missing profile key de."
  }

  It "resolves exact language match deterministically" {
    $result = Resolve-LocalizationProfile -LanguageCodeInput "fr" -RegionCodeInput "FR"
    Assert-Equal -Actual ([string]$result.profile_key) -Expected "fr" -Message "Expected fr profile key."
    Assert-Contains -Collection @($result.reason_codes) -Value "profile_exact_match" -Message "Expected exact match reason code."
  }

  It "falls back language for regional code deterministically (es-MX -> es)" {
    $result = Resolve-LocalizationProfile -LanguageCodeInput "es-MX" -RegionCodeInput "MX"
    Assert-Equal -Actual ([string]$result.profile_key) -Expected "es" -Message "Expected es fallback profile key."
    Assert-Contains -Collection @($result.reason_codes) -Value "profile_exact_match" -Message "Expected language exact match after normalization."
  }

  It "falls back to global default for unsupported language" {
    $result = Resolve-LocalizationProfile -LanguageCodeInput "it-IT" -RegionCodeInput "IT"
    Assert-Equal -Actual ([string]$result.profile_key) -Expected "en" -Message "Expected global default profile key."
    Assert-Contains -Collection @($result.reason_codes) -Value "profile_language_fallback" -Message "Expected language fallback reason."
    Assert-Contains -Collection @($result.reason_codes) -Value "profile_global_fallback" -Message "Expected global fallback reason."
  }

  It "returns stable output for repeated same input" {
    $a = Resolve-LocalizationProfile -LanguageCodeInput "de-DE" -RegionCodeInput "DE"
    $b = Resolve-LocalizationProfile -LanguageCodeInput "de-DE" -RegionCodeInput "DE"
    Assert-Equal -Actual ($a | ConvertTo-Json -Depth 20 -Compress) -Expected ($b | ConvertTo-Json -Depth 20 -Compress) -Message "Resolver output must be deterministic."
  }
}
