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

function Write-JsonFile {
  param([string]$Path, [object]$Value)
  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -Path $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }
  $Value | ConvertTo-Json -Depth 30 | Set-Content -Path $Path -Encoding UTF8
}

Describe "growth autopilot tracking integration" {
  BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:ScriptPath = Join-Path $script:RepoRoot "scripts\dev\start_growth_autopilot.ps1"
    $script:PowerShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Assert-True -Condition (Test-Path -Path $script:ScriptPath -PathType Leaf) -Message "Missing script: $script:ScriptPath"
  }

  It "emits deterministic metrics and tracked links in live mode" {
    $runRoot = Join-Path ([System.IO.Path]::GetTempPath()) ("growth_tracking_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $runRoot -Force | Out-Null

    $config = [pscustomobject]@{
      delivery_mode = "tenant_only"
      cross_sell_allowed = $false
      self_promotion_mode = "explicit_only"
      safe_mode = $false
      global_emergency_stop = $false
      publish_transport_default = "mock"
      default_daily_budget = 60
      default_max_posts_per_day = 3
      utm_template = "utm_source={channel}&utm_medium=growth_autopilot&utm_campaign={campaign_id}&utm_content={language_code}-{creative_id}"
      compliance = [pscustomobject]@{
        default_disclosure = "Sponsored content. Reply STOP to opt out."
      }
    }
    $campaign = [pscustomobject]@{
      campaign_id = "tracking-test"
      keywords = @("meeting followup systems")
      target_languages = @("en")
      discovery_seed_channels = @("x")
      tone = "professional"
      daily_budget_usd = 30
      max_posts_per_day = 2
      cost_per_post_usd = 2
      estimated_sale_value_usd = 125
      landing_url = "https://example.com/pilot"
      self_promotion_allowed = $true
    }

    $configPath = Join-Path $runRoot "config.json"
    $campaignPath = Join-Path $runRoot "campaign.json"
    Write-JsonFile -Path $configPath -Value $config
    Write-JsonFile -Path $campaignPath -Value $campaign

    try {
      $invoke = {
        param($ScriptPath, $PowerShellExe, $ConfigPath, $CampaignPath, $RepoRoot, $RunRoot)
        $output = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
          -Mode live `
          -CampaignId "tracking-test" `
          -Languages "en" `
          -ConfigPath $ConfigPath `
          -CampaignPath $CampaignPath `
          -AllowlistPath (Join-Path $RepoRoot "data\growth\allowlist.json") `
          -ArtifactsDir (Join-Path $RunRoot "artifacts") `
          -StateDir (Join-Path $RunRoot "state") `
          -LandingUrl "https://example.com/pilot" 2>&1
        if ($null -eq $LASTEXITCODE) { return 0 }
        return [int]$LASTEXITCODE
      }

      $exit1 = & $invoke $script:ScriptPath $script:PowerShellExe $configPath $campaignPath $script:RepoRoot $runRoot
      Assert-Equal -Actual $exit1 -Expected 0 -Message "First tracking run should exit 0."
      $metricsPath = Join-Path $runRoot "artifacts\growth_autopilot.metrics.json"
      $postsPath = Join-Path $runRoot "artifacts\growth_autopilot.posts.json"
      $requestsPath = Join-Path $runRoot "artifacts\growth_autopilot.adapter_requests.json"
      $receiptsPath = Join-Path $runRoot "artifacts\growth_autopilot.publish_receipts.json"
      $ledgerPath = Join-Path $runRoot "state\publish_ledger.tracking-test.json"
      Assert-True -Condition (Test-Path -Path $metricsPath -PathType Leaf) -Message "Metrics artifact missing."
      Assert-True -Condition (Test-Path -Path $postsPath -PathType Leaf) -Message "Posts artifact missing."
      Assert-True -Condition (Test-Path -Path $requestsPath -PathType Leaf) -Message "Adapter requests artifact missing."
      Assert-True -Condition (Test-Path -Path $receiptsPath -PathType Leaf) -Message "Publish receipts artifact missing."
      Assert-True -Condition (Test-Path -Path $ledgerPath -PathType Leaf) -Message "Publish ledger missing."

      $metrics1 = Get-Content -Path $metricsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $posts1 = @((Get-Content -Path $postsPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $requests1 = @((Get-Content -Path $requestsPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $receipts1 = @((Get-Content -Path $receiptsPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $ledger1 = @((Get-Content -Path $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      Assert-True -Condition ($posts1.Count -gt 0) -Message "Tracking fixture must create at least one post."
      Assert-Equal -Actual $requests1.Count -Expected $posts1.Count -Message "Adapter requests must be emitted for published actions."
      Assert-Equal -Actual $receipts1.Count -Expected $posts1.Count -Message "Publish receipts must be emitted for published actions."
      Assert-Equal -Actual $ledger1.Count -Expected $posts1.Count -Message "Ledger must contain one entry per published action in this fixture."
      Assert-True -Condition ([int]$metrics1.totals.clicks -gt 0) -Message "Clicks must be greater than zero for posted entries."
      Assert-True -Condition ([int]$metrics1.totals.posts -gt 0) -Message "Metrics totals.posts must be greater than zero."
      Assert-True -Condition (@($metrics1.channel_language_summary).Count -gt 0) -Message "channel_language_summary must not be empty."
      Assert-True -Condition ([string]$posts1[0].tracked_url -like "*utm_source=*") -Message "Tracked URL must include utm_source."
      Assert-True -Condition ([string]$posts1[0].tracked_url -like "*utm_campaign=*") -Message "Tracked URL must include utm_campaign."

      $metricsJson1 = $metrics1 | ConvertTo-Json -Depth 30 -Compress
      $postsJson1 = $posts1 | ConvertTo-Json -Depth 30 -Compress
      $requestsJson1 = $requests1 | ConvertTo-Json -Depth 30 -Compress
      $receiptsJson1 = $receipts1 | ConvertTo-Json -Depth 30 -Compress
      $ledgerJson1 = $ledger1 | ConvertTo-Json -Depth 30 -Compress

      $exit2 = & $invoke $script:ScriptPath $script:PowerShellExe $configPath $campaignPath $script:RepoRoot $runRoot
      Assert-Equal -Actual $exit2 -Expected 0 -Message "Second tracking run should exit 0."
      $metrics2 = Get-Content -Path $metricsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $posts2 = @((Get-Content -Path $postsPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $requests2 = @((Get-Content -Path $requestsPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $receipts2 = @((Get-Content -Path $receiptsPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $ledger2 = @((Get-Content -Path $ledgerPath -Raw -Encoding UTF8 | ConvertFrom-Json))
      $metricsJson2 = $metrics2 | ConvertTo-Json -Depth 30 -Compress
      $postsJson2 = $posts2 | ConvertTo-Json -Depth 30 -Compress
      $requestsJson2 = $requests2 | ConvertTo-Json -Depth 30 -Compress
      $receiptsJson2 = $receipts2 | ConvertTo-Json -Depth 30 -Compress
      $ledgerJson2 = $ledger2 | ConvertTo-Json -Depth 30 -Compress

      Assert-Equal -Actual $metricsJson1 -Expected $metricsJson2 -Message "Metrics must be deterministic for repeated identical runs."
      Assert-Equal -Actual $postsJson1 -Expected $postsJson2 -Message "Post planning output must be deterministic for repeated identical runs."
      Assert-Equal -Actual $requestsJson1 -Expected $requestsJson2 -Message "Adapter requests must be deterministic for repeated identical runs."
      Assert-Equal -Actual $receiptsJson1 -Expected $receiptsJson2 -Message "Publish receipts must be deterministic for repeated identical runs."
      Assert-Equal -Actual $ledgerJson1 -Expected $ledgerJson2 -Message "Ledger must not grow or drift on idempotent rerun."
    }
    finally {
      Remove-Item -Path $runRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
