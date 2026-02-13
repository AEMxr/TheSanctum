Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param([bool]$Condition, [string]$Message = "Assertion failed.")
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param($Actual, $Expected, [string]$Message = "Values are not equal.")
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-Contains {
  param([object[]]$Collection, $Value, [string]$Message = "Collection missing value.")
  if (-not ($Collection -contains $Value)) {
    throw "$Message`nExpected value: $Value"
  }
}

function Write-JsonFile {
  param([string]$Path, [object]$Value)
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -Path $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Value | ConvertTo-Json -Depth 30 | Set-Content -Path $Path -Encoding UTF8
}

Describe "growth autopilot publish integration" {
  BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:ScriptPath = Join-Path $script:RepoRoot "scripts\dev\start_growth_autopilot.ps1"
    $script:PowerShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Assert-True -Condition (Test-Path -Path $script:ScriptPath -PathType Leaf) -Message "Missing script: $script:ScriptPath"
  }

  It "live mode auto-publishes only compliant allowlist channels and drafts everything else" {
    $runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("growth_publish_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $config = [pscustomobject]@{
      delivery_mode = "tenant_only"
      cross_sell_allowed = $false
      safe_mode = $false
      global_emergency_stop = $false
      default_daily_budget = 40
      default_max_posts_per_day = 3
      utm_template = "utm_source={channel}&utm_medium=growth_autopilot&utm_campaign={campaign_id}&utm_content={language_code}-{creative_id}"
      compliance = [pscustomobject]@{
        default_disclosure = "Sponsored content. Reply STOP to opt out."
      }
    }
    $campaign = [pscustomobject]@{
      campaign_id = "publish-test"
      keywords = @("lead response automation")
      target_languages = @("en")
      discovery_seed_channels = @("x", "reddit", "community_forum_unknown")
      tone = "professional"
      daily_budget_usd = 20
      max_posts_per_day = 2
      cost_per_post_usd = 3
      estimated_sale_value_usd = 100
      landing_url = "https://example.com/pilot"
    }

    $configPath = Join-Path $runRoot "config.json"
    $campaignPath = Join-Path $runRoot "campaign.json"
    Write-JsonFile -Path $configPath -Value $config
    Write-JsonFile -Path $campaignPath -Value $campaign

    try {
      $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptPath `
        -Mode live `
        -CampaignId "publish-test" `
        -Languages "en" `
        -ConfigPath $configPath `
        -CampaignPath $campaignPath `
        -AllowlistPath (Join-Path $script:RepoRoot "data\growth\allowlist.json") `
        -ArtifactsDir (Join-Path $runRoot "artifacts") `
        -StateDir (Join-Path $runRoot "state") `
        -MaxPostsPerDay 2 `
        -DailyBudget 20 `
        -LandingUrl "https://example.com/pilot" 2>&1
      $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      Assert-Equal -Actual $exitCode -Expected 0 -Message "Live publish run should exit 0."

      $posts = @((Get-Content -Path (Join-Path $runRoot "artifacts\growth_autopilot.posts.json") -Raw -Encoding UTF8 | ConvertFrom-Json))
      $drafts = @((Get-Content -Path (Join-Path $runRoot "artifacts\growth_autopilot.drafts.json") -Raw -Encoding UTF8 | ConvertFrom-Json))
      Assert-True -Condition ($posts.Count -gt 0) -Message "Live publish run should emit at least one auto-published action."
      Assert-True -Condition ($posts.Count -le 2) -Message "Live publish run must respect MaxPostsPerDay cap."

      foreach ($post in $posts) {
        Assert-Equal -Actual ([string]$post.channel) -Expected "x" -Message "Only allowlisted autopost channel should publish in this fixture."
        Assert-Contains -Collection @($post.reason_codes) -Value "autopost_allowed" -Message "Published actions must carry autopost_allowed reason."
      }

      $redditDraft = @($drafts | Where-Object { $_.channel -eq "reddit" } | Select-Object -First 1)
      Assert-True -Condition ($redditDraft.Count -eq 1) -Message "reddit should be queued as draft."
      Assert-Contains -Collection @($redditDraft[0].reason_codes) -Value "channel_requires_human_review" -Message "reddit draft should include human-review reason."

      $unknownDraft = @($drafts | Where-Object { $_.channel -eq "community_forum_unknown" } | Select-Object -First 1)
      Assert-True -Condition ($unknownDraft.Count -eq 1) -Message "Unknown channel should be queued as draft."
      Assert-Contains -Collection @($unknownDraft[0].reason_codes) -Value "policy_unknown_draft_only" -Message "Unknown policy draft should include policy_unknown_draft_only reason."
    }
    finally {
      Remove-Item -Path $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  It "safe mode forces draft-only even in live mode" {
    $runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("growth_publish_safe_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $config = [pscustomobject]@{
      delivery_mode = "tenant_only"
      cross_sell_allowed = $false
      safe_mode = $true
      global_emergency_stop = $false
      default_daily_budget = 40
      default_max_posts_per_day = 3
      utm_template = "utm_source={channel}&utm_medium=growth_autopilot&utm_campaign={campaign_id}&utm_content={language_code}-{creative_id}"
      compliance = [pscustomobject]@{
        default_disclosure = "Sponsored content. Reply STOP to opt out."
      }
    }
    $campaign = [pscustomobject]@{
      campaign_id = "publish-safe-test"
      keywords = @("lead response automation")
      target_languages = @("en")
      discovery_seed_channels = @("x")
      tone = "professional"
      daily_budget_usd = 20
      max_posts_per_day = 2
      cost_per_post_usd = 3
      estimated_sale_value_usd = 100
      landing_url = "https://example.com/pilot"
    }

    $configPath = Join-Path $runRoot "config.json"
    $campaignPath = Join-Path $runRoot "campaign.json"
    Write-JsonFile -Path $configPath -Value $config
    Write-JsonFile -Path $campaignPath -Value $campaign

    try {
      $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:ScriptPath `
        -Mode live `
        -CampaignId "publish-safe-test" `
        -Languages "en" `
        -ConfigPath $configPath `
        -CampaignPath $campaignPath `
        -AllowlistPath (Join-Path $script:RepoRoot "data\growth\allowlist.json") `
        -ArtifactsDir (Join-Path $runRoot "artifacts") `
        -StateDir (Join-Path $runRoot "state") `
        -LandingUrl "https://example.com/pilot" 2>&1
      $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      Assert-Equal -Actual $exitCode -Expected 0 -Message "Safe-mode live run should exit 0."

      $posts = @((Get-Content -Path (Join-Path $runRoot "artifacts\growth_autopilot.posts.json") -Raw -Encoding UTF8 | ConvertFrom-Json))
      $drafts = @((Get-Content -Path (Join-Path $runRoot "artifacts\growth_autopilot.drafts.json") -Raw -Encoding UTF8 | ConvertFrom-Json))
      Assert-Equal -Actual $posts.Count -Expected 0 -Message "Safe mode must block all auto-publishing."
      Assert-True -Condition ($drafts.Count -gt 0) -Message "Safe mode should still produce drafts."
      Assert-Contains -Collection @($drafts[0].reason_codes) -Value "safe_mode_forced_draft" -Message "Safe mode draft should include safe_mode_forced_draft reason."
    }
    finally {
      Remove-Item -Path $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
