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
        "policy",
        "offer",
        "proposal",
        "telemetry_event_stub",
        "telemetry_event",
        "campaign_packet",
        "dispatch_plan",
        "delivery_manifest",
        "sender_envelope",
        "adapter_request",
        "dispatch_receipt",
        "audit_record",
        "evidence_envelope",
        "retention_manifest"
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
      Assert-True -Condition ($null -ne $run1.result.proposal) -Message "High-priority lead_enrich should emit proposal."
      Assert-Equal -Actual ([string]$run1.result.proposal.tier) -Expected "pro" -Message "High-priority offer should map to pro proposal."
      Assert-Equal -Actual ([int]$run1.result.proposal.monthly_price_usd) -Expected 999 -Message "Pro proposal monthly price mismatch."
      Assert-Equal -Actual ([int]$run1.result.proposal.setup_fee_usd) -Expected 499 -Message "Pro proposal setup fee mismatch."
      Assert-Equal -Actual ([int]$run1.result.proposal.due_now_usd) -Expected 1498 -Message "Pro proposal due_now mismatch."
      Assert-Contains -Collection @($run1.result.proposal.reason_codes) -Value "proposal_from_offer_pro" -Message "Pro proposal should include deterministic reason code."

      $offerJson1 = ($run1.result.offer | ConvertTo-Json -Depth 20 -Compress)
      $offerJson2 = ($run2.result.offer | ConvertTo-Json -Depth 20 -Compress)
      Assert-Equal -Actual $offerJson1 -Expected $offerJson2 -Message "Offer payload must remain deterministic across repeated runs."
      $proposalJson1 = ($run1.result.proposal | ConvertTo-Json -Depth 20 -Compress)
      $proposalJson2 = ($run2.result.proposal | ConvertTo-Json -Depth 20 -Compress)
      Assert-Equal -Actual $proposalJson1 -Expected $proposalJson2 -Message "Proposal payload must remain deterministic across repeated runs."
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
      Assert-True -Condition ($null -ne $run.result.proposal) -Message "Medium-priority route should emit proposal."
      Assert-Equal -Actual ([string]$run.result.proposal.tier) -Expected "starter" -Message "Medium-priority offer should map to starter proposal."
      Assert-Equal -Actual ([int]$run.result.proposal.monthly_price_usd) -Expected 299 -Message "Starter proposal monthly price mismatch."
      Assert-Equal -Actual ([int]$run.result.proposal.setup_fee_usd) -Expected 149 -Message "Starter proposal setup fee mismatch."
      Assert-Equal -Actual ([int]$run.result.proposal.due_now_usd) -Expected 448 -Message "Starter proposal due_now mismatch."
      Assert-Contains -Collection @($run.result.proposal.reason_codes) -Value "proposal_from_offer_starter" -Message "Starter proposal should include deterministic reason code."
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
      Assert-True -Condition ($null -ne $run.result.proposal) -Message "Low-priority route should emit proposal."
      Assert-Equal -Actual ([string]$run.result.proposal.tier) -Expected "free" -Message "Low-priority offer should map to free proposal."
      Assert-Equal -Actual ([int]$run.result.proposal.monthly_price_usd) -Expected 0 -Message "Free proposal monthly price mismatch."
      Assert-Equal -Actual ([int]$run.result.proposal.setup_fee_usd) -Expected 0 -Message "Free proposal setup fee mismatch."
      Assert-Equal -Actual ([int]$run.result.proposal.due_now_usd) -Expected 0 -Message "Free proposal due_now mismatch."
      Assert-Contains -Collection @($run.result.proposal.reason_codes) -Value "proposal_from_offer_free" -Message "Free proposal should include deterministic reason code."
      Assert-True -Condition (([string]$run.result.proposal.checkout_stub) -like "stub://checkout/free/*") -Message "Free proposal should use free checkout stub."
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
      Assert-True -Condition ($null -eq $run.result.proposal) -Message "Malformed payload.leads must not emit proposal."
    }
  }

  Context "9) context-scoped policy guard engine" {
    It "allows action when under context cap" {
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
            [pscustomobject]@{ lead_id = "lead-policy-allow"; segment = "saas"; intent = "demo" }
          )
          policy_context = [pscustomobject]@{
            platform = "x"
            account_id = "acct-001"
            community_id = "community-allow"
            action_type = "reply"
            window_key = "2026021010"
            context_cap = 3
            actions_in_window = 1
            cooldown_seconds = 120
            seconds_since_last_action = 240
          }
        }
        created_at_utc = "2026-02-10T10:00:00Z"
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Under-cap policy should allow execution."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Allowed policy should keep success path."
      Assert-True -Condition ($null -ne $run.result.policy) -Message "Result should include policy object."
      Assert-Equal -Actual ([bool]$run.result.policy.allowed) -Expected $true -Message "Policy should be allowed under cap."
      Assert-Equal -Actual ([string]$run.result.policy.context_key) -Expected "x|acct-001|community-allow|reply|2026021010" -Message "Policy context key mismatch."
      Assert-Equal -Actual (@($run.result.policy.reason_codes).Count) -Expected 0 -Message "Allowed policy should have no deny reason codes."
    }

    It "denies action when context cap is exceeded" {
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
            [pscustomobject]@{ lead_id = "lead-policy-cap"; segment = "saas" }
          )
          policy_context = [pscustomobject]@{
            platform = "x"
            account_id = "acct-001"
            community_id = "community-cap"
            action_type = "post"
            window_key = "2026021011"
            context_cap = 2
            actions_in_window = 2
            cooldown_seconds = 0
            seconds_since_last_action = 999
          }
        }
        created_at_utc = "2026-02-10T11:00:00Z"
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Policy denial should not crash process."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SKIPPED" -Message "Cap denial should return SKIPPED."
      Assert-Equal -Actual ([bool]$run.result.policy.allowed) -Expected $false -Message "Policy should be denied on cap."
      Assert-Contains -Collection @($run.result.policy.reason_codes) -Value "policy_denied_context_cap" -Message "Cap denial reason code missing."
    }

    It "denies action on cooldown window" {
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
            [pscustomobject]@{ lead_id = "lead-policy-cooldown"; segment = "b2b" }
          )
          policy_context = [pscustomobject]@{
            platform = "reddit"
            account_id = "acct-002"
            community_id = "community-cooldown"
            action_type = "reply"
            window_key = "2026021012"
            context_cap = 10
            actions_in_window = 1
            cooldown_seconds = 300
            seconds_since_last_action = 30
          }
        }
        created_at_utc = "2026-02-10T12:00:00Z"
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Cooldown denial should not crash process."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SKIPPED" -Message "Cooldown denial should return SKIPPED."
      Assert-Equal -Actual ([bool]$run.result.policy.allowed) -Expected $false -Message "Policy should be denied on cooldown."
      Assert-Contains -Collection @($run.result.policy.reason_codes) -Value "policy_denied_cooldown" -Message "Cooldown denial reason code missing."
    }

    It "caps contexts independently across communities" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }

      $taskDenied = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = @([pscustomobject]@{ lead_id = "lead-community-a"; segment = "saas" })
          policy_context = [pscustomobject]@{
            platform = "x"
            account_id = "acct-003"
            community_id = "community-a"
            action_type = "post"
            window_key = "2026021013"
            context_cap = 1
            actions_in_window = 1
            cooldown_seconds = 0
            seconds_since_last_action = 1000
          }
        }
        created_at_utc = "2026-02-10T13:00:00Z"
      }
      $taskAllowed = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          leads = @([pscustomobject]@{ lead_id = "lead-community-b"; segment = "saas" })
          policy_context = [pscustomobject]@{
            platform = "x"
            account_id = "acct-003"
            community_id = "community-b"
            action_type = "post"
            window_key = "2026021013"
            context_cap = 1
            actions_in_window = 0
            cooldown_seconds = 0
            seconds_since_last_action = 1000
          }
        }
        created_at_utc = "2026-02-10T13:00:00Z"
      }

      $runDenied = Invoke-RevenueRun -Config $config -Task $taskDenied
      $runAllowed = Invoke-RevenueRun -Config $config -Task $taskAllowed

      Assert-Equal -Actual ([bool]$runDenied.result.policy.allowed) -Expected $false -Message "Community A should be denied by cap."
      Assert-Equal -Actual ([bool]$runAllowed.result.policy.allowed) -Expected $true -Message "Community B should remain allowed."
      Assert-True -Condition ([string]$runDenied.result.policy.context_key -ne [string]$runAllowed.result.policy.context_key) -Message "Different communities must produce different context keys."
    }

    It "returns deterministic policy output across repeated runs" {
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
          leads = @([pscustomobject]@{ lead_id = "lead-policy-stable"; segment = "saas" })
          policy_context = [pscustomobject]@{
            platform = "facebook"
            account_id = "acct-004"
            community_id = "community-stable"
            action_type = "reply"
            window_key = "2026021014"
            context_cap = 4
            actions_in_window = 1
            cooldown_seconds = 120
            seconds_since_last_action = 240
          }
        }
        created_at_utc = "2026-02-10T14:00:00Z"
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task
      $policy1 = ($run1.result.policy | ConvertTo-Json -Depth 20 -Compress)
      $policy2 = ($run2.result.policy | ConvertTo-Json -Depth 20 -Compress)

      Assert-Equal -Actual $policy1 -Expected $policy2 -Message "Policy output must remain deterministic across repeated runs."
    }
  }

  Context "10) multilingual template engine" {
    It "emits deterministic native-language templates for spanish input" {
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
          language_code = "es-MX"
          leads = @(
            [pscustomobject]@{ lead_id = "lead-es-001"; segment = "saas"; pain_match = $true; budget = 2000; engagement_score = 75 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Spanish template run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Spanish template run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.proposal) -Message "Spanish template run should emit proposal."
      Assert-Equal -Actual ([string]$run1.result.proposal.template_language) -Expected "es" -Message "Spanish template should use native language."
      Assert-Contains -Collection @($run1.result.proposal.reason_codes) -Value "template_lang_native" -Message "Spanish template should include native reason code."
      Assert-Contains -Collection @($run1.result.proposal.reason_codes) -Value "profile_exact_match" -Message "Spanish template should include localization profile resolution reason code."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.proposal.ad_copy)) -Message "Spanish template should include ad_copy."
      Assert-True -Condition (@($run1.result.proposal.short_reply_templates).Count -gt 0) -Message "Spanish template should include short replies."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.proposal.cta_buy_text)) -Message "Spanish template should include buy CTA text."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.proposal.cta_subscribe_text)) -Message "Spanish template should include subscribe CTA text."

      $proposal1 = ($run1.result.proposal | ConvertTo-Json -Depth 30 -Compress)
      $proposal2 = ($run2.result.proposal | ConvertTo-Json -Depth 30 -Compress)
      Assert-Equal -Actual $proposal1 -Expected $proposal2 -Message "Spanish template payload should be deterministic across repeated runs."
    }

    It "falls back to english templates for unsupported language with deterministic reason code" {
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
          detected_language = "it-IT"
          leads = @(
            [pscustomobject]@{ lead_id = "lead-it-001"; segment = "saas"; pain_match = $true; budget = 2000; engagement_score = 75 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Fallback language run should exit 0."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Fallback language run should return SUCCESS."
      Assert-True -Condition ($null -ne $run.result.proposal) -Message "Fallback language run should emit proposal."
      Assert-Equal -Actual ([string]$run.result.proposal.template_language) -Expected "en" -Message "Unsupported language should fallback to en templates."
      Assert-Contains -Collection @($run.result.proposal.reason_codes) -Value "template_lang_fallback_en" -Message "Fallback language run should include fallback reason code."
      Assert-Contains -Collection @($run.result.proposal.reason_codes) -Value "profile_global_fallback" -Message "Fallback language run should include profile fallback reason code."
    }

    It "preserves clean FAILED behavior for malformed lead payloads without proposal templates" {
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
          language_code = "es"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should still exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should remain FAILED."
      Assert-True -Condition ($null -eq $run.result.proposal) -Message "Malformed lead payload must not emit proposal/template fields."
    }
  }

  Context "11) language-aware variant selection" {
    It "selects deterministic variant for repeated same language input" {
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
          language_code = "en-US"
          region_code = "US"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "en"; region_code = "US"; variant_id = "variant_en_alpha"; ctr_bps = 800; conversion_bps = 300; impressions = 500 },
              [pscustomobject]@{ language_code = "en"; region_code = "US"; variant_id = "variant_en_beta"; ctr_bps = 700; conversion_bps = 200; impressions = 400 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-variant-en"; segment = "saas"; pain_match = $true; budget = 2500; engagement_score = 80 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Variant deterministic run should exit 0."
      Assert-Equal -Actual $run2.exit_code -Expected 0 -Message "Variant deterministic repeat run should exit 0."
      Assert-True -Condition ($null -ne $run1.result.route.variant) -Message "Variant selection should be emitted on successful lead_enrich route."
      Assert-Equal -Actual ([string]$run1.result.route.variant.selected_variant_id) -Expected "variant_en_alpha" -Message "Expected deterministic best EN variant."
      Assert-Equal -Actual ([string]$run1.result.route.variant.confidence_band) -Expected "high" -Message "Expected high confidence for clear winner."
      Assert-Contains -Collection @($run1.result.route.variant.selection_reason_codes) -Value "variant_lang_perf_win" -Message "Variant reason should include perf win code."
      Assert-Equal -Actual (($run1.result.route.variant | ConvertTo-Json -Depth 20 -Compress)) -Expected (($run2.result.route.variant | ConvertTo-Json -Depth 20 -Compress)) -Message "Variant payload should be deterministic across repeated runs."
    }

    It "can select different variants for different language segments" {
      $config = [pscustomobject]@{
        enable_revenue_automation = $true
        provider_mode = "mock"
        emit_telemetry = $false
        safe_mode = $true
        dry_run = $true
      }

      $sharedSegments = @(
        [pscustomobject]@{ language_code = "en"; region_code = "US"; variant_id = "variant_en_perf"; ctr_bps = 900; conversion_bps = 250; impressions = 300 },
        [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 920; conversion_bps = 260; impressions = 300 }
      )

      $taskEn = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          language_code = "en-US"
          region_code = "US"
          trend_summary = [pscustomobject]@{ segments = $sharedSegments }
          leads = @([pscustomobject]@{ lead_id = "lead-en"; segment = "saas"; pain_match = $true; budget = 2000; engagement_score = 72 })
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $taskEs = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{ segments = $sharedSegments }
          leads = @([pscustomobject]@{ lead_id = "lead-es"; segment = "saas"; pain_match = $true; budget = 2000; engagement_score = 72 })
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $runEn = Invoke-RevenueRun -Config $config -Task $taskEn
      $runEs = Invoke-RevenueRun -Config $config -Task $taskEs

      Assert-Equal -Actual ([string]$runEn.result.route.variant.selected_variant_id) -Expected "variant_en_perf" -Message "EN segment should resolve EN variant."
      Assert-Equal -Actual ([string]$runEs.result.route.variant.selected_variant_id) -Expected "variant_es_perf" -Message "ES segment should resolve ES variant."
      Assert-True -Condition (([string]$runEn.result.route.variant.selected_variant_id) -ne ([string]$runEs.result.route.variant.selected_variant_id)) -Message "Different language segments should be able to choose different variants."
    }

    It "uses deterministic tie-break ordering by variant_id when scores are equal" {
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
          language_code = "fr-FR"
          region_code = "FR"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "fr"; region_code = "FR"; variant_id = "variant_fr_beta"; ctr_bps = 400; conversion_bps = 200; impressions = 100 },
              [pscustomobject]@{ language_code = "fr"; region_code = "FR"; variant_id = "variant_fr_alpha"; ctr_bps = 400; conversion_bps = 200; impressions = 100 }
            )
          }
          leads = @([pscustomobject]@{ lead_id = "lead-fr"; segment = "b2b"; pain_match = $true; budget = 2200; engagement_score = 70 })
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual ([string]$run.result.route.variant.selected_variant_id) -Expected "variant_fr_alpha" -Message "Tie-break should use variant_id ascending."
      Assert-Contains -Collection @($run.result.route.variant.selection_reason_codes) -Value "variant_lang_tiebreak" -Message "Tie-break reason code should be emitted."
      Assert-Equal -Actual ([string]$run.result.route.variant.confidence_band) -Expected "medium" -Message "Tie-break path should emit medium confidence for equal positive scores."
    }

    It "emits fallback variant for missing trend summary without crashing" {
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
          language_code = "de-DE"
          region_code = "DE"
          leads = @([pscustomobject]@{ lead_id = "lead-de"; segment = "b2b"; pain_match = $true; budget = 2200; engagement_score = 70 })
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 0 -Message "Missing trend summary should not crash."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "SUCCESS" -Message "Missing trend summary should preserve successful path."
      Assert-Equal -Actual ([string]$run.result.route.variant.selected_variant_id) -Expected "variant_de_core" -Message "Missing trend summary should use deterministic language fallback variant."
      Assert-Contains -Collection @($run.result.route.variant.selection_reason_codes) -Value "variant_lang_tiebreak" -Message "Fallback variant should emit stable reason code."
      Assert-Equal -Actual ([string]$run.result.route.variant.confidence_band) -Expected "low" -Message "Fallback variant should emit low confidence when no trend candidates match."
    }
  }

  Context "12) marketing API response contract" {
    It "emits explicit proposal, variant, telemetry fields, and reason lineage on successful lead_enrich" {
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
          source_channel = "reddit"
          campaign_id = "camp-001"
          language_code = "es-MX"
          region_code = "MX"
          geo_coarse = "mx-north"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 920; conversion_bps = 300; impressions = 400 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-contract-001"; segment = "saas"; pain_match = $true; budget = 2500; engagement_score = 80 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Contract success run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Contract success run should return SUCCESS."

      Assert-True -Condition ($null -ne $run1.result.proposal) -Message "Successful lead_enrich should emit proposal."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.proposal.ad_copy)) -Message "Proposal should include ad_copy."
      Assert-True -Condition (@($run1.result.proposal.short_reply_templates).Count -gt 0) -Message "Proposal should include short_reply_templates."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.proposal.cta_buy_text)) -Message "Proposal should include cta_buy_text."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.proposal.cta_subscribe_text)) -Message "Proposal should include cta_subscribe_text."

      Assert-True -Condition ($null -ne $run1.result.route) -Message "Successful lead_enrich should emit route."
      Assert-True -Condition ($null -ne $run1.result.route.variant) -Message "Successful lead_enrich should emit route.variant."
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$run1.result.route.variant.selected_variant_id)) -Message "Variant should include selected_variant_id."
      Assert-True -Condition (@($run1.result.route.variant.selection_reason_codes).Count -gt 0) -Message "Variant should include selection_reason_codes."

      Assert-Contains -Collection @($run1.result.reason_codes) -Value "template_lang_native" -Message "Result reason_codes should include template lineage."
      Assert-Contains -Collection @($run1.result.reason_codes) -Value "variant_lang_perf_win" -Message "Result reason_codes should include variant lineage."

      Assert-True -Condition ($null -ne $run1.result.telemetry_event_stub) -Message "Result should include telemetry_event_stub."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event_stub.language_code) -Expected "es" -Message "Telemetry stub language_code mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event_stub.region_code) -Expected "MX" -Message "Telemetry stub region_code mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event_stub.geo_coarse) -Expected "mx-north" -Message "Telemetry stub geo_coarse mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event_stub.source_channel) -Expected "reddit" -Message "Telemetry stub source_channel mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event_stub.selected_variant_id) -Expected ([string]$run1.result.route.variant.selected_variant_id) -Message "Telemetry stub selected_variant_id mismatch."

      Assert-True -Condition ($null -ne $run1.result.telemetry_event) -Message "Result should include telemetry_event on successful lead_enrich."
      $requiredTelemetryFields = @(
        "event_id",
        "event_type",
        "receipt_id",
        "request_id",
        "idempotency_key",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "status",
        "accepted_action_types",
        "reason_codes"
      )
      foreach ($field in $requiredTelemetryFields) {
        Assert-True -Condition ($run1.result.telemetry_event.PSObject.Properties.Name -contains $field) -Message "telemetry_event missing field: $field"
      }

      Assert-Equal -Actual ([string]$run1.result.telemetry_event.event_type) -Expected "dispatch_receipt" -Message "Telemetry event type mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.receipt_id) -Expected ([string]$run1.result.dispatch_receipt.receipt_id) -Message "Telemetry event receipt_id mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.request_id) -Expected ([string]$run1.result.dispatch_receipt.request_id) -Message "Telemetry event request_id mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.idempotency_key) -Expected ([string]$run1.result.dispatch_receipt.idempotency_key) -Message "Telemetry event idempotency_key mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.channel) -Expected ([string]$run1.result.dispatch_receipt.channel) -Message "Telemetry event channel mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.provider_mode) -Expected "mock" -Message "Telemetry event provider_mode mismatch."
      Assert-Equal -Actual ([bool]$run1.result.telemetry_event.dry_run) -Expected $true -Message "Telemetry event dry_run mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.status) -Expected "simulated" -Message "Telemetry event status mismatch."

      $acceptedActionTypes = @($run1.result.telemetry_event.accepted_action_types | ForEach-Object { [string]$_ })
      Assert-Equal -Actual $acceptedActionTypes.Count -Expected 2 -Message "Telemetry event accepted_action_types should contain exactly two entries."
      Assert-Equal -Actual ([string]$acceptedActionTypes[0]) -Expected "cta_buy" -Message "Telemetry event accepted_action_types ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$acceptedActionTypes[1]) -Expected "cta_subscribe" -Message "Telemetry event accepted_action_types ordering mismatch for cta_subscribe."

      Assert-Equal -Actual ([string]$run1.result.telemetry_event.language_code) -Expected "es" -Message "Telemetry event language_code mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.region_code) -Expected "MX" -Message "Telemetry event region_code mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.geo_coarse) -Expected "mx-north" -Message "Telemetry event geo_coarse mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.source_channel) -Expected "reddit" -Message "Telemetry event source_channel mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.campaign_id) -Expected "camp-001" -Message "Telemetry event campaign_id mismatch."
      Assert-Equal -Actual ([string]$run1.result.telemetry_event.selected_variant_id) -Expected ([string]$run1.result.route.variant.selected_variant_id) -Message "Telemetry event selected_variant_id mismatch."
      Assert-Contains -Collection @($run1.result.telemetry_event.reason_codes) -Value "telemetry_event_emitted" -Message "Telemetry event should include emission reason code."
      Assert-Contains -Collection @($run1.result.telemetry_event.reason_codes) -Value "dispatch_receipt_dry_run" -Message "Telemetry event should include dry-run receipt lineage."
      Assert-Contains -Collection @($run1.result.telemetry_event.reason_codes) -Value "template_lang_native" -Message "Telemetry event should carry template reason lineage."
      Assert-Contains -Collection @($run1.result.telemetry_event.reason_codes) -Value "variant_lang_perf_win" -Message "Telemetry event should carry variant reason lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($run1.result.telemetry_event_stub.PSObject.Properties.Name -contains $forbidden)) -Message "Telemetry stub must not expose $forbidden."
        Assert-True -Condition (-not ($run1.result.telemetry_event.PSObject.Properties.Name -contains $forbidden)) -Message "Telemetry event must not expose $forbidden."
      }

      Assert-Equal -Actual (($run1.result.telemetry_event | ConvertTo-Json -Depth 20 -Compress)) -Expected (($run2.result.telemetry_event | ConvertTo-Json -Depth 20 -Compress)) -Message "Telemetry event must remain deterministic across repeated runs."
    }

    It "does not emit telemetry_event for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.telemetry_event) -Message "Malformed lead payload must not emit telemetry_event."
    }
  }

  Context "13) dual-cta campaign packet contract" {
    It "emits deterministic campaign packet with buy/subscribe stubs for successful lead_enrich" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv008-001"
          language_code = "en-US"
          region_code = "US"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "en"; region_code = "US"; variant_id = "variant_en_perf"; ctr_bps = 950; conversion_bps = 310; impressions = 450 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv008-001"; segment = "saas"; pain_match = $true; budget = 2600; engagement_score = 85 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Campaign packet run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Campaign packet run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.campaign_packet) -Message "Successful lead_enrich should emit campaign_packet."

      Assert-Equal -Actual ([string]$run1.result.campaign_packet.campaign_id) -Expected "camp-rv008-001" -Message "Campaign packet campaign_id mismatch."
      Assert-Equal -Actual ([string]$run1.result.campaign_packet.tier) -Expected ([string]$run1.result.offer.tier) -Message "Campaign packet tier should match offer tier."
      Assert-True -Condition (@($run1.result.campaign_packet.channels).Count -gt 0) -Message "Campaign packet should include channels."
      Assert-Equal -Actual ([string]$run1.result.campaign_packet.channels[0]) -Expected "reddit" -Message "Campaign packet channel mismatch."
      Assert-True -Condition (@($run1.result.campaign_packet.copy_variants).Count -ge 2) -Message "Campaign packet should include copy variants."
      Assert-True -Condition (([string]$run1.result.campaign_packet.cta_buy_stub) -like "stub://checkout/*") -Message "Campaign packet buy CTA stub mismatch."
      Assert-True -Condition (([string]$run1.result.campaign_packet.cta_subscribe_stub) -like "stub://subscribe/*") -Message "Campaign packet subscribe CTA stub mismatch."
      Assert-Contains -Collection @($run1.result.campaign_packet.reason_codes) -Value "campaign_dual_cta_emitted" -Message "Campaign packet should include dual CTA reason code."
      Assert-Contains -Collection @($run1.result.campaign_packet.reason_codes) -Value "template_lang_native" -Message "Campaign packet should carry template reason lineage."
      Assert-Contains -Collection @($run1.result.campaign_packet.reason_codes) -Value "variant_lang_perf_win" -Message "Campaign packet should carry variant reason lineage."

      $packet1 = ($run1.result.campaign_packet | ConvertTo-Json -Depth 30 -Compress)
      $packet2 = ($run2.result.campaign_packet | ConvertTo-Json -Depth 30 -Compress)
      Assert-Equal -Actual $packet1 -Expected $packet2 -Message "Campaign packet must remain deterministic across repeated runs."
    }
  }

  Context "14) deterministic localized dispatch plan contract" {
    It "emits deterministic dispatch_plan with lineage and privacy-safe fields" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv009-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 900; conversion_bps = 260; impressions = 600 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv009-001"; segment = "saas"; pain_match = $true; budget = 2500; engagement_score = 81 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Dispatch plan run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Dispatch plan run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.dispatch_plan) -Message "Successful lead_enrich should emit dispatch_plan."

      $dispatch = $run1.result.dispatch_plan
      $requiredDispatchFields = @(
        "dispatch_id",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "ad_copy",
        "reply_template",
        "cta_buy_stub",
        "cta_subscribe_stub",
        "reason_codes"
      )
      foreach ($field in $requiredDispatchFields) {
        Assert-True -Condition ($dispatch.PSObject.Properties.Name -contains $field) -Message "dispatch_plan missing field: $field"
      }

      Assert-Equal -Actual ([string]$dispatch.campaign_id) -Expected "camp-rv009-001" -Message "Dispatch campaign_id mismatch."
      Assert-Equal -Actual ([string]$dispatch.channel) -Expected "reddit" -Message "Dispatch channel mismatch."
      Assert-Equal -Actual ([string]$dispatch.language_code) -Expected "es" -Message "Dispatch language_code mismatch."
      Assert-Equal -Actual ([string]$dispatch.selected_variant_id) -Expected ([string]$run1.result.route.variant.selected_variant_id) -Message "Dispatch variant lineage mismatch."
      Assert-Contains -Collection @($dispatch.reason_codes) -Value "dispatch_plan_emitted" -Message "Dispatch plan should include emission reason code."
      Assert-Contains -Collection @($dispatch.reason_codes) -Value "template_lang_native" -Message "Dispatch plan should include template reason lineage."
      Assert-Contains -Collection @($dispatch.reason_codes) -Value "variant_lang_perf_win" -Message "Dispatch plan should include variant reason lineage."

      Assert-True -Condition (-not ($dispatch.PSObject.Properties.Name -contains "latitude")) -Message "dispatch_plan must not expose latitude."
      Assert-True -Condition (-not ($dispatch.PSObject.Properties.Name -contains "longitude")) -Message "dispatch_plan must not expose longitude."

      $dispatchJson1 = ($run1.result.dispatch_plan | ConvertTo-Json -Depth 30 -Compress)
      $dispatchJson2 = ($run2.result.dispatch_plan | ConvertTo-Json -Depth 30 -Compress)
      Assert-Equal -Actual $dispatchJson1 -Expected $dispatchJson2 -Message "dispatch_plan must remain deterministic across repeated runs."
    }

    It "does not emit dispatch_plan for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.dispatch_plan) -Message "Malformed lead payload must not emit dispatch_plan."
    }
  }

  Context "15) deterministic delivery manifest contract" {
    It "emits deterministic delivery_manifest with ordered actions, lineage, and privacy-safe fields" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv012-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 910; conversion_bps = 270; impressions = 650 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv012-001"; segment = "saas"; pain_match = $true; budget = 2700; engagement_score = 83 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Delivery manifest run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Delivery manifest run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.delivery_manifest) -Message "Successful lead_enrich should emit delivery_manifest."

      $manifest = $run1.result.delivery_manifest
      $requiredManifestFields = @(
        "delivery_id",
        "dispatch_id",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "actions",
        "reason_codes"
      )
      foreach ($field in $requiredManifestFields) {
        Assert-True -Condition ($manifest.PSObject.Properties.Name -contains $field) -Message "delivery_manifest missing field: $field"
      }

      Assert-Equal -Actual ([string]$manifest.dispatch_id) -Expected ([string]$run1.result.dispatch_plan.dispatch_id) -Message "delivery_manifest dispatch_id mismatch."
      Assert-Equal -Actual ([string]$manifest.campaign_id) -Expected ([string]$run1.result.dispatch_plan.campaign_id) -Message "delivery_manifest campaign_id mismatch."
      Assert-Equal -Actual ([string]$manifest.channel) -Expected ([string]$run1.result.dispatch_plan.channel) -Message "delivery_manifest channel mismatch."
      Assert-Equal -Actual ([string]$manifest.language_code) -Expected ([string]$run1.result.dispatch_plan.language_code) -Message "delivery_manifest language_code mismatch."
      Assert-Equal -Actual ([string]$manifest.selected_variant_id) -Expected ([string]$run1.result.dispatch_plan.selected_variant_id) -Message "delivery_manifest variant mismatch."
      Assert-Equal -Actual ([string]$manifest.provider_mode) -Expected "mock" -Message "delivery_manifest provider_mode mismatch."
      Assert-Equal -Actual ([bool]$manifest.dry_run) -Expected $true -Message "delivery_manifest dry_run mismatch."

      $actions = @($manifest.actions)
      Assert-Equal -Actual $actions.Count -Expected 2 -Message "delivery_manifest actions should contain exactly two entries."
      Assert-Equal -Actual ([string]$actions[0].action_type) -Expected "cta_buy" -Message "delivery_manifest action ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$actions[1].action_type) -Expected "cta_subscribe" -Message "delivery_manifest action ordering mismatch for cta_subscribe."
      Assert-Equal -Actual ([string]$actions[0].action_stub) -Expected ([string]$run1.result.dispatch_plan.cta_buy_stub) -Message "delivery_manifest buy action stub mismatch."
      Assert-Equal -Actual ([string]$actions[1].action_stub) -Expected ([string]$run1.result.dispatch_plan.cta_subscribe_stub) -Message "delivery_manifest subscribe action stub mismatch."
      Assert-Equal -Actual ([string]$actions[0].ad_copy) -Expected ([string]$run1.result.dispatch_plan.ad_copy) -Message "delivery_manifest ad_copy mapping mismatch."
      Assert-Equal -Actual ([string]$actions[0].reply_template) -Expected ([string]$run1.result.dispatch_plan.reply_template) -Message "delivery_manifest reply_template mapping mismatch."

      Assert-Contains -Collection @($manifest.reason_codes) -Value "delivery_manifest_emitted" -Message "delivery_manifest should include emission reason code."
      Assert-Contains -Collection @($manifest.reason_codes) -Value "template_lang_native" -Message "delivery_manifest should include template lineage."
      Assert-Contains -Collection @($manifest.reason_codes) -Value "variant_lang_perf_win" -Message "delivery_manifest should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($manifest.PSObject.Properties.Name -contains $forbidden)) -Message "delivery_manifest must not expose $forbidden."
      }

      $manifestJson1 = ($run1.result.delivery_manifest | ConvertTo-Json -Depth 40 -Compress)
      $manifestJson2 = ($run2.result.delivery_manifest | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $manifestJson1 -Expected $manifestJson2 -Message "delivery_manifest must remain deterministic across repeated runs."
    }

    It "does not emit delivery_manifest for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.delivery_manifest) -Message "Malformed lead payload must not emit delivery_manifest."
    }
  }

  Context "16) deterministic sender envelope contract" {
    It "emits deterministic sender_envelope with ordered scheduled_actions, lineage, and privacy-safe fields" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv013-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 930; conversion_bps = 280; impressions = 700 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv013-001"; segment = "saas"; pain_match = $true; budget = 2800; engagement_score = 85 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Sender envelope run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Sender envelope run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.sender_envelope) -Message "Successful lead_enrich should emit sender_envelope."

      $envelope = $run1.result.sender_envelope
      $requiredEnvelopeFields = @(
        "envelope_id",
        "delivery_id",
        "dispatch_id",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "scheduled_actions",
        "reason_codes"
      )
      foreach ($field in $requiredEnvelopeFields) {
        Assert-True -Condition ($envelope.PSObject.Properties.Name -contains $field) -Message "sender_envelope missing field: $field"
      }

      Assert-Equal -Actual ([string]$envelope.delivery_id) -Expected ([string]$run1.result.delivery_manifest.delivery_id) -Message "sender_envelope delivery_id mismatch."
      Assert-Equal -Actual ([string]$envelope.dispatch_id) -Expected ([string]$run1.result.delivery_manifest.dispatch_id) -Message "sender_envelope dispatch_id mismatch."
      Assert-Equal -Actual ([string]$envelope.campaign_id) -Expected ([string]$run1.result.delivery_manifest.campaign_id) -Message "sender_envelope campaign_id mismatch."
      Assert-Equal -Actual ([string]$envelope.channel) -Expected ([string]$run1.result.delivery_manifest.channel) -Message "sender_envelope channel mismatch."
      Assert-Equal -Actual ([string]$envelope.language_code) -Expected ([string]$run1.result.delivery_manifest.language_code) -Message "sender_envelope language_code mismatch."
      Assert-Equal -Actual ([string]$envelope.selected_variant_id) -Expected ([string]$run1.result.delivery_manifest.selected_variant_id) -Message "sender_envelope variant mismatch."
      Assert-Equal -Actual ([string]$envelope.provider_mode) -Expected "mock" -Message "sender_envelope provider_mode mismatch."
      Assert-Equal -Actual ([bool]$envelope.dry_run) -Expected $true -Message "sender_envelope dry_run mismatch."

      $scheduled = @($envelope.scheduled_actions)
      Assert-Equal -Actual $scheduled.Count -Expected 2 -Message "sender_envelope scheduled_actions should contain exactly two entries."
      Assert-Equal -Actual ([string]$scheduled[0].action_type) -Expected "cta_buy" -Message "sender_envelope scheduled action ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$scheduled[1].action_type) -Expected "cta_subscribe" -Message "sender_envelope scheduled action ordering mismatch for cta_subscribe."
      Assert-Equal -Actual ([string]$scheduled[0].action_stub) -Expected ([string]$run1.result.delivery_manifest.actions[0].action_stub) -Message "sender_envelope cta_buy action_stub mismatch."
      Assert-Equal -Actual ([string]$scheduled[1].action_stub) -Expected ([string]$run1.result.delivery_manifest.actions[1].action_stub) -Message "sender_envelope cta_subscribe action_stub mismatch."
      Assert-Equal -Actual ([string]$scheduled[0].ad_copy) -Expected ([string]$run1.result.delivery_manifest.actions[0].ad_copy) -Message "sender_envelope cta_buy ad_copy mismatch."
      Assert-Equal -Actual ([string]$scheduled[0].reply_template) -Expected ([string]$run1.result.delivery_manifest.actions[0].reply_template) -Message "sender_envelope cta_buy reply_template mismatch."

      Assert-Contains -Collection @($envelope.reason_codes) -Value "sender_envelope_emitted" -Message "sender_envelope should include emission reason code."
      Assert-Contains -Collection @($envelope.reason_codes) -Value "template_lang_native" -Message "sender_envelope should include template lineage."
      Assert-Contains -Collection @($envelope.reason_codes) -Value "variant_lang_perf_win" -Message "sender_envelope should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($envelope.PSObject.Properties.Name -contains $forbidden)) -Message "sender_envelope must not expose $forbidden."
      }

      $envelopeJson1 = ($run1.result.sender_envelope | ConvertTo-Json -Depth 40 -Compress)
      $envelopeJson2 = ($run2.result.sender_envelope | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $envelopeJson1 -Expected $envelopeJson2 -Message "sender_envelope must remain deterministic across repeated runs."
    }

    It "does not emit sender_envelope for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.sender_envelope) -Message "Malformed lead payload must not emit sender_envelope."
    }
  }

  Context "17) deterministic adapter request contract" {
    It "emits deterministic adapter_request with ordered scheduled_actions, lineage, privacy, and idempotency" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv014-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 940; conversion_bps = 290; impressions = 710 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv014-001"; segment = "saas"; pain_match = $true; budget = 2900; engagement_score = 86 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Adapter request run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Adapter request run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.adapter_request) -Message "Successful lead_enrich should emit adapter_request."

      $request = $run1.result.adapter_request
      $requiredRequestFields = @(
        "request_id",
        "idempotency_key",
        "envelope_id",
        "delivery_id",
        "dispatch_id",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "scheduled_actions",
        "reason_codes"
      )
      foreach ($field in $requiredRequestFields) {
        Assert-True -Condition ($request.PSObject.Properties.Name -contains $field) -Message "adapter_request missing field: $field"
      }

      Assert-Equal -Actual ([string]$request.envelope_id) -Expected ([string]$run1.result.sender_envelope.envelope_id) -Message "adapter_request envelope_id mismatch."
      Assert-Equal -Actual ([string]$request.delivery_id) -Expected ([string]$run1.result.sender_envelope.delivery_id) -Message "adapter_request delivery_id mismatch."
      Assert-Equal -Actual ([string]$request.dispatch_id) -Expected ([string]$run1.result.sender_envelope.dispatch_id) -Message "adapter_request dispatch_id mismatch."
      Assert-Equal -Actual ([string]$request.campaign_id) -Expected ([string]$run1.result.sender_envelope.campaign_id) -Message "adapter_request campaign_id mismatch."
      Assert-Equal -Actual ([string]$request.channel) -Expected ([string]$run1.result.sender_envelope.channel) -Message "adapter_request channel mismatch."
      Assert-Equal -Actual ([string]$request.language_code) -Expected ([string]$run1.result.sender_envelope.language_code) -Message "adapter_request language_code mismatch."
      Assert-Equal -Actual ([string]$request.selected_variant_id) -Expected ([string]$run1.result.sender_envelope.selected_variant_id) -Message "adapter_request variant mismatch."
      Assert-Equal -Actual ([string]$request.provider_mode) -Expected "mock" -Message "adapter_request provider_mode mismatch."
      Assert-Equal -Actual ([bool]$request.dry_run) -Expected $true -Message "adapter_request dry_run mismatch."

      $scheduled = @($request.scheduled_actions)
      Assert-Equal -Actual $scheduled.Count -Expected 2 -Message "adapter_request scheduled_actions should contain exactly two entries."
      Assert-Equal -Actual ([string]$scheduled[0].action_type) -Expected "cta_buy" -Message "adapter_request scheduled action ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$scheduled[1].action_type) -Expected "cta_subscribe" -Message "adapter_request scheduled action ordering mismatch for cta_subscribe."
      Assert-Equal -Actual ([string]$scheduled[0].action_stub) -Expected ([string]$run1.result.sender_envelope.scheduled_actions[0].action_stub) -Message "adapter_request cta_buy action_stub mismatch."
      Assert-Equal -Actual ([string]$scheduled[1].action_stub) -Expected ([string]$run1.result.sender_envelope.scheduled_actions[1].action_stub) -Message "adapter_request cta_subscribe action_stub mismatch."
      Assert-Equal -Actual ([string]$scheduled[0].ad_copy) -Expected ([string]$run1.result.sender_envelope.scheduled_actions[0].ad_copy) -Message "adapter_request cta_buy ad_copy mismatch."
      Assert-Equal -Actual ([string]$scheduled[0].reply_template) -Expected ([string]$run1.result.sender_envelope.scheduled_actions[0].reply_template) -Message "adapter_request cta_buy reply_template mismatch."

      Assert-Contains -Collection @($request.reason_codes) -Value "adapter_request_emitted" -Message "adapter_request should include emission reason code."
      Assert-Contains -Collection @($request.reason_codes) -Value "template_lang_native" -Message "adapter_request should include template lineage."
      Assert-Contains -Collection @($request.reason_codes) -Value "variant_lang_perf_win" -Message "adapter_request should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($request.PSObject.Properties.Name -contains $forbidden)) -Message "adapter_request must not expose $forbidden."
      }

      Assert-Equal -Actual ([string]$run1.result.adapter_request.idempotency_key) -Expected ([string]$run2.result.adapter_request.idempotency_key) -Message "idempotency_key must remain stable across repeated runs."
      $requestJson1 = ($run1.result.adapter_request | ConvertTo-Json -Depth 40 -Compress)
      $requestJson2 = ($run2.result.adapter_request | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $requestJson1 -Expected $requestJson2 -Message "adapter_request must remain deterministic across repeated runs."

      $taskChangedCampaign = [pscustomobject]@{
        task_id = [guid]::NewGuid().ToString()
        task_type = "lead_enrich"
        payload = [pscustomobject]@{
          source_channel = "reddit"
          campaign_id = "camp-rv014-002"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 940; conversion_bps = 290; impressions = 710 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv014-002"; segment = "saas"; pain_match = $true; budget = 2900; engagement_score = 86 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $runChanged = Invoke-RevenueRun -Config $config -Task $taskChangedCampaign
      Assert-True -Condition (([string]$run1.result.adapter_request.idempotency_key) -ne ([string]$runChanged.result.adapter_request.idempotency_key)) -Message "idempotency_key should change when campaign lineage changes."
    }

    It "does not emit adapter_request for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.adapter_request) -Message "Malformed lead payload must not emit adapter_request."
    }
  }

  Context "18) deterministic dispatch receipt contract" {
    It "emits deterministic dispatch_receipt with ordered accepted_actions, lineage, privacy, and dry-run status" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv015-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 950; conversion_bps = 300; impressions = 720 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv015-001"; segment = "saas"; pain_match = $true; budget = 3000; engagement_score = 88 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Dispatch receipt run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Dispatch receipt run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.dispatch_receipt) -Message "Successful lead_enrich should emit dispatch_receipt."

      $receipt = $run1.result.dispatch_receipt
      $requiredReceiptFields = @(
        "receipt_id",
        "request_id",
        "idempotency_key",
        "envelope_id",
        "delivery_id",
        "dispatch_id",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "status",
        "accepted_actions",
        "reason_codes"
      )
      foreach ($field in $requiredReceiptFields) {
        Assert-True -Condition ($receipt.PSObject.Properties.Name -contains $field) -Message "dispatch_receipt missing field: $field"
      }

      Assert-Equal -Actual ([string]$receipt.request_id) -Expected ([string]$run1.result.adapter_request.request_id) -Message "dispatch_receipt request_id mismatch."
      Assert-Equal -Actual ([string]$receipt.idempotency_key) -Expected ([string]$run1.result.adapter_request.idempotency_key) -Message "dispatch_receipt idempotency_key mismatch."
      Assert-Equal -Actual ([string]$receipt.envelope_id) -Expected ([string]$run1.result.adapter_request.envelope_id) -Message "dispatch_receipt envelope_id mismatch."
      Assert-Equal -Actual ([string]$receipt.delivery_id) -Expected ([string]$run1.result.adapter_request.delivery_id) -Message "dispatch_receipt delivery_id mismatch."
      Assert-Equal -Actual ([string]$receipt.dispatch_id) -Expected ([string]$run1.result.adapter_request.dispatch_id) -Message "dispatch_receipt dispatch_id mismatch."
      Assert-Equal -Actual ([string]$receipt.campaign_id) -Expected ([string]$run1.result.adapter_request.campaign_id) -Message "dispatch_receipt campaign_id mismatch."
      Assert-Equal -Actual ([string]$receipt.channel) -Expected ([string]$run1.result.adapter_request.channel) -Message "dispatch_receipt channel mismatch."
      Assert-Equal -Actual ([string]$receipt.language_code) -Expected ([string]$run1.result.adapter_request.language_code) -Message "dispatch_receipt language_code mismatch."
      Assert-Equal -Actual ([string]$receipt.selected_variant_id) -Expected ([string]$run1.result.adapter_request.selected_variant_id) -Message "dispatch_receipt variant mismatch."
      Assert-Equal -Actual ([string]$receipt.provider_mode) -Expected "mock" -Message "dispatch_receipt provider_mode mismatch."
      Assert-Equal -Actual ([bool]$receipt.dry_run) -Expected $true -Message "dispatch_receipt dry_run mismatch."
      Assert-Equal -Actual ([string]$receipt.status) -Expected "simulated" -Message "dispatch_receipt status mismatch for dry-run path."

      $accepted = @($receipt.accepted_actions)
      Assert-Equal -Actual $accepted.Count -Expected 2 -Message "dispatch_receipt accepted_actions should contain exactly two entries."
      Assert-Equal -Actual ([string]$accepted[0].action_type) -Expected "cta_buy" -Message "dispatch_receipt action ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$accepted[1].action_type) -Expected "cta_subscribe" -Message "dispatch_receipt action ordering mismatch for cta_subscribe."
      Assert-Equal -Actual ([string]$accepted[0].action_stub) -Expected ([string]$run1.result.adapter_request.scheduled_actions[0].action_stub) -Message "dispatch_receipt cta_buy action_stub mismatch."
      Assert-Equal -Actual ([string]$accepted[1].action_stub) -Expected ([string]$run1.result.adapter_request.scheduled_actions[1].action_stub) -Message "dispatch_receipt cta_subscribe action_stub mismatch."
      Assert-Equal -Actual ([string]$accepted[0].ad_copy) -Expected ([string]$run1.result.adapter_request.scheduled_actions[0].ad_copy) -Message "dispatch_receipt cta_buy ad_copy mismatch."
      Assert-Equal -Actual ([string]$accepted[0].reply_template) -Expected ([string]$run1.result.adapter_request.scheduled_actions[0].reply_template) -Message "dispatch_receipt cta_buy reply_template mismatch."

      Assert-Contains -Collection @($receipt.reason_codes) -Value "dispatch_receipt_emitted" -Message "dispatch_receipt should include emission reason code."
      Assert-Contains -Collection @($receipt.reason_codes) -Value "dispatch_receipt_dry_run" -Message "dispatch_receipt should include dry-run reason code."
      Assert-Contains -Collection @($receipt.reason_codes) -Value "template_lang_native" -Message "dispatch_receipt should include template lineage."
      Assert-Contains -Collection @($receipt.reason_codes) -Value "variant_lang_perf_win" -Message "dispatch_receipt should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($receipt.PSObject.Properties.Name -contains $forbidden)) -Message "dispatch_receipt must not expose $forbidden."
      }

      $receiptJson1 = ($run1.result.dispatch_receipt | ConvertTo-Json -Depth 40 -Compress)
      $receiptJson2 = ($run2.result.dispatch_receipt | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $receiptJson1 -Expected $receiptJson2 -Message "dispatch_receipt must remain deterministic across repeated runs."
      Assert-Equal -Actual ([string]$run1.result.dispatch_receipt.idempotency_key) -Expected ([string]$run2.result.dispatch_receipt.idempotency_key) -Message "dispatch_receipt idempotency_key must remain stable across repeated runs."
    }

    It "does not emit dispatch_receipt for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.dispatch_receipt) -Message "Malformed lead payload must not emit dispatch_receipt."
    }
  }

  Context "19) deterministic audit record contract" {
    It "emits deterministic audit_record with ordered accepted_action_types, lineage, and privacy-safe fields" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv017-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 960; conversion_bps = 310; impressions = 730 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv017-001"; segment = "saas"; pain_match = $true; budget = 3200; engagement_score = 90 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Audit record run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Audit record run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.audit_record) -Message "Successful lead_enrich should emit audit_record."

      $record = $run1.result.audit_record
      $requiredRecordFields = @(
        "record_id",
        "event_id",
        "receipt_id",
        "request_id",
        "idempotency_key",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "status",
        "accepted_action_types",
        "reason_codes"
      )
      foreach ($field in $requiredRecordFields) {
        Assert-True -Condition ($record.PSObject.Properties.Name -contains $field) -Message "audit_record missing field: $field"
      }

      Assert-Equal -Actual ([string]$record.event_id) -Expected ([string]$run1.result.telemetry_event.event_id) -Message "audit_record event_id mismatch."
      Assert-Equal -Actual ([string]$record.receipt_id) -Expected ([string]$run1.result.telemetry_event.receipt_id) -Message "audit_record receipt_id mismatch."
      Assert-Equal -Actual ([string]$record.request_id) -Expected ([string]$run1.result.telemetry_event.request_id) -Message "audit_record request_id mismatch."
      Assert-Equal -Actual ([string]$record.idempotency_key) -Expected ([string]$run1.result.telemetry_event.idempotency_key) -Message "audit_record idempotency_key mismatch."
      Assert-Equal -Actual ([string]$record.campaign_id) -Expected ([string]$run1.result.telemetry_event.campaign_id) -Message "audit_record campaign_id mismatch."
      Assert-Equal -Actual ([string]$record.channel) -Expected ([string]$run1.result.telemetry_event.channel) -Message "audit_record channel mismatch."
      Assert-Equal -Actual ([string]$record.language_code) -Expected ([string]$run1.result.telemetry_event.language_code) -Message "audit_record language_code mismatch."
      Assert-Equal -Actual ([string]$record.selected_variant_id) -Expected ([string]$run1.result.telemetry_event.selected_variant_id) -Message "audit_record selected_variant_id mismatch."
      Assert-Equal -Actual ([string]$record.provider_mode) -Expected "mock" -Message "audit_record provider_mode mismatch."
      Assert-Equal -Actual ([bool]$record.dry_run) -Expected $true -Message "audit_record dry_run mismatch."
      Assert-Equal -Actual ([string]$record.status) -Expected "simulated" -Message "audit_record status mismatch."

      $acceptedActionTypes = @($record.accepted_action_types | ForEach-Object { [string]$_ })
      Assert-Equal -Actual $acceptedActionTypes.Count -Expected 2 -Message "audit_record accepted_action_types should contain exactly two entries."
      Assert-Equal -Actual ([string]$acceptedActionTypes[0]) -Expected "cta_buy" -Message "audit_record accepted_action_types ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$acceptedActionTypes[1]) -Expected "cta_subscribe" -Message "audit_record accepted_action_types ordering mismatch for cta_subscribe."

      Assert-Contains -Collection @($record.reason_codes) -Value "audit_record_emitted" -Message "audit_record should include emission reason code."
      Assert-Contains -Collection @($record.reason_codes) -Value "dispatch_receipt_dry_run" -Message "audit_record should include dry-run receipt lineage."
      Assert-Contains -Collection @($record.reason_codes) -Value "template_lang_native" -Message "audit_record should include template lineage."
      Assert-Contains -Collection @($record.reason_codes) -Value "variant_lang_perf_win" -Message "audit_record should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($record.PSObject.Properties.Name -contains $forbidden)) -Message "audit_record must not expose $forbidden."
      }

      $recordJson1 = ($run1.result.audit_record | ConvertTo-Json -Depth 40 -Compress)
      $recordJson2 = ($run2.result.audit_record | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $recordJson1 -Expected $recordJson2 -Message "audit_record must remain deterministic across repeated runs."
      Assert-Equal -Actual ([string]$run1.result.audit_record.idempotency_key) -Expected ([string]$run2.result.audit_record.idempotency_key) -Message "audit_record idempotency_key must remain stable across repeated runs."
    }

    It "does not emit audit_record for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.audit_record) -Message "Malformed lead payload must not emit audit_record."
    }
  }

  Context "20) deterministic evidence envelope contract" {
    It "emits deterministic evidence_envelope with ordered accepted_action_types, lineage, and privacy-safe fields" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv018-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 970; conversion_bps = 320; impressions = 740 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv018-001"; segment = "saas"; pain_match = $true; budget = 3400; engagement_score = 92 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Evidence envelope run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Evidence envelope run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.evidence_envelope) -Message "Successful lead_enrich should emit evidence_envelope."

      $envelope = $run1.result.evidence_envelope
      $requiredEnvelopeFields = @(
        "envelope_id",
        "record_id",
        "event_id",
        "receipt_id",
        "request_id",
        "idempotency_key",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "status",
        "accepted_action_types",
        "reason_codes"
      )
      foreach ($field in $requiredEnvelopeFields) {
        Assert-True -Condition ($envelope.PSObject.Properties.Name -contains $field) -Message "evidence_envelope missing field: $field"
      }

      Assert-Equal -Actual ([string]$envelope.record_id) -Expected ([string]$run1.result.audit_record.record_id) -Message "evidence_envelope record_id mismatch."
      Assert-Equal -Actual ([string]$envelope.event_id) -Expected ([string]$run1.result.audit_record.event_id) -Message "evidence_envelope event_id mismatch."
      Assert-Equal -Actual ([string]$envelope.receipt_id) -Expected ([string]$run1.result.audit_record.receipt_id) -Message "evidence_envelope receipt_id mismatch."
      Assert-Equal -Actual ([string]$envelope.request_id) -Expected ([string]$run1.result.audit_record.request_id) -Message "evidence_envelope request_id mismatch."
      Assert-Equal -Actual ([string]$envelope.idempotency_key) -Expected ([string]$run1.result.audit_record.idempotency_key) -Message "evidence_envelope idempotency_key mismatch."
      Assert-Equal -Actual ([string]$envelope.campaign_id) -Expected ([string]$run1.result.audit_record.campaign_id) -Message "evidence_envelope campaign_id mismatch."
      Assert-Equal -Actual ([string]$envelope.channel) -Expected ([string]$run1.result.audit_record.channel) -Message "evidence_envelope channel mismatch."
      Assert-Equal -Actual ([string]$envelope.language_code) -Expected ([string]$run1.result.audit_record.language_code) -Message "evidence_envelope language_code mismatch."
      Assert-Equal -Actual ([string]$envelope.selected_variant_id) -Expected ([string]$run1.result.audit_record.selected_variant_id) -Message "evidence_envelope selected_variant_id mismatch."
      Assert-Equal -Actual ([string]$envelope.provider_mode) -Expected "mock" -Message "evidence_envelope provider_mode mismatch."
      Assert-Equal -Actual ([bool]$envelope.dry_run) -Expected $true -Message "evidence_envelope dry_run mismatch."
      Assert-Equal -Actual ([string]$envelope.status) -Expected "simulated" -Message "evidence_envelope status mismatch."

      $acceptedActionTypes = @($envelope.accepted_action_types | ForEach-Object { [string]$_ })
      Assert-Equal -Actual $acceptedActionTypes.Count -Expected 2 -Message "evidence_envelope accepted_action_types should contain exactly two entries."
      Assert-Equal -Actual ([string]$acceptedActionTypes[0]) -Expected "cta_buy" -Message "evidence_envelope accepted_action_types ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$acceptedActionTypes[1]) -Expected "cta_subscribe" -Message "evidence_envelope accepted_action_types ordering mismatch for cta_subscribe."

      Assert-Contains -Collection @($envelope.reason_codes) -Value "evidence_envelope_emitted" -Message "evidence_envelope should include emission reason code."
      Assert-Contains -Collection @($envelope.reason_codes) -Value "dispatch_receipt_dry_run" -Message "evidence_envelope should include dry-run receipt lineage."
      Assert-Contains -Collection @($envelope.reason_codes) -Value "template_lang_native" -Message "evidence_envelope should include template lineage."
      Assert-Contains -Collection @($envelope.reason_codes) -Value "variant_lang_perf_win" -Message "evidence_envelope should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($envelope.PSObject.Properties.Name -contains $forbidden)) -Message "evidence_envelope must not expose $forbidden."
      }

      $envelopeJson1 = ($run1.result.evidence_envelope | ConvertTo-Json -Depth 40 -Compress)
      $envelopeJson2 = ($run2.result.evidence_envelope | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $envelopeJson1 -Expected $envelopeJson2 -Message "evidence_envelope must remain deterministic across repeated runs."
      Assert-Equal -Actual ([string]$run1.result.evidence_envelope.idempotency_key) -Expected ([string]$run2.result.evidence_envelope.idempotency_key) -Message "evidence_envelope idempotency_key must remain stable across repeated runs."
    }

    It "does not emit evidence_envelope for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.evidence_envelope) -Message "Malformed lead payload must not emit evidence_envelope."
    }
  }

  Context "21) deterministic retention manifest contract" {
    It "emits deterministic retention_manifest with ordered accepted_action_types, lineage, and privacy-safe fields" {
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
          source_channel = "reddit"
          campaign_id = "camp-rv019-001"
          language_code = "es-MX"
          region_code = "MX"
          trend_summary = [pscustomobject]@{
            segments = @(
              [pscustomobject]@{ language_code = "es"; region_code = "MX"; variant_id = "variant_es_perf"; ctr_bps = 980; conversion_bps = 330; impressions = 750 }
            )
          }
          leads = @(
            [pscustomobject]@{ lead_id = "lead-rv019-001"; segment = "saas"; pain_match = $true; budget = 3600; engagement_score = 94 }
          )
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run1 = Invoke-RevenueRun -Config $config -Task $task
      $run2 = Invoke-RevenueRun -Config $config -Task $task

      Assert-Equal -Actual $run1.exit_code -Expected 0 -Message "Retention manifest run should exit 0."
      Assert-Equal -Actual ([string]$run1.result.status) -Expected "SUCCESS" -Message "Retention manifest run should return SUCCESS."
      Assert-True -Condition ($null -ne $run1.result.retention_manifest) -Message "Successful lead_enrich should emit retention_manifest."

      $manifest = $run1.result.retention_manifest
      $requiredManifestFields = @(
        "manifest_id",
        "envelope_id",
        "record_id",
        "event_id",
        "receipt_id",
        "request_id",
        "idempotency_key",
        "campaign_id",
        "channel",
        "language_code",
        "selected_variant_id",
        "provider_mode",
        "dry_run",
        "status",
        "accepted_action_types",
        "reason_codes"
      )
      foreach ($field in $requiredManifestFields) {
        Assert-True -Condition ($manifest.PSObject.Properties.Name -contains $field) -Message "retention_manifest missing field: $field"
      }

      Assert-Equal -Actual ([string]$manifest.envelope_id) -Expected ([string]$run1.result.evidence_envelope.envelope_id) -Message "retention_manifest envelope_id mismatch."
      Assert-Equal -Actual ([string]$manifest.record_id) -Expected ([string]$run1.result.evidence_envelope.record_id) -Message "retention_manifest record_id mismatch."
      Assert-Equal -Actual ([string]$manifest.event_id) -Expected ([string]$run1.result.evidence_envelope.event_id) -Message "retention_manifest event_id mismatch."
      Assert-Equal -Actual ([string]$manifest.receipt_id) -Expected ([string]$run1.result.evidence_envelope.receipt_id) -Message "retention_manifest receipt_id mismatch."
      Assert-Equal -Actual ([string]$manifest.request_id) -Expected ([string]$run1.result.evidence_envelope.request_id) -Message "retention_manifest request_id mismatch."
      Assert-Equal -Actual ([string]$manifest.idempotency_key) -Expected ([string]$run1.result.evidence_envelope.idempotency_key) -Message "retention_manifest idempotency_key mismatch."
      Assert-Equal -Actual ([string]$manifest.campaign_id) -Expected ([string]$run1.result.evidence_envelope.campaign_id) -Message "retention_manifest campaign_id mismatch."
      Assert-Equal -Actual ([string]$manifest.channel) -Expected ([string]$run1.result.evidence_envelope.channel) -Message "retention_manifest channel mismatch."
      Assert-Equal -Actual ([string]$manifest.language_code) -Expected ([string]$run1.result.evidence_envelope.language_code) -Message "retention_manifest language_code mismatch."
      Assert-Equal -Actual ([string]$manifest.selected_variant_id) -Expected ([string]$run1.result.evidence_envelope.selected_variant_id) -Message "retention_manifest selected_variant_id mismatch."
      Assert-Equal -Actual ([string]$manifest.provider_mode) -Expected "mock" -Message "retention_manifest provider_mode mismatch."
      Assert-Equal -Actual ([bool]$manifest.dry_run) -Expected $true -Message "retention_manifest dry_run mismatch."
      Assert-Equal -Actual ([string]$manifest.status) -Expected "simulated" -Message "retention_manifest status mismatch."

      $acceptedActionTypes = @($manifest.accepted_action_types | ForEach-Object { [string]$_ })
      Assert-Equal -Actual $acceptedActionTypes.Count -Expected 2 -Message "retention_manifest accepted_action_types should contain exactly two entries."
      Assert-Equal -Actual ([string]$acceptedActionTypes[0]) -Expected "cta_buy" -Message "retention_manifest accepted_action_types ordering mismatch for cta_buy."
      Assert-Equal -Actual ([string]$acceptedActionTypes[1]) -Expected "cta_subscribe" -Message "retention_manifest accepted_action_types ordering mismatch for cta_subscribe."

      Assert-Contains -Collection @($manifest.reason_codes) -Value "retention_manifest_emitted" -Message "retention_manifest should include emission reason code."
      Assert-Contains -Collection @($manifest.reason_codes) -Value "dispatch_receipt_dry_run" -Message "retention_manifest should include dry-run receipt lineage."
      Assert-Contains -Collection @($manifest.reason_codes) -Value "template_lang_native" -Message "retention_manifest should include template lineage."
      Assert-Contains -Collection @($manifest.reason_codes) -Value "variant_lang_perf_win" -Message "retention_manifest should include variant lineage."

      $forbiddenFields = @("latitude", "longitude", "email", "phone", "ip_address")
      foreach ($forbidden in $forbiddenFields) {
        Assert-True -Condition (-not ($manifest.PSObject.Properties.Name -contains $forbidden)) -Message "retention_manifest must not expose $forbidden."
      }

      $manifestJson1 = ($run1.result.retention_manifest | ConvertTo-Json -Depth 40 -Compress)
      $manifestJson2 = ($run2.result.retention_manifest | ConvertTo-Json -Depth 40 -Compress)
      Assert-Equal -Actual $manifestJson1 -Expected $manifestJson2 -Message "retention_manifest must remain deterministic across repeated runs."
      Assert-Equal -Actual ([string]$run1.result.retention_manifest.idempotency_key) -Expected ([string]$run2.result.retention_manifest.idempotency_key) -Message "retention_manifest idempotency_key must remain stable across repeated runs."
    }

    It "does not emit retention_manifest for malformed lead payload FAILED path" {
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
          language_code = "en-US"
          leads = "bad-format"
        }
        created_at_utc = (Get-Date).ToUniversalTime().ToString("o")
      }

      $run = Invoke-RevenueRun -Config $config -Task $task
      Assert-Equal -Actual $run.exit_code -Expected 1 -Message "Malformed lead payload should return process exit 1."
      Assert-Equal -Actual ([string]$run.result.status) -Expected "FAILED" -Message "Malformed lead payload should return FAILED."
      Assert-True -Condition ($null -eq $run.result.retention_manifest) -Message "Malformed lead payload must not emit retention_manifest."
    }
  }
}
