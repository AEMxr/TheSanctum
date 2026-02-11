# apps/api/tests/api.contract.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester apps/api/tests/api.contract.Tests.ps1

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

Describe "language detection API contract" {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $apiRoot = Resolve-Path (Join-Path $here "..")
    $script:IndexPath = Join-Path $apiRoot "src/index.ps1"

    if (-not (Test-Path -Path $script:IndexPath -PathType Leaf)) {
      throw "Missing API index script: $script:IndexPath"
    }

    . $script:IndexPath
  }

  Context "contract shape" {
    It "returns contract with required request and response fields" {
      $contract = Get-LanguageDetectionContract
      Assert-Equal -Actual ([string]$contract.contract_name) -Expected "language_detection" -Message "Contract name mismatch."
      Assert-Contains -Collection @($contract.request.required) -Value "input_text" -Message "request.required missing input_text."
      Assert-Contains -Collection @($contract.request.required) -Value "source_channel" -Message "request.required missing source_channel."
      Assert-Contains -Collection @($contract.response.required) -Value "detected_language" -Message "response.required missing detected_language."
      Assert-Contains -Collection @($contract.response.required) -Value "confidence_band" -Message "response.required missing confidence_band."
      Assert-Contains -Collection @($contract.response.required) -Value "reason_codes" -Message "response.required missing reason_codes."
      Assert-Contains -Collection @($contract.response.properties.confidence_band.enum) -Value "low" -Message "confidence_band enum missing low."
      Assert-Contains -Collection @($contract.response.properties.confidence_band.enum) -Value "medium" -Message "confidence_band enum missing medium."
      Assert-Contains -Collection @($contract.response.properties.confidence_band.enum) -Value "high" -Message "confidence_band enum missing high."
    }
  }

  Context "detection behavior" {
    It "detects spanish with deterministic reason code" {
      $result = Invoke-LanguageDetection -Text "hola gracias oferta cliente servicio automatizacion" -Channel "reddit"
      Assert-Equal -Actual ([string]$result.detected_language) -Expected "es" -Message "Spanish detection mismatch."
      Assert-Equal -Actual ([string]$result.confidence_band) -Expected "high" -Message "Spanish confidence mismatch."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_detect_high_conf" -Message "Spanish reason code mismatch."
    }

    It "falls back to und for unknown text" {
      $result = Invoke-LanguageDetection -Text "qwrty zxcvb nnnn" -Channel "x"
      Assert-Equal -Actual ([string]$result.detected_language) -Expected "und" -Message "Unknown fallback language mismatch."
      Assert-Equal -Actual ([string]$result.confidence_band) -Expected "low" -Message "Unknown fallback confidence mismatch."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_detect_unknown" -Message "Unknown fallback reason mismatch."
    }

    It "falls back to und for ambiguous ties" {
      $result = Invoke-LanguageDetection -Text "offer oferta" -Channel "web"
      Assert-Equal -Actual ([string]$result.detected_language) -Expected "und" -Message "Ambiguous fallback language mismatch."
      Assert-Equal -Actual ([string]$result.confidence_band) -Expected "medium" -Message "Ambiguous fallback confidence mismatch."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_detect_ambiguous" -Message "Ambiguous fallback reason mismatch."
    }

    It "is deterministic for repeated same input" {
      $a = Invoke-LanguageDetection -Text "hello thanks offer client service automation business" -Channel "reddit"
      $b = Invoke-LanguageDetection -Text "hello thanks offer client service automation business" -Channel "reddit"
      Assert-Equal -Actual ($a | ConvertTo-Json -Depth 10 -Compress) -Expected ($b | ConvertTo-Json -Depth 10 -Compress) -Message "Repeated input output mismatch."
    }
  }
}
