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

Describe "growth autopilot smoke" {
  BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..")
    $script:AutopilotScript = Join-Path $script:RepoRoot "scripts\dev\start_growth_autopilot.ps1"
    $script:PowerShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    Assert-True -Condition (Test-Path -Path $script:AutopilotScript -PathType Leaf) -Message "Missing script: $script:AutopilotScript"
  }

  It "runs dryrun end-to-end and writes required artifacts" {
    $runDir = Join-Path ([System.IO.Path]::GetTempPath()) ("growth_smoke_" + [guid]::NewGuid().ToString("N"))
    $artifactDir = Join-Path $runDir "artifacts"
    $stateDir = Join-Path $runDir "state"
    New-Item -ItemType Directory -Path $artifactDir -Force | Out-Null
    New-Item -ItemType Directory -Path $stateDir -Force | Out-Null

    try {
      $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:AutopilotScript `
        -Mode dryrun `
        -CampaignId sample `
        -Languages "all" `
        -LandingUrl "https://example.com/pilot" `
        -ArtifactsDir $artifactDir `
        -StateDir $stateDir 2>&1
      $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
      Assert-Equal -Actual $exitCode -Expected 0 -Message "Dryrun should exit 0."

      $requiredArtifacts = @(
        "growth_autopilot.summary.json",
        "growth_autopilot.posts.json",
        "growth_autopilot.drafts.json",
        "growth_autopilot.metrics.json",
        "growth_autopilot.errors.json",
        "growth_autopilot.adapter_requests.json",
        "growth_autopilot.publish_receipts.json"
      )
      foreach ($name in $requiredArtifacts) {
        $path = Join-Path $artifactDir $name
        Assert-True -Condition (Test-Path -Path $path -PathType Leaf) -Message "Missing artifact: $path"
      }

      $summary = Get-Content -Path (Join-Path $artifactDir "growth_autopilot.summary.json") -Raw -Encoding UTF8 | ConvertFrom-Json

      # Avoid @(... | ConvertFrom-Json) edge case where empty JSON arrays become a single pipeline object.
      $postsRaw = Get-Content -Path (Join-Path $artifactDir "growth_autopilot.posts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
      $posts = @($postsRaw)

      $draftsRaw = Get-Content -Path (Join-Path $artifactDir "growth_autopilot.drafts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
      $drafts = @($draftsRaw)

      $requestsRaw = Get-Content -Path (Join-Path $artifactDir "growth_autopilot.adapter_requests.json") -Raw -Encoding UTF8 | ConvertFrom-Json
      $requests = @($requestsRaw)

      $receiptsRaw = Get-Content -Path (Join-Path $artifactDir "growth_autopilot.publish_receipts.json") -Raw -Encoding UTF8 | ConvertFrom-Json
      $receipts = @($receiptsRaw)
      Assert-Equal -Actual ([string]$summary.verdict) -Expected "PASS" -Message "Smoke summary verdict should be PASS."
      Assert-Equal -Actual ([string]$summary.mode) -Expected "dryrun" -Message "Smoke summary mode should be dryrun."
      Assert-Equal -Actual $posts.Count -Expected 0 -Message "Dryrun must not auto-publish."
      Assert-Equal -Actual $requests.Count -Expected 0 -Message "Dryrun must not execute adapters."
      Assert-Equal -Actual $receipts.Count -Expected 0 -Message "Dryrun must not emit publish receipts."
      Assert-True -Condition ($drafts.Count -gt 0) -Message "Dryrun should generate draft queue."
    }
    finally {
      Remove-Item -Path $runDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }
}
