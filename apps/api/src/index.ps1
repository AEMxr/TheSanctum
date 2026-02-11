param(
  [string]$InputText = "",
  [string]$SourceChannel = "unknown",
  [string]$InputJsonPath = "",
  [string]$OutFile = ""
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

function Get-LanguageDetectionInput {
  param(
    [string]$JsonPath,
    [string]$FallbackText,
    [string]$FallbackChannel
  )

  if ([string]::IsNullOrWhiteSpace($JsonPath)) {
    return [pscustomobject]@{
      input_text = $FallbackText
      source_channel = $FallbackChannel
    }
  }

  if (-not (Test-Path -Path $JsonPath -PathType Leaf)) {
    throw "InputJsonPath not found: $JsonPath"
  }

  $obj = Get-Content -Path $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json
  return [pscustomobject]@{
    input_text = if ($obj.PSObject.Properties.Name -contains "input_text") { [string]$obj.input_text } else { $FallbackText }
    source_channel = if ($obj.PSObject.Properties.Name -contains "source_channel") { [string]$obj.source_channel } else { $FallbackChannel }
  }
}

$isDotSourced = $MyInvocation.InvocationName -eq "."
if (-not $isDotSourced) {
  $input = Get-LanguageDetectionInput -JsonPath $InputJsonPath -FallbackText $InputText -FallbackChannel $SourceChannel
  $result = Invoke-LanguageDetection -Text $input.input_text -Channel $input.source_channel
  $json = $result | ConvertTo-Json -Depth 10
  if ([string]::IsNullOrWhiteSpace($OutFile)) {
    Write-Output $json
  }
  else {
    $json | Set-Content -Path $OutFile -Encoding UTF8
  }
}
