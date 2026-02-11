param(
  [string]$InputText = "",
  [string]$SourceChannel = "unknown",
  [string]$InputJsonPath = "",
  [string]$OutFile = "",
  [string]$Mode = "detect",
  [string]$SourceLanguage = "",
  [string]$TargetLanguage = "",
  [switch]$Health
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Get-LanguageDetectionContract {
  $contractPath = Join-Path $PSScriptRoot "contracts/language_detection.contract.json"
  if (-not (Test-Path -Path $contractPath -PathType Leaf)) {
    throw "Missing contract file: $contractPath"
  }
  return Get-Content -Path $contractPath -Raw -Encoding UTF8 | ConvertFrom-Json
}

function Get-LanguageTokenMap {
  return [ordered]@{
    de = @("hallo", "danke", "angebot", "kunde", "dienst", "automatisierung", "unternehmen")
    en = @("hello", "thanks", "offer", "client", "service", "automation", "business")
    es = @("hola", "gracias", "oferta", "cliente", "servicio", "automatizacion", "negocio")
    fr = @("bonjour", "merci", "offre", "client", "service", "automatisation", "entreprise")
    pt = @("ola", "obrigado", "oferta", "cliente", "servico", "automacao", "negocio")
  }
}

function Get-LanguageConceptMap {
  return @{
    hello = @{ en = "hello"; es = "hola"; pt = "ola"; fr = "bonjour"; de = "hallo" }
    thanks = @{ en = "thanks"; es = "gracias"; pt = "obrigado"; fr = "merci"; de = "danke" }
    offer = @{ en = "offer"; es = "oferta"; pt = "oferta"; fr = "offre"; de = "angebot" }
    client = @{ en = "client"; es = "cliente"; pt = "cliente"; fr = "client"; de = "kunde" }
    service = @{ en = "service"; es = "servicio"; pt = "servico"; fr = "service"; de = "dienst" }
    automation = @{ en = "automation"; es = "automatizacion"; pt = "automacao"; fr = "automatisation"; de = "automatisierung" }
    business = @{ en = "business"; es = "negocio"; pt = "negocio"; fr = "entreprise"; de = "unternehmen" }
  }
}

function Get-SupportedLanguageCodes {
  return @("de", "en", "es", "fr", "pt")
}

function Get-LanguageApiHealthPayload {
  return [pscustomobject]@{
    service = "language_api"
    status = "ok"
    ready = $true
    mode_default = "detect"
    supported_modes = @("detect", "convert", "detect_and_convert")
    supported_languages = @(Get-SupportedLanguageCodes | Sort-Object)
  }
}

function Normalize-LanguageCode {
  param([string]$Value)

  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $parts = ([string]$Value).Trim().ToLowerInvariant() -split "[-_]"
  if ($parts.Count -eq 0) { return "" }
  return [string]$parts[0]
}

function Normalize-ApiMode {
  param([string]$Value)

  $normalized = if ([string]::IsNullOrWhiteSpace($Value)) { "detect" } else { ([string]$Value).Trim().ToLowerInvariant() }
  if ($normalized -notin @("detect", "convert", "detect_and_convert")) {
    throw "mode must be one of: detect|convert|detect_and_convert"
  }
  return $normalized
}

function Get-TokenScore {
  param(
    [string]$Text,
    [string[]]$Tokens
  )
  $score = 0
  foreach ($token in $Tokens) {
    $pattern = "\b{0}\b" -f [regex]::Escape($token)
    if ($Text -match $pattern) {
      $score++
    }
  }
  return $score
}

function Invoke-LanguageDetection {
  param(
    [string]$Text,
    [string]$Channel
  )

  $normalizedText = if ($null -eq $Text) { "" } else { ([string]$Text).ToLowerInvariant() }
  $channelText = if ([string]::IsNullOrWhiteSpace($Channel)) { "unknown" } else { [string]$Channel }

  if ([string]::IsNullOrWhiteSpace($normalizedText)) {
    return [pscustomobject]@{
      input_text = [string]$Text
      source_channel = $channelText
      detected_language = "und"
      confidence_band = "low"
      reason_codes = @("lang_detect_unknown")
    }
  }

  $tokenMap = Get-LanguageTokenMap
  $scores = New-Object System.Collections.Generic.List[object]
  foreach ($lang in $tokenMap.Keys) {
    $score = Get-TokenScore -Text $normalizedText -Tokens $tokenMap[$lang]
    [void]$scores.Add([pscustomobject]@{
      language = $lang
      score = $score
    })
  }

  $orderedScores = @(
    $scores |
      Sort-Object -Property @{ Expression = "score"; Descending = $true }, @{ Expression = "language"; Descending = $false }
  )

  $top = $orderedScores[0]
  $secondScore = if ($orderedScores.Count -gt 1) { [int]$orderedScores[1].score } else { 0 }
  $topScore = [int]$top.score

  if ($topScore -eq 0) {
    return [pscustomobject]@{
      input_text = [string]$Text
      source_channel = $channelText
      detected_language = "und"
      confidence_band = "low"
      reason_codes = @("lang_detect_unknown")
    }
  }

  if ($topScore -eq $secondScore) {
    return [pscustomobject]@{
      input_text = [string]$Text
      source_channel = $channelText
      detected_language = "und"
      confidence_band = "medium"
      reason_codes = @("lang_detect_ambiguous")
    }
  }

  $confidence = "low"
  $reasonCode = "lang_detect_low_conf"
  if ($topScore -ge 3 -or (($topScore - $secondScore) -ge 2)) {
    $confidence = "high"
    $reasonCode = "lang_detect_high_conf"
  }
  elseif ($topScore -ge 2) {
    $confidence = "medium"
    $reasonCode = "lang_detect_medium_conf"
  }

  return [pscustomobject]@{
    input_text = [string]$Text
    source_channel = $channelText
    detected_language = [string]$top.language
    confidence_band = $confidence
    reason_codes = @($reasonCode)
  }
}

function Get-ConceptLookupByLanguage {
  param([Parameter(Mandatory = $true)][string]$LanguageCode)

  $lookup = @{}
  $conceptMap = Get-LanguageConceptMap
  foreach ($concept in $conceptMap.Keys) {
    $tokensByLanguage = $conceptMap[$concept]
    if ($tokensByLanguage.ContainsKey($LanguageCode)) {
      $token = ([string]$tokensByLanguage[$LanguageCode]).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($token)) {
        $lookup[$token] = $concept
      }
    }
  }

  return $lookup
}

function Get-TargetTokensByConcept {
  param([Parameter(Mandatory = $true)][string]$LanguageCode)

  $lookup = @{}
  $conceptMap = Get-LanguageConceptMap
  foreach ($concept in $conceptMap.Keys) {
    $tokensByLanguage = $conceptMap[$concept]
    if ($tokensByLanguage.ContainsKey($LanguageCode)) {
      $token = ([string]$tokensByLanguage[$LanguageCode]).Trim().ToLowerInvariant()
      if (-not [string]::IsNullOrWhiteSpace($token)) {
        $lookup[$concept] = $token
      }
    }
  }

  return $lookup
}

function Convert-DeterministicTextByConcept {
  param(
    [Parameter(Mandatory = $true)][string]$Text,
    [Parameter(Mandatory = $true)][string]$SourceLanguage,
    [Parameter(Mandatory = $true)][string]$TargetLanguage
  )

  $sourceLookup = Get-ConceptLookupByLanguage -LanguageCode $SourceLanguage
  $targetLookup = Get-TargetTokensByConcept -LanguageCode $TargetLanguage

  $parts = [regex]::Split([string]$Text, "(\W+)")
  $builder = New-Object System.Text.StringBuilder
  foreach ($part in $parts) {
    if ([string]::IsNullOrEmpty($part)) { continue }

    if ($part -match "^\W+$") {
      [void]$builder.Append($part)
      continue
    }

    $token = $part.ToLowerInvariant()
    if ($sourceLookup.ContainsKey($token)) {
      $concept = [string]$sourceLookup[$token]
      if ($targetLookup.ContainsKey($concept)) {
        [void]$builder.Append([string]$targetLookup[$concept])
      }
      else {
        [void]$builder.Append($token)
      }
    }
    else {
      [void]$builder.Append($part)
    }
  }

  return $builder.ToString()
}

function Invoke-LanguageConversion {
  param(
    [string]$Text,
    [string]$SourceLanguage,
    [string]$TargetLanguage
  )

  $supported = Get-SupportedLanguageCodes
  $source = Normalize-LanguageCode -Value $SourceLanguage
  $target = Normalize-LanguageCode -Value $TargetLanguage

  $reasonCodes = New-Object System.Collections.Generic.List[string]

  if ([string]::IsNullOrWhiteSpace($target)) {
    $target = "en"
    [void]$reasonCodes.Add("lang_convert_fallback")
  }

  if ($supported -notcontains $target) {
    $target = "en"
    [void]$reasonCodes.Add("lang_convert_unsupported_target")
  }

  if ([string]::IsNullOrWhiteSpace($source) -or $source -eq "und" -or ($supported -notcontains $source)) {
    $source = "en"
    [void]$reasonCodes.Add("lang_convert_fallback")
  }

  if ($source -eq $target) {
    [void]$reasonCodes.Add("lang_convert_native")
    return [pscustomobject]@{
      source_language = $source
      target_language = $target
      converted_text = [string]$Text
      conversion_applied = $false
      reason_codes = @($reasonCodes | Select-Object -Unique)
    }
  }

  $convertedText = Convert-DeterministicTextByConcept -Text ([string]$Text) -SourceLanguage $source -TargetLanguage $target
  [void]$reasonCodes.Add("lang_convert_fallback")

  return [pscustomobject]@{
    source_language = $source
    target_language = $target
    converted_text = [string]$convertedText
    conversion_applied = $true
    reason_codes = @($reasonCodes | Select-Object -Unique)
  }
}

function Get-LanguageDetectionInput {
  param(
    [string]$JsonPath,
    [string]$FallbackText,
    [string]$FallbackChannel,
    [string]$FallbackMode,
    [string]$FallbackSourceLanguage,
    [string]$FallbackTargetLanguage
  )

  if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    return [pscustomobject]@{
      input_text = $FallbackText
      source_channel = $FallbackChannel
      mode = $FallbackMode
      source_language = $FallbackSourceLanguage
      target_language = $FallbackTargetLanguage
    }
  }

  if (-not (Test-Path -Path $JsonPath -PathType Leaf)) {
    throw "InputJsonPath not found: $JsonPath"
  }

  $obj = Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  return [pscustomobject]@{
    input_text = if ($obj.PSObject.Properties.Name -contains "input_text") { [string]$obj.input_text } else { $FallbackText }
    source_channel = if ($obj.PSObject.Properties.Name -contains "source_channel") { [string]$obj.source_channel } else { $FallbackChannel }
    mode = if ($obj.PSObject.Properties.Name -contains "mode") { [string]$obj.mode } else { $FallbackMode }
    source_language = if ($obj.PSObject.Properties.Name -contains "source_language") { [string]$obj.source_language } else { $FallbackSourceLanguage }
    target_language = if ($obj.PSObject.Properties.Name -contains "target_language") { [string]$obj.target_language } else { $FallbackTargetLanguage }
  }
}

function Invoke-LanguageApi {
  param(
    [string]$Text,
    [string]$Channel,
    [string]$Mode,
    [string]$SourceLanguage,
    [string]$TargetLanguage
  )

  $resolvedMode = Normalize-ApiMode -Value $Mode
  $detected = Invoke-LanguageDetection -Text $Text -Channel $Channel

  $reasonCodes = New-Object System.Collections.Generic.List[string]
  foreach ($rc in @($detected.reason_codes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$reasonCodes.Add([string]$rc)
    }
  }

  $resolvedSourceLanguage = Normalize-LanguageCode -Value $SourceLanguage
  if ([string]::IsNullOrWhiteSpace($resolvedSourceLanguage)) {
    $resolvedSourceLanguage = [string]$detected.detected_language
  }

  $resolvedTargetLanguage = Normalize-LanguageCode -Value $TargetLanguage
  $convertedText = $null
  $conversionApplied = $false

  if ($resolvedMode -in @("convert", "detect_and_convert")) {
    if ($resolvedMode -eq "detect_and_convert") {
      $resolvedSourceLanguage = [string]$detected.detected_language
    }

    $conversion = Invoke-LanguageConversion -Text $Text -SourceLanguage $resolvedSourceLanguage -TargetLanguage $resolvedTargetLanguage
    $resolvedSourceLanguage = [string]$conversion.source_language
    $resolvedTargetLanguage = [string]$conversion.target_language
    $convertedText = [string]$conversion.converted_text
    $conversionApplied = [bool]$conversion.conversion_applied

    foreach ($rc in @($conversion.reason_codes)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
        [void]$reasonCodes.Add([string]$rc)
      }
    }
  }
  else {
    if ([string]::IsNullOrWhiteSpace($resolvedSourceLanguage)) {
      $resolvedSourceLanguage = [string]$detected.detected_language
    }
    $resolvedTargetLanguage = ""
  }

  return [pscustomobject]@{
    input_text = [string]$Text
    source_channel = if ([string]::IsNullOrWhiteSpace($Channel)) { "unknown" } else { [string]$Channel }
    mode = $resolvedMode
    source_language = if ([string]::IsNullOrWhiteSpace($resolvedSourceLanguage)) { "und" } else { $resolvedSourceLanguage }
    target_language = $resolvedTargetLanguage
    detected_language = [string]$detected.detected_language
    confidence_band = [string]$detected.confidence_band
    converted_text = $convertedText
    conversion_applied = $conversionApplied
    reason_codes = @($reasonCodes | Select-Object -Unique)
  }
}

$isDotSourced = $MyInvocation.InvocationName -eq "."
if (-not $isDotSourced) {
  if ($Health) {
    $healthPayload = Get-LanguageApiHealthPayload
    $healthJson = $healthPayload | ConvertTo-Json -Depth 20
    if ([string]::IsNullOrWhiteSpace($OutFile)) {
      Write-Output $healthJson
    }
    else {
      $healthJson | Set-Content -Path $OutFile -Encoding UTF8
    }
    exit 0
  }

  $input = Get-LanguageDetectionInput `
    -JsonPath $InputJsonPath `
    -FallbackText $InputText `
    -FallbackChannel $SourceChannel `
    -FallbackMode $Mode `
    -FallbackSourceLanguage $SourceLanguage `
    -FallbackTargetLanguage $TargetLanguage

  $result = Invoke-LanguageApi `
    -Text $input.input_text `
    -Channel $input.source_channel `
    -Mode $input.mode `
    -SourceLanguage $input.source_language `
    -TargetLanguage $input.target_language

  $json = $result | ConvertTo-Json -Depth 20
  if ([string]::IsNullOrWhiteSpace($OutFile)) {
    Write-Output $json
  }
  else {
    $json | Set-Content -Path $OutFile -Encoding UTF8
  }
}
