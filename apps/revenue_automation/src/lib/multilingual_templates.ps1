Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Test-RevenueObjectLike {
  param([object]$Value)
  if ($null -eq $Value) { return $false }
  return (($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject]))
}

function Get-RevenueObjectPropertyNames {
  param([object]$Value)
  if ($null -eq $Value) { return @() }
  if ($Value -is [System.Collections.IDictionary]) {
    return @($Value.Keys | ForEach-Object { [string]$_ })
  }
  return @($Value.PSObject.Properties.Name)
}

function Get-RevenueObjectPropertyValue {
  param(
    [object]$Value,
    [Parameter(Mandatory = $true)][string]$Name
  )
  if ($null -eq $Value) { return $null }
  if ($Value -is [System.Collections.IDictionary]) {
    if ($Value.Contains($Name)) { return $Value[$Name] }
    return $null
  }
  if (-not ((Get-RevenueObjectPropertyNames -Value $Value) -contains $Name)) {
    return $null
  }
  return $Value.$Name
}

function Normalize-TemplateLanguageCode {
  param([string]$Value)
  if ([string]::IsNullOrWhiteSpace($Value)) { return "" }
  $parts = ([string]$Value).Trim().ToLowerInvariant() -split "[-_]"
  if ($parts.Count -eq 0) { return "" }
  return [string]$parts[0]
}

function Get-LanguageProfileResolution {
  param([Parameter(Mandatory = $true)][object]$Task)

  $payload = Get-RevenueObjectPropertyValue -Value $Task -Name "payload"
  $languageInput = ""
  $regionInput = ""

  if (Test-RevenueObjectLike -Value $payload) {
    $languageCandidates = @(
      [string](Get-RevenueObjectPropertyValue -Value $payload -Name "detected_language"),
      [string](Get-RevenueObjectPropertyValue -Value $payload -Name "language_code"),
      [string](Get-RevenueObjectPropertyValue -Value $payload -Name "language"),
      [string](Get-RevenueObjectPropertyValue -Value $payload -Name "locale")
    )

    foreach ($candidate in $languageCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $languageInput = [string]$candidate
        break
      }
    }

    $regionCandidates = @(
      [string](Get-RevenueObjectPropertyValue -Value $payload -Name "region_code"),
      [string](Get-RevenueObjectPropertyValue -Value $payload -Name "region")
    )
    foreach ($candidate in $regionCandidates) {
      if (-not [string]::IsNullOrWhiteSpace($candidate)) {
        $regionInput = [string]$candidate
        break
      }
    }
  }

  if ([string]::IsNullOrWhiteSpace($languageInput)) {
    $languageInput = "en"
  }

  $normalizedLanguage = Normalize-TemplateLanguageCode -Value $languageInput
  if ([string]::IsNullOrWhiteSpace($normalizedLanguage)) {
    $normalizedLanguage = "en"
  }

  $profileKey = $normalizedLanguage
  $profileReasonCodes = New-Object System.Collections.Generic.List[string]

  $resolverPath = Join-Path $PSScriptRoot "..\..\..\..\core\localization\profile_resolver.ps1"
  if (Test-Path -Path $resolverPath -PathType Leaf) {
    . $resolverPath
    $resolved = Resolve-LocalizationProfile -LanguageCodeInput $languageInput -RegionCodeInput $regionInput
    if ($null -ne $resolved -and -not [string]::IsNullOrWhiteSpace([string]$resolved.profile_key)) {
      $profileKey = ([string]$resolved.profile_key).Trim().ToLowerInvariant()
    }
    foreach ($rc in @($resolved.reason_codes)) {
      if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
        [void]$profileReasonCodes.Add([string]$rc)
      }
    }
  }

  return [pscustomobject]@{
    language_input = $languageInput
    normalized_language = $normalizedLanguage
    profile_key = $profileKey
    reason_codes = @($profileReasonCodes.ToArray())
  }
}

function Get-LocalizedTemplateCatalog {
  return @{
    en = @{
      pro = [pscustomobject]@{
        ad_copy = "Priority automation that captures and converts high-intent leads this week."
        short_reply_templates = @(
          "Happy to share a 14-day rollout plan tailored to your funnel.",
          "I can map expected ROI and execution steps in one page.",
          "If useful, we can start with a focused pilot and measurable targets."
        )
        cta_buy_text = "Start Pro"
        cta_subscribe_text = "Subscribe for weekly updates"
      }
      starter = [pscustomobject]@{
        ad_copy = "Starter automation to improve response speed and lead follow-through."
        short_reply_templates = @(
          "This is a practical starting point with predictable weekly output.",
          "You can begin small and scale once conversion data is in.",
          "Starter keeps setup lean while improving pipeline consistency."
        )
        cta_buy_text = "Start Starter"
        cta_subscribe_text = "Subscribe for roadmap updates"
      }
      free = [pscustomobject]@{
        ad_copy = "Free baseline automation templates to validate fit before upgrading."
        short_reply_templates = @(
          "Free mode is a low-risk way to test relevance and timing.",
          "Start with the baseline template pack and upgrade when ready.",
          "You can subscribe for implementation tips and examples."
        )
        cta_buy_text = "Use Free Plan"
        cta_subscribe_text = "Subscribe for free playbooks"
      }
    }
    es = @{
      pro = [pscustomobject]@{
        ad_copy = "Automatizacion prioritaria para captar y convertir leads de alta intencion esta semana."
        short_reply_templates = @(
          "Puedo compartir un plan de despliegue de 14 dias para tu embudo.",
          "Te envio ROI esperado y pasos de ejecucion en una sola pagina.",
          "Si te sirve, empezamos con un piloto enfocado y metas medibles."
        )
        cta_buy_text = "Iniciar Pro"
        cta_subscribe_text = "Suscribirse a novedades semanales"
      }
      starter = [pscustomobject]@{
        ad_copy = "Automatizacion Starter para mejorar respuesta y seguimiento de leads."
        short_reply_templates = @(
          "Es un punto de partida practico con salida semanal predecible.",
          "Puedes empezar pequeno y escalar con datos de conversion.",
          "Starter mantiene el setup liviano y mejora consistencia comercial."
        )
        cta_buy_text = "Iniciar Starter"
        cta_subscribe_text = "Suscribirse a novedades del roadmap"
      }
      free = [pscustomobject]@{
        ad_copy = "Plantillas gratuitas de automatizacion para validar ajuste antes de escalar."
        short_reply_templates = @(
          "El plan gratuito permite validar relevancia con riesgo bajo.",
          "Empieza con plantilla base y mejora cuando haya traccion.",
          "Puedes suscribirte para recibir guias y ejemplos."
        )
        cta_buy_text = "Usar plan Gratis"
        cta_subscribe_text = "Suscribirse a recursos gratis"
      }
    }
  }
}

function Merge-ProposalWithLocalizedTemplates {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$Proposal
  )

  $catalog = Get-LocalizedTemplateCatalog
  $resolution = Get-LanguageProfileResolution -Task $Task

  $tier = ([string](Get-RevenueObjectPropertyValue -Value $Proposal -Name "tier")).Trim().ToLowerInvariant()
  if ([string]::IsNullOrWhiteSpace($tier)) { $tier = "free" }

  $templateLanguage = "en"
  if ($catalog.ContainsKey([string]$resolution.profile_key)) {
    $templateLanguage = [string]$resolution.profile_key
  }
  elseif ($catalog.ContainsKey([string]$resolution.normalized_language)) {
    $templateLanguage = [string]$resolution.normalized_language
  }

  if (-not ($catalog[$templateLanguage].ContainsKey($tier))) {
    $tier = "free"
  }

  $templateData = $catalog[$templateLanguage][$tier]
  $templateReasonCode = if ($templateLanguage -eq [string]$resolution.normalized_language) { "template_lang_native" } else { "template_lang_fallback_en" }

  $proposalReasonCodes = New-Object System.Collections.Generic.List[string]
  foreach ($rc in @($Proposal.reason_codes)) {
    if (-not [string]::IsNullOrWhiteSpace([string]$rc)) {
      [void]$proposalReasonCodes.Add([string]$rc)
    }
  }
  [void]$proposalReasonCodes.Add($templateReasonCode)

  return [pscustomobject]@{
    proposal = [pscustomobject]@{
      proposal_id = [string](Get-RevenueObjectPropertyValue -Value $Proposal -Name "proposal_id")
      tier = [string](Get-RevenueObjectPropertyValue -Value $Proposal -Name "tier")
      headline = [string](Get-RevenueObjectPropertyValue -Value $Proposal -Name "headline")
      monthly_price_usd = [int](Get-RevenueObjectPropertyValue -Value $Proposal -Name "monthly_price_usd")
      setup_fee_usd = [int](Get-RevenueObjectPropertyValue -Value $Proposal -Name "setup_fee_usd")
      due_now_usd = [int](Get-RevenueObjectPropertyValue -Value $Proposal -Name "due_now_usd")
      checkout_stub = [string](Get-RevenueObjectPropertyValue -Value $Proposal -Name "checkout_stub")
      reason_codes = @($proposalReasonCodes | Select-Object -Unique)
      ad_copy = [string]$templateData.ad_copy
      short_reply_templates = @($templateData.short_reply_templates | ForEach-Object { [string]$_ })
      cta_buy_text = [string]$templateData.cta_buy_text
      cta_subscribe_text = [string]$templateData.cta_subscribe_text
      template_language = [string]$templateLanguage
      template_profile_key = [string]$resolution.profile_key
    }
    reason_codes = @($templateReasonCode)
  }
}
