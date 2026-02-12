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
      Assert-Contains -Collection @($contract.request.properties.mode.enum) -Value "detect" -Message "mode enum missing detect."
      Assert-Contains -Collection @($contract.request.properties.mode.enum) -Value "convert" -Message "mode enum missing convert."
      Assert-Contains -Collection @($contract.request.properties.mode.enum) -Value "detect_and_convert" -Message "mode enum missing detect_and_convert."

      Assert-Contains -Collection @($contract.response.required) -Value "mode" -Message "response.required missing mode."
      Assert-Contains -Collection @($contract.response.required) -Value "source_language" -Message "response.required missing source_language."
      Assert-Contains -Collection @($contract.response.required) -Value "target_language" -Message "response.required missing target_language."
      Assert-Contains -Collection @($contract.response.required) -Value "detected_language" -Message "response.required missing detected_language."
      Assert-Contains -Collection @($contract.response.required) -Value "confidence_band" -Message "response.required missing confidence_band."
      Assert-Contains -Collection @($contract.response.required) -Value "converted_text" -Message "response.required missing converted_text."
      Assert-Contains -Collection @($contract.response.required) -Value "conversion_applied" -Message "response.required missing conversion_applied."
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

  Context "mode behavior" {
    It "supports detect mode without conversion side effects" {
      $result = Invoke-LanguageApi -Text "hola gracias oferta cliente servicio automatizacion" -Channel "reddit" -Mode "detect" -SourceLanguage "" -TargetLanguage ""
      Assert-Equal -Actual ([string]$result.mode) -Expected "detect" -Message "Detect mode mismatch."
      Assert-Equal -Actual ([string]$result.detected_language) -Expected "es" -Message "Detect mode language mismatch."
      Assert-Equal -Actual ([bool]$result.conversion_applied) -Expected $false -Message "Detect mode must not apply conversion."
      Assert-Equal -Actual ([string]$result.target_language) -Expected "" -Message "Detect mode target_language should be blank."
      Assert-Equal -Actual $result.converted_text -Expected $null -Message "Detect mode converted_text should be null."
    }

    It "supports detect_and_convert with deterministic fallback reason" {
      $result = Invoke-LanguageApi -Text "hola gracias oferta cliente servicio automatizacion negocio" -Channel "reddit" -Mode "detect_and_convert" -SourceLanguage "" -TargetLanguage "en"
      Assert-Equal -Actual ([string]$result.mode) -Expected "detect_and_convert" -Message "detect_and_convert mode mismatch."
      Assert-Equal -Actual ([string]$result.detected_language) -Expected "es" -Message "detect_and_convert language mismatch."
      Assert-Equal -Actual ([string]$result.target_language) -Expected "en" -Message "detect_and_convert target language mismatch."
      Assert-Equal -Actual ([bool]$result.conversion_applied) -Expected $true -Message "detect_and_convert should apply conversion."
      Assert-Equal -Actual ([string]$result.converted_text) -Expected "hello thanks offer client service automation business" -Message "detect_and_convert converted text mismatch."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_detect_high_conf" -Message "detect_and_convert should include detection reason code."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_convert_fallback" -Message "detect_and_convert should include conversion reason code."
    }

    It "supports explicit convert mode with source and target language" {
      $result = Invoke-LanguageApi -Text "hello offer client service automation business" -Channel "web" -Mode "convert" -SourceLanguage "en" -TargetLanguage "es"
      Assert-Equal -Actual ([string]$result.mode) -Expected "convert" -Message "Convert mode mismatch."
      Assert-Equal -Actual ([string]$result.source_language) -Expected "en" -Message "Convert mode source language mismatch."
      Assert-Equal -Actual ([string]$result.target_language) -Expected "es" -Message "Convert mode target language mismatch."
      Assert-Equal -Actual ([bool]$result.conversion_applied) -Expected $true -Message "Convert mode should apply conversion."
      Assert-Equal -Actual ([string]$result.converted_text) -Expected "hola oferta cliente servicio automatizacion negocio" -Message "Convert mode converted text mismatch."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_convert_fallback" -Message "Convert mode should include conversion reason code."
    }

    It "falls back deterministically on unsupported target language" {
      $result = Invoke-LanguageApi -Text "hello offer client" -Channel "web" -Mode "convert" -SourceLanguage "en" -TargetLanguage "it"
      Assert-Equal -Actual ([string]$result.target_language) -Expected "en" -Message "Unsupported target should fallback to en."
      Assert-Equal -Actual ([bool]$result.conversion_applied) -Expected $false -Message "Unsupported target fallback to same language should not apply conversion."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_convert_unsupported_target" -Message "Unsupported target reason code missing."
      Assert-Contains -Collection @($result.reason_codes) -Value "lang_convert_native" -Message "Native fallback reason code missing."
    }

    It "is deterministic for repeated convert input" {
      $a = Invoke-LanguageApi -Text "hello thanks offer" -Channel "reddit" -Mode "convert" -SourceLanguage "en" -TargetLanguage "fr"
      $b = Invoke-LanguageApi -Text "hello thanks offer" -Channel "reddit" -Mode "convert" -SourceLanguage "en" -TargetLanguage "fr"
      Assert-Equal -Actual ($a | ConvertTo-Json -Depth 20 -Compress) -Expected ($b | ConvertTo-Json -Depth 20 -Compress) -Message "Repeated convert input output mismatch."
    }
  }

  Context "api key hash auth behavior" {
    It "authenticates hash-only key entries" {
      $hashOnlyKey = "hash-only-auth-key"
      $hash = Get-Sha256Hex -Text $hashOnlyKey
      $configObject = [pscustomobject]@{
        http = [pscustomobject]@{
          api_keys = @(
            [pscustomobject]@{
              key_id = "hash-only-admin"
              key_sha256 = $hash
              role = "admin"
            }
          )
        }
      }

      $runtime = Get-ApiHttpConfig `
        -ServiceName "language_api_hash_only_test" `
        -ConfigObject $configObject `
        -DefaultPort 18081 `
        -DefaultUsageLedgerPath "apps/api/artifacts/usage/language_api_usage.hash_only_test.jsonl" `
        -DefaultSchemaVersion "language-api-http-v1"

      $principal = Get-ApiKeyPrincipal -HttpConfig $runtime -ProvidedKey $hashOnlyKey
      Assert-True -Condition ($null -ne $principal) -Message "Hash-only API key should resolve a principal."
      Assert-Equal -Actual ([string]$principal.key_id) -Expected "hash-only-admin" -Message "Hash-only key_id mismatch."
      Assert-Equal -Actual ([string]$principal.role) -Expected "admin" -Message "Hash-only role mismatch."
    }

    It "rejects malformed key_sha256 entries" {
      $configObject = [pscustomobject]@{
        http = [pscustomobject]@{
          api_keys = @(
            [pscustomobject]@{
              key_id = "bad-hash-entry"
              key = "bad-hash-clear-key"
              key_sha256 = "not-a-valid-sha256-value"
              role = "admin"
            }
          )
        }
      }

      $runtime = Get-ApiHttpConfig `
        -ServiceName "language_api_bad_hash_test" `
        -ConfigObject $configObject `
        -DefaultPort 18081 `
        -DefaultUsageLedgerPath "apps/api/artifacts/usage/language_api_usage.bad_hash_test.jsonl" `
        -DefaultSchemaVersion "language-api-http-v1"

      $configuredKeyIds = @($runtime.api_keys | ForEach-Object { [string]$_.key_id })
      Assert-True -Condition (-not ($configuredKeyIds -contains "bad-hash-entry")) -Message "Malformed key_sha256 entry must be rejected from normalized config."

      $principal = Get-ApiKeyPrincipal -HttpConfig $runtime -ProvidedKey "bad-hash-clear-key"
      Assert-Equal -Actual $principal -Expected $null -Message "Malformed key_sha256 entry must not authenticate."
    }

    It "does not authenticate wrong clear key against hash-only entry" {
      $validKey = "equal-length-key-01"
      $wrongKey = "equal-length-key-99"
      $configObject = [pscustomobject]@{
        http = [pscustomobject]@{
          api_keys = @(
            [pscustomobject]@{
              key_id = "hash-only-standard"
              key_sha256 = (Get-Sha256Hex -Text $validKey)
              role = "standard"
            }
          )
        }
      }

      $runtime = Get-ApiHttpConfig `
        -ServiceName "language_api_wrong_key_test" `
        -ConfigObject $configObject `
        -DefaultPort 18081 `
        -DefaultUsageLedgerPath "apps/api/artifacts/usage/language_api_usage.wrong_key_test.jsonl" `
        -DefaultSchemaVersion "language-api-http-v1"

      $principal = Get-ApiKeyPrincipal -HttpConfig $runtime -ProvidedKey $wrongKey
      Assert-Equal -Actual $principal -Expected $null -Message "Wrong clear key must not authenticate against hash-only entry."
    }
  }

  Context "runtime health contract" {
    It "returns deterministic health payload shape with readiness keys" {
      $health = Get-LanguageApiHealthPayload
      Assert-Equal -Actual ([string]$health.service) -Expected "language_api" -Message "Health payload service mismatch."
      Assert-Equal -Actual ([string]$health.status) -Expected "ok" -Message "Health payload status mismatch."
      Assert-Equal -Actual ([bool]$health.ready) -Expected $true -Message "Health payload readiness mismatch."
      Assert-Equal -Actual ([string]$health.mode_default) -Expected "detect" -Message "Health payload default mode mismatch."

      $modes = @($health.supported_modes | ForEach-Object { [string]$_ })
      Assert-Contains -Collection $modes -Value "detect" -Message "Health payload supported_modes missing detect."
      Assert-Contains -Collection $modes -Value "convert" -Message "Health payload supported_modes missing convert."
      Assert-Contains -Collection $modes -Value "detect_and_convert" -Message "Health payload supported_modes missing detect_and_convert."

      $langs = @($health.supported_languages | ForEach-Object { [string]$_ })
      Assert-Contains -Collection $langs -Value "de" -Message "Health payload supported_languages missing de."
      Assert-Contains -Collection $langs -Value "en" -Message "Health payload supported_languages missing en."
      Assert-Contains -Collection $langs -Value "es" -Message "Health payload supported_languages missing es."
      Assert-Contains -Collection $langs -Value "fr" -Message "Health payload supported_languages missing fr."
      Assert-Contains -Collection $langs -Value "pt" -Message "Health payload supported_languages missing pt."
    }

    It "health mode CLI returns parseable readiness payload" {
      $output = @(& $script:IndexPath -Health 2>&1)
      $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      Assert-Equal -Actual $exitCode -Expected 0 -Message "Health mode CLI should exit 0."

      $raw = ($output -join [Environment]::NewLine)
      $health = $raw | ConvertFrom-Json
      Assert-Equal -Actual ([string]$health.service) -Expected "language_api" -Message "Health mode CLI service mismatch."
      Assert-Equal -Actual ([string]$health.status) -Expected "ok" -Message "Health mode CLI status mismatch."
      Assert-Equal -Actual ([bool]$health.ready) -Expected $true -Message "Health mode CLI readiness mismatch."
    }
  }
}
