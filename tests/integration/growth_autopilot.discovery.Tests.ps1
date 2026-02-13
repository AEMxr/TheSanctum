Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "growth_autopilot.test_env_utils.ps1")
. (Join-Path $PSScriptRoot "growth_autopilot.test_assert_utils.ps1")

function Invoke-AutopilotDryrun {
  param(
    [Parameter(Mandatory = $true)][string]$ScriptPath,
    [Parameter(Mandatory = $true)][string]$PowerShellExe,
    [Parameter(Mandatory = $true)][string]$ArtifactsDir,
    [Parameter(Mandatory = $true)][string]$StateDir
  )

  $output = & $PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath `
    -Mode dryrun `
    -CampaignId sample `
    -Languages "en,es" `
    -LandingUrl "https://example.com/pilot" `
    -ArtifactsDir $ArtifactsDir `
    -StateDir $StateDir 2>&1
  $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
  return [pscustomobject]@{
    exit_code = $exitCode
    output = @($output | ForEach-Object { [string]$_ })
    summary = Get-Content -Path (Join-Path $ArtifactsDir "growth_autopilot.summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json
    drafts = @((Get-Content -Path (Join-Path $ArtifactsDir "growth_autopilot.drafts.json") -Raw -Encoding UTF8 | ConvertFrom-Json))
    posts = @((Get-Content -Path (Join-Path $ArtifactsDir "growth_autopilot.posts.json") -Raw -Encoding UTF8 | ConvertFrom-Json))
  }
}

Describe "growth autopilot discovery integration" {
  BeforeAll {
    $script:GrowthEnvSnapshot = New-GrowthAutopilotTestEnvSnapshot
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:ScriptPath = Join-Path $script:RepoRoot "scripts\dev\start_growth_autopilot.ps1"
    $script:PowerShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Assert-True -Condition (Test-Path -Path $script:ScriptPath -PathType Leaf) -Message "Missing script: $script:ScriptPath"
  }

  AfterEach {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  AfterAll {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  It "produces deterministic discovery output and drafts unknown policy channels" {
    $runRoot1 = Join-Path ([System.IO.Path]::GetTempPath()) ("growth_discovery_1_" + [guid]::NewGuid().ToString("N"))
    $runRoot2 = Join-Path ([System.IO.Path]::GetTempPath()) ("growth_discovery_2_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $runRoot1 -Force | Out-Null
    New-Item -ItemType Directory -Path $runRoot2 -Force | Out-Null

    try {
      $run1 = Invoke-AutopilotDryrun -ScriptPath $script:ScriptPath -PowerShellExe $script:PowerShellExe -ArtifactsDir (Join-Path $runRoot1 "artifacts") -StateDir (Join-Path $runRoot1 "state")
      $run2 = Invoke-AutopilotDryrun -ScriptPath $script:ScriptPath -PowerShellExe $script:PowerShellExe -ArtifactsDir (Join-Path $runRoot2 "artifacts") -StateDir (Join-Path $runRoot2 "state")

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "First dryrun should exit 0."
      Assert-Equal -Actual $run2.exit_code -Expected 0 -Message "Second dryrun should exit 0."
      Assert-Equal -Actual ([string]$run1.summary.verdict) -Expected "PASS" -Message "First dryrun summary must be PASS."
      Assert-Equal -Actual ([string]$run2.summary.verdict) -Expected "PASS" -Message "Second dryrun summary must be PASS."
      Assert-Equal -Actual ($run1.posts.Count) -Expected 0 -Message "Dryrun should not publish posts."
      Assert-True -Condition ($run1.drafts.Count -gt 0) -Message "Dryrun should generate drafts."

      $unknownDraft = @($run1.drafts | Where-Object { $_.channel -eq "community_forum_unknown" } | Select-Object -First 1)
      Assert-True -Condition ($unknownDraft.Count -eq 1) -Message "Unknown policy channel should be present in draft queue."
      Assert-True -Condition (@($unknownDraft[0].reason_codes) -contains "policy_unknown_draft_only") -Message "Unknown policy draft should carry policy_unknown_draft_only reason."

      $draftJson1 = ($run1.drafts | ConvertTo-Json -Depth 30 -Compress)
      $draftJson2 = ($run2.drafts | ConvertTo-Json -Depth 30 -Compress)
      Assert-Equal -Actual $draftJson1 -Expected $draftJson2 -Message "Discovery drafts should be deterministic across repeated runs."

      Assert-True -Condition ([int]$run1.summary.discovery_count -gt 0) -Message "Discovery count should be greater than zero."
    }
    finally {
      Remove-Item -Path $runRoot1 -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -Path $runRoot2 -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
