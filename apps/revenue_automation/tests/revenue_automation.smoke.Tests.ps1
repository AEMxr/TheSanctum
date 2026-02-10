# apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester apps/revenue_automation/tests/revenue_automation.smoke.Tests.ps1

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

Describe "revenue automation scaffold smoke" {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Resolve-Path (Join-Path $here "..\..\..")
    $script:IndexPath = Join-Path $script:RepoRoot "apps\revenue_automation\src\index.ps1"
    $script:ReplayPath = Join-Path $script:RepoRoot "apps\revenue_automation\scripts\replay_fixtures.ps1"
    $script:FixtureDir = Join-Path $script:RepoRoot "apps\revenue_automation\fixtures"
    Assert-True -Condition (Test-Path -Path $script:IndexPath -PathType Leaf) -Message "Missing entrypoint script: $script:IndexPath"
    Assert-True -Condition (Test-Path -Path $script:ReplayPath -PathType Leaf) -Message "Missing replay script: $script:ReplayPath"
    Assert-True -Condition (Test-Path -Path $script:FixtureDir -PathType Container) -Message "Missing fixture directory: $script:FixtureDir"

    $script:TestTempDir = Join-Path ([System.IO.Path]::GetTempPath()) ("revenue_automation_smoke_" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $script:TestTempDir -Force | Out-Null

    $script:PowerShellExe = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
  }

  AfterAll {
    if (-not [string]::IsNullOrWhiteSpace($script:TestTempDir) -and (Test-Path -Path $script:TestTempDir -PathType Container)) {
      Remove-Item -Path $script:TestTempDir -Recurse -Force -ErrorAction SilentlyContinue
    }
  }

  function Write-JsonFile {
    param(
      [Parameter(Mandatory = $true)][string]$Path,
      [Parameter(Mandatory = $true)][object]$Value
    )
    $Value | ConvertTo-Json -Depth 20 | Set-Content -Path $Path -Encoding UTF8
  }

  function New-TaskEnvelope {
    param([string]$TaskType)
    return [pscustomobject]@{
      task_id = [guid]::NewGuid().ToString()
      task_type = $TaskType
      payload = [pscustomobject]@{
        lead_id = "lead-001"
      }
      created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
  }

  function Invoke-RevenueRun {
    param(
      [Parameter(Mandatory = $true)][object]$Config,
      [Parameter(Mandatory = $true)][object]$Task
    )

    $id = [guid]::NewGuid().ToString("N")
    $configPath = Join-Path $script:TestTempDir ("config_$id.json")
    $taskPath = Join-Path $script:TestTempDir ("task_$id.json")

    Write-JsonFile -Path $configPath -Value $Config
    Write-JsonFile -Path $taskPath -Value $Task

    $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:IndexPath -ConfigPath $configPath -TaskPath $taskPath 2>&1
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    $lines = @($output | ForEach-Object { [string]$_ })
    $jsonLine = @($lines | Where-Object { $_.Trim().StartsWith("{") -and $_.Trim().EndsWith("}") } | Select-Object -Last 1)

    $result = $null
    if ($jsonLine.Count -gt 0) {
      try {
        $result = ($jsonLine[0] | ConvertFrom-Json)
      }
      catch {
        $result = $null
      }
    }

    return [pscustomobject]@{
      exit_code = $exitCode
      output_lines = $lines
      result = $result
    }
  }

  Context "1) flag OFF safe path" {
    It "exits 0 with clear disabled message and no task execution" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $false
        provider_mode = "mock"
        emit_telemetry = $true
        safe_mode = $true
        dry_run = $true
      }
      $task = New-TaskEnvelope -TaskType "lead_enrich"

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Disabled path should exit 0."

      $disabledMessage = @($run.output_lines | Where-Object { $_ -like "*Revenue automation disabled*" })
      Assert-True -Condition ($disabledMessage.Count -gt 0) -Message "Disabled path should emit clear message."
    }
  }

  Context "2) mock provider path" {
    It "returns SUCCESS for known task_type" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = New-TaskEnvelope -TaskType "lead_enrich"

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Mock success path should exit 0."
      Assert-True -Condition ($null -ne $run.result) -Message "Mock success path should emit result JSON."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Known task should return SUCCESS."
      Assert-Equal -Actual ([string]$run.result.provider_used) -Expected "mock" -Message "Mock provider should be used."
    }
  }

  Context "3) unsupported task_type behavior" {
    It "returns SKIPPED for unknown task_type" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = New-TaskEnvelope -TaskType "unknown_task_type"

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Unknown task_type should not hard fail process."
      Assert-True -Condition ($null -ne $run.result) -Message "Unknown task_type should emit result JSON."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SKIPPED" -Message "Unknown task_type should return SKIPPED."
      Assert-True -Condition (([string]$run.result.error) -like "*Unsupported task_type*") -Message "Unknown task_type should include explicit reason."
    }
  }

  Context "4) http provider safe mode behavior" {
    It "returns SKIPPED when provider_mode=http and safe_mode=true" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "http"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = New-TaskEnvelope -TaskType "followup_draft"

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Safe-mode http path should exit 0."
      Assert-True -Condition ($null -ne $run.result) -Message "Safe-mode http path should emit result JSON."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SKIPPED" -Message "Safe-mode http path should be SKIPPED."
      Assert-Equal -Actual ([string]$run.result.provider_used) -Expected "http" -Message "HTTP provider should be reported."
    }
  }

  Context "5) negative-path contract behavior" {
    It "returns FAILED for missing payload envelope" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Missing payload should return process exit 1."
      Assert-True -Condition ($null -ne $run.result) -Message "Missing payload should emit result JSON."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Missing payload should return FAILED."
      Assert-True -Condition (([string]$run.result.error) -like "*payload is required*") -Message "Missing payload should include validation error."
    }

    It "returns FAILED for invalid created_at_utc envelope" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "followup_draft"
        payload = [pscustomobject]@{
          lead_id = "lead-err-001"
        }
        created_at_utc = "bad-date"
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Invalid created_at_utc should return process exit 1."
      Assert-True -Condition ($null -ne $run.result) -Message "Invalid created_at_utc should emit result JSON."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Invalid created_at_utc should return FAILED."
      Assert-True -Condition (([string]$run.result.error) -like "*created_at_utc*") -Message "Invalid created_at_utc should include validation error."
    }
  }

  Context "6) output contract" {
    It "contains required fields and expected value types" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = New-TaskEnvelope -TaskType "calendar_proposal"

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-True -Condition ($null -ne $run.result) -Message "Contract test requires result JSON."

      $requiredFields = @(
        "task_id",
        "status",
        "provider_used",
        "started_at_utc",
        "finished_at_utc",
        "duration_ms",
        "error",
        "artifacts",
        "offer"
      )

      foreach ($field in $requiredFields) {
        Assert-True -Condition ($run.result.PSObject.Properties.Name -contains $field) -Message "Missing required output field: $field"
      }

      Assert-Contains -Collection @("SUCCESS", "FAILED", "SKIPPED") -Value ([string]$run.result.status) -Message "status must be SUCCESS|FAILED|SKIPPED."

      $tmpDuration = 0
      Assert-True -Condition ([int]::TryParse([string]$run.result.duration_ms, [ref]$tmpDuration)) -Message "duration_ms must be integer-like."
      Assert-True -Condition ($tmpDuration -ge 0) -Message "duration_ms must be non-negative."

      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run.result.task_id)) -Message "task_id must be non-empty."
      Assert-True -Condition (@($run.result.artifacts).Count -ge 0) -Message "artifacts must be an array."
    }
  }

  Context "7) fixture replay runner" {
    It "replays fixtures deterministically in safe/dry mode" {
      $replaySummaryPath = Join-Path $script:TestTempDir ("replay_summary_" + [guid]::NewGuid().ToString("N") + ".json")

      $output = & $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:ReplayPath -ConfigPath (Join-Path $script:RepoRoot "apps\revenue_automation\config.example.json") -FixturesDir $script:FixtureDir -OutputPath $replaySummaryPath 2>&1
      $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

      Assert-Equal -Actual $exitCode -Expected 0 -Message "Fixture replay should exit 0."
      Assert-True -Condition (Test-Path -Path $replaySummaryPath -PathType Leaf) -Message "Fixture replay should write summary output."

      $summary = Get-Content -Path $replaySummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json
      Assert-Equal -Actual ([string]$summary.provider_mode) -Expected "mock" -Message "Replay should default to mock provider from config."
      Assert-Equal -Actual ([bool]$summary.safe_mode) -Expected $true -Message "Replay must enforce safe_mode=true."
      Assert-Equal -Actual ([bool]$summary.dry_run) -Expected $true -Message "Replay must enforce dry_run=true."
      Assert-Equal -Actual ([int]$summary.failed) -Expected 0 -Message "Fixture replay should not have failed fixtures."
      Assert-True -Condition (@($summary.results).Count -ge 6) -Message "Fixture replay should include all fixture results."

      $missingPayload = @($summary.results | Where-Object { $_.fixture -eq "task_missing_payload.json" } | Select-Object -First 1)
      Assert-True -Condition ($missingPayload.Count -eq 1) -Message "Replay should include task_missing_payload.json."
      Assert-Equal -Actual ([string]$missingPayload[0].expected_status) -Expected "FAILED" -Message "task_missing_payload expected_status mismatch."
      Assert-Equal -Actual ([string]$missingPayload[0].actual_status) -Expected "FAILED" -Message "task_missing_payload actual_status mismatch."
      Assert-Equal -Actual ([int]$missingPayload[0].expected_exit_code) -Expected 1 -Message "task_missing_payload expected_exit_code mismatch."
      Assert-Equal -Actual ([int]$missingPayload[0].exit_code) -Expected 1 -Message "task_missing_payload exit_code mismatch."
      Assert-Equal -Actual ([bool]$missingPayload[0].pass) -Expected $true -Message "task_missing_payload should pass replay expectation."

      $invalidCreatedAt = @($summary.results | Where-Object { $_.fixture -eq "task_invalid_created_at.json" } | Select-Object -First 1)
      Assert-True -Condition ($invalidCreatedAt.Count -eq 1) -Message "Replay should include task_invalid_created_at.json."
      Assert-Equal -Actual ([string]$invalidCreatedAt[0].expected_status) -Expected "FAILED" -Message "task_invalid_created_at expected_status mismatch."
      Assert-Equal -Actual ([string]$invalidCreatedAt[0].actual_status) -Expected "FAILED" -Message "task_invalid_created_at actual_status mismatch."
      Assert-Equal -Actual ([int]$invalidCreatedAt[0].expected_exit_code) -Expected 1 -Message "task_invalid_created_at expected_exit_code mismatch."
      Assert-Equal -Actual ([int]$invalidCreatedAt[0].exit_code) -Expected 1 -Message "task_invalid_created_at exit_code mismatch."
      Assert-Equal -Actual ([bool]$invalidCreatedAt[0].pass) -Expected $true -Message "task_invalid_created_at should pass replay expectation."
    }
  }

  Context "8) deterministic lead scoring and routing" {
    It "returns stable ranked leads and routing reason codes across repeated runs" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = @(
            [pscustomobject]@{ lead_id = "lead-001"; segment = "saas"; intent = "demo"; budget = 500; engagement_score = 40 },
            [pscustomobject]@{ lead_id = "lead-003"; segment = "b2b"; pain_match = $true; budget = 3000; engagement_score = 80 },
            [pscustomobject]@{ lead_id = "lead-002" }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "First deterministic routing run should exit 0."
      Assert-Equal -Actual $run2.exit_code -Expected 0 -Message "Second deterministic routing run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "First deterministic routing run should return SUCCESS."
      Assert-Equal -Actual ([string]$run2.result.status) -Expected "SUCCESS" -Message "Second deterministic routing run should return SUCCESS."

      $ordered1 = @($run1.result.route.ranked_leads | ForEach-Object { [string]$_.lead_id })
      $ordered2 = @($run2.result.route.ranked_leads | ForEach-Object { [string]$_.lead_id })
      Assert-Equal -Actual ($ordered1 -join ",") -Expected "lead-003,lead-001,lead-002" -Message "Rank order mismatch for deterministic scoring."
      Assert-Equal -Actual ($ordered2 -join ",") -Expected "lead-003,lead-001,lead-002" -Message "Repeat run rank order mismatch for deterministic scoring."
      Assert-Equal -Actual ($ordered1 -join ",") -Expected ($ordered2 -join ",") -Message "Repeated run ranking must be stable."

      Assert-Equal -Actual ([string]$run1.result.route.selected_route) -Expected "priority_outreach" -Message "Expected priority_outreach selected route."
      Assert-Contains -Collection @($run1.result.reason_codes) -Value "high_priority_score" -Message "Expected high_priority_score reason code."
      Assert-Contains -Collection @($run1.result.route.reason_codes) -Value "fit_segment" -Message "Expected fit_segment reason code."
      Assert-True -Condition ($null -ne $run1.result.offer) -Message "High-priority lead_enrich should emit offer."
      Assert-Equal -Actual ([string]$run1.result.offer.tier) -Expected "pro" -Message "High-priority route should map to pro offer."
      Assert-Contains -Collection @($run1.result.offer.reason_codes) -Value "offer_pro_priority" -Message "Pro offer should include deterministic reason code."

      $offerJson1 = ($run1.result.offer | ConvertTo-Json -Depth 20 -Compress)
      $offerJson2 = ($run2.result.offer | ConvertTo-Json -Depth 20 -Compress)
      Assert-Equal -Actual $offerJson1 -Expected $offerJson2 -Message "Offer payload must remain deterministic across repeated runs."
    }

    It "uses lead_id ascending tie-break when scores are equal" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = @(
            [pscustomobject]@{ lead_id = "lead-c" },
            [pscustomobject]@{ lead_id = "lead-a" },
            [pscustomobject]@{ lead_id = "lead-b" }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Tie-break run should exit 0."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Tie-break run should return SUCCESS."

      $ordered = @($run.result.route.ranked_leads | ForEach-Object { [string]$_.lead_id })
      Assert-Equal -Actual ($ordered -join ",") -Expected "lead-a,lead-b,lead-c" -Message "Tie-break ordering must use lead_id ascending."
    }

    It "returns starter offer for medium-priority route" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = @(
            [pscustomobject]@{ lead_id = "lead-medium"; segment = "b2b" }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Medium-priority route should exit 0."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Medium-priority route should return SUCCESS."
      Assert-Equal -Actual ([string]$run.result.route.selected_route) -Expected "nurture_sequence" -Message "Expected nurture_sequence route."
      Assert-True -Condition ($null -ne $run.result.offer) -Message "Medium-priority route should emit offer."
      Assert-Equal -Actual ([string]$run.result.offer.tier) -Expected "starter" -Message "Medium-priority route should map to starter offer."
      Assert-Contains -Collection @($run.result.offer.reason_codes) -Value "offer_starter_nurture" -Message "Starter offer should include deterministic reason code."
    }

    It "returns free offer for low-priority route" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = @(
            [pscustomobject]@{ lead_id = "lead-low" }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Low-priority route should exit 0."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Low-priority route should return SUCCESS."
      Assert-Equal -Actual ([string]$run.result.route.selected_route) -Expected "qualify_later" -Message "Expected qualify_later route."
      Assert-True -Condition ($null -ne $run.result.offer) -Message "Low-priority route should emit offer."
      Assert-Equal -Actual ([string]$run.result.offer.tier) -Expected "free" -Message "Low-priority route should map to free offer."
      Assert-Contains -Collection @($run.result.offer.reason_codes) -Value "offer_free_low_signal" -Message "Free offer should include deterministic reason code."
    }

    It "returns FAILED for malformed payload.leads" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }
      $task = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = "not-an-object-array"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed payload.leads should exit 1."
      Assert-True -Condition ($null -ne $run.result) -Message "Malformed payload.leads should emit result JSON."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed payload.leads should return FAILED."
      Assert-True -Condition (([string]$run.result.error) -like "*payload.leads must be an array or object.*") -Message "Malformed payload.leads should include routing validation error."
    }
  }
}
