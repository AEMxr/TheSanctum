param(
  [string]$EvidenceDir = ".",
  [switch]$AllowPreflightBlocked,
  [ValidateRange(1, 1000)][int]$ExpectedP0TestCount = 12
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -Path $EvidenceDir -PathType Container)) {
  Write-Error "Evidence directory not found: $EvidenceDir"
  exit 2
}

Push-Location $EvidenceDir
try {
  $BlockOnPreflightBlocked = -not $AllowPreflightBlocked.IsPresent
  $blockers = New-Object System.Collections.Generic.List[string]
  $warnings = New-Object System.Collections.Generic.List[string]
  $scriptName = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Leaf $PSCommandPath } else { "verify_evidence.ps1" }
  $scriptVersion = "v2.3.3"
  $hostName = [System.Net.Dns]::GetHostName()
  $pwshVersion = $PSVersionTable.PSVersion.ToString()
  $resolvedExpectedTestCount = $null
  $resolvedExpectedP0TestCount = $null
  $resolvedExpectedTelemetryTestCount = $null
  $resolvedExecutedTestCount = $null
  $gitCommit = ""
  try {
    if (Get-Command git -ErrorAction SilentlyContinue) {
      $gitOut = & git rev-parse --short=12 HEAD 2>$null
      if ($LASTEXITCODE -eq 0 -and $null -ne $gitOut) {
        $gitCommit = ([string]($gitOut | Select-Object -First 1)).Trim()
      }
    }
  }
  catch {
    # keep empty
  }

  function Add-Blocker {
    param([string]$Message)
    [void]$blockers.Add($Message)
  }

  function Add-Warning {
    param([string]$Message)
    [void]$warnings.Add($Message)
  }

  function Read-JsonFile {
    param([string]$Path)
    try {
      return Get-Content -Path $Path -Raw | ConvertFrom-Json
    }
    catch {
      Add-Blocker "$Path is not valid JSON: $($_.Exception.Message)"
      return $null
    }
  }

  function Read-TextFile {
    param([string]$Path)
    try {
      return Get-Content -Path $Path -Raw
    }
    catch {
      Add-Blocker "Unable to read ${Path}: $($_.Exception.Message)"
      return ""
    }
  }

  function Get-FileSha256Hex {
    param([string]$Path)
    try {
      $hash = Get-FileHash -Path $Path -Algorithm SHA256
      return $hash.Hash.ToLowerInvariant()
    }
    catch {
      Add-Blocker "Unable to hash ${Path}: $($_.Exception.Message)"
      return $null
    }
  }

  function Try-ParseStrictBool {
    param(
      [object]$Value,
      [ref]$Result
    )
    if ($Value -is [bool]) {
      $Result.Value = [bool]$Value
      return $true
    }
    if ($null -eq $Value) { return $false }
    $s = ([string]$Value).Trim().ToLowerInvariant()
    switch ($s) {
      "true" {
        $Result.Value = $true
        return $true
      }
      "false" {
        $Result.Value = $false
        return $true
      }
      default { return $false }
    }
  }

  function Is-MapLike {
    param([object]$Value)
    if ($null -eq $Value) { return $false }
    if ($Value -is [System.Array]) { return $false }
    return ($Value -is [System.Collections.IDictionary]) -or ($Value -is [pscustomobject])
  }

  function Get-MapEntries {
    param([object]$Map)
    $entries = @()
    if ($Map -is [System.Collections.IDictionary]) {
      foreach ($kv in $Map.GetEnumerator()) {
        $entries += [pscustomobject]@{ Key = [string]$kv.Key; Value = $kv.Value }
      }
      return $entries
    }
    if ($Map -is [pscustomobject]) {
      foreach ($p in $Map.PSObject.Properties) {
        $entries += [pscustomobject]@{ Key = [string]$p.Name; Value = $p.Value }
      }
    }
    return $entries
  }

  function Assert-NumberRange {
    param(
      [string]$FieldPath,
      $Value,
      [double]$Min,
      [double]$Max
    )
    $parsed = 0.0
    if ($null -eq $Value -or -not [double]::TryParse([string]$Value, [ref]$parsed)) {
      Add-Blocker "$FieldPath is not numeric"
      return
    }
    if ($parsed -lt $Min -or $parsed -gt $Max) {
      Add-Blocker "$FieldPath out of range [$Min,$Max]: $parsed"
    }
  }

  function Assert-IntMin {
    param(
      [string]$FieldPath,
      $Value,
      [int]$Min
    )
    $parsed = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$parsed)) {
      Add-Blocker "$FieldPath is not an integer"
      return
    }
    if ($parsed -lt $Min) {
      Add-Blocker "${FieldPath} is below minimum ${Min}: $parsed"
    }
  }

  function Try-ParseNonNegativeInt {
    param(
      [object]$Value,
      [ref]$Result
    )
    $parsed = 0
    if ($null -eq $Value -or -not [int]::TryParse([string]$Value, [ref]$parsed)) {
      return $false
    }
    if ($parsed -lt 0) { return $false }
    $Result.Value = $parsed
    return $true
  }

  # Required deliverables for RC evidence
  $requiredFiles = @(
    "checksums.txt",
    "db_verification_results.sql.out",
    "p0_gate_results.json",
    "telemetry_before.json",
    "telemetry_after.json",
    "api_negative_tests.json",
    "STAGING_EVIDENCE_v2_3.md",
    "p0_ci_gate.ps1",
    "sanctum_v2_2_runtime.sql",
    "openapi_hgmoe_v2_2.yaml",
    "council_contracts_v2_2.json"
  )

  # Newman artifact is conditional-but-required.
  $newmanArtifact = $null
  if (Test-Path "newman_summary.json" -PathType Leaf) {
    $newmanArtifact = "newman_summary.json"
  }
  elseif (Test-Path "newman_results.xml" -PathType Leaf) {
    $newmanArtifact = "newman_results.xml"
  }
  else {
    Add-Blocker "Missing Newman artifact: provide either newman_summary.json or newman_results.xml"
  }

  foreach ($f in $requiredFiles) {
    if (-not (Test-Path -Path $f -PathType Leaf)) {
      Add-Blocker "Missing required artifact: $f"
    }
  }

  # 1) Full telemetry key presence + basic numeric sanity
  $requiredTelemetryKeys = @(
    "material_action_without_valid_nonce_7d",
    "boundary_respect_rate_7d",
    "policy_check_failure_rate_7d",
    "council_disagreement_entropy_7d",
    "nonce_misuse_events_7d",
    "override_rate_by_domain_7d",
    "onboarding_completion_rate_current"
  )

  foreach ($tf in @("telemetry_before.json", "telemetry_after.json")) {
    if (Test-Path $tf) {
      $t = Read-JsonFile $tf
      if ($null -eq $t) { continue }

      # If this is a telemetry transport/error envelope, report once and skip payload-key checks.
      if ($t.PSObject.Properties.Name -contains "status_code") {
        $statusCode = 0
        if (-not [int]::TryParse([string]$t.status_code, [ref]$statusCode)) {
          Add-Blocker "$tf telemetry envelope has non-integer status_code: $($t.status_code)"
          continue
        }
        if ($statusCode -ne 200) {
          $err = if ($t.PSObject.Properties.Name -contains "error") { [string]$t.error } else { "unknown" }
          Add-Blocker "$tf telemetry fetch failed (status_code=$statusCode, error=$err)"
          continue
        }
      }
      elseif (($t.PSObject.Properties.Name -contains "request_url") -and ($t.PSObject.Properties.Name -contains "error")) {
        Add-Blocker "$tf telemetry fetch failed (missing status_code, error=$($t.error))"
        continue
      }

      foreach ($key in $requiredTelemetryKeys) {
        if (-not ($t.PSObject.Properties.Name -contains $key)) {
          Add-Blocker "$tf missing required key: $key"
        }
      }

      if ($t.PSObject.Properties.Name -contains "material_action_without_valid_nonce_7d") {
        Assert-IntMin "$tf.material_action_without_valid_nonce_7d" $t.material_action_without_valid_nonce_7d 0
      }
      if ($t.PSObject.Properties.Name -contains "boundary_respect_rate_7d") {
        Assert-NumberRange "$tf.boundary_respect_rate_7d" $t.boundary_respect_rate_7d 0 1
      }
      if ($t.PSObject.Properties.Name -contains "policy_check_failure_rate_7d") {
        Assert-NumberRange "$tf.policy_check_failure_rate_7d" $t.policy_check_failure_rate_7d 0 1
      }
      if ($t.PSObject.Properties.Name -contains "onboarding_completion_rate_current") {
        Assert-NumberRange "$tf.onboarding_completion_rate_current" $t.onboarding_completion_rate_current 0 1
      }

      if ($t.PSObject.Properties.Name -contains "nonce_misuse_events_7d") {
        $nm = $t.nonce_misuse_events_7d
        if (-not (Is-MapLike -Value $nm)) {
          Add-Blocker "$tf.nonce_misuse_events_7d must be an object"
        }
        else {
          foreach ($entry in (Get-MapEntries -Map $nm)) {
            if ([string]::IsNullOrWhiteSpace($entry.Key)) {
              Add-Blocker "$tf.nonce_misuse_events_7d contains an empty key"
              continue
            }
            $count = 0
            if ($null -eq $entry.Value -or -not [int]::TryParse([string]$entry.Value, [ref]$count) -or $count -lt 0) {
              Add-Blocker "$tf.nonce_misuse_events_7d[$($entry.Key)] must be a non-negative integer"
            }
          }
        }
      }

      if ($t.PSObject.Properties.Name -contains "override_rate_by_domain_7d") {
        $ov = $t.override_rate_by_domain_7d
        if (-not (Is-MapLike -Value $ov)) {
          Add-Blocker "$tf.override_rate_by_domain_7d must be an object"
        }
        else {
          foreach ($entry in (Get-MapEntries -Map $ov)) {
            if ([string]::IsNullOrWhiteSpace($entry.Key)) {
              Add-Blocker "$tf.override_rate_by_domain_7d contains an empty key"
              continue
            }
            Assert-NumberRange "$tf.override_rate_by_domain_7d.$($entry.Key)" $entry.Value 0 1
          }
        }
      }
    }
  }

  # 2) p0_gate_results hard_failures empty
  if (Test-Path "p0_gate_results.json") {
    $p0 = Read-JsonFile "p0_gate_results.json"
    if ($null -ne $p0) {
      $p0PreflightRan = $false
      $p0PreflightBlocked = $false
      $p0PreflightEnabled = $null
      $p0PreflightVerdict = ""
      $p0PreflightExitCode = $null
      if ($p0.PSObject.Properties.Name -contains "preflight_enabled") {
        $boolOut = $false
        if (Try-ParseStrictBool -Value $p0.preflight_enabled -Result ([ref]$boolOut)) {
          $p0PreflightEnabled = $boolOut
        }
        else {
          Add-Blocker "p0_gate_results.json preflight_enabled must be strict boolean true/false"
        }
      }
      if ($p0.PSObject.Properties.Name -contains "preflight_ran") {
        $boolOut = $false
        if (Try-ParseStrictBool -Value $p0.preflight_ran -Result ([ref]$boolOut)) {
          $p0PreflightRan = $boolOut
        }
        else {
          Add-Blocker "p0_gate_results.json preflight_ran must be strict boolean true/false"
        }
      }

      if ($p0.PSObject.Properties.Name -contains "preflight_blocked") {
        $boolOut = $false
        if (Try-ParseStrictBool -Value $p0.preflight_blocked -Result ([ref]$boolOut)) {
          $p0PreflightBlocked = $boolOut
        }
        else {
          Add-Blocker "p0_gate_results.json preflight_blocked must be strict boolean true/false"
        }
      }
      if ($p0.PSObject.Properties.Name -contains "preflight_verdict") {
        $p0PreflightVerdict = ([string]$p0.preflight_verdict).Trim()
      }
      if ($p0.PSObject.Properties.Name -contains "preflight_exit_code") {
        $tmpExitCode = 0
        if ([int]::TryParse([string]$p0.preflight_exit_code, [ref]$tmpExitCode)) {
          $p0PreflightExitCode = $tmpExitCode
        }
        else {
          Add-Blocker "p0_gate_results.json preflight_exit_code is not an integer: $($p0.preflight_exit_code)"
        }
      }

      # Resolve expected/executed test metadata from artifact in all modes.
      if ($p0.PSObject.Properties.Name -contains "expected_test_count") {
        $tmpExpectedTotal = 0
        if (Try-ParseNonNegativeInt -Value $p0.expected_test_count -Result ([ref]$tmpExpectedTotal)) {
          $resolvedExpectedTestCount = $tmpExpectedTotal
        }
        else {
          Add-Blocker "p0_gate_results.json expected_test_count is not a non-negative integer: $($p0.expected_test_count)"
        }
      }
      if ($p0.PSObject.Properties.Name -contains "expected_p0_test_count") {
        $tmpExpectedP0 = 0
        if (Try-ParseNonNegativeInt -Value $p0.expected_p0_test_count -Result ([ref]$tmpExpectedP0)) {
          $resolvedExpectedP0TestCount = $tmpExpectedP0
        }
        else {
          Add-Blocker "p0_gate_results.json expected_p0_test_count is not a non-negative integer: $($p0.expected_p0_test_count)"
        }
      }
      if ($p0.PSObject.Properties.Name -contains "expected_telemetry_test_count") {
        $tmpExpectedTelemetry = 0
        if (Try-ParseNonNegativeInt -Value $p0.expected_telemetry_test_count -Result ([ref]$tmpExpectedTelemetry)) {
          $resolvedExpectedTelemetryTestCount = $tmpExpectedTelemetry
        }
        else {
          Add-Blocker "p0_gate_results.json expected_telemetry_test_count is not a non-negative integer: $($p0.expected_telemetry_test_count)"
        }
      }
      if ($p0.PSObject.Properties.Name -contains "tests") {
        $resolvedExecutedTestCount = @($p0.tests).Count
      }
      if ($p0.PSObject.Properties.Name -contains "executed_test_count") {
        $tmpExecutedCount = 0
        if (Try-ParseNonNegativeInt -Value $p0.executed_test_count -Result ([ref]$tmpExecutedCount)) {
          if (($null -ne $resolvedExecutedTestCount) -and ($resolvedExecutedTestCount -ne $tmpExecutedCount)) {
            Add-Blocker "p0_gate_results.json executed_test_count mismatch: tests.Count=$resolvedExecutedTestCount, executed_test_count=$tmpExecutedCount"
          }
          $resolvedExecutedTestCount = $tmpExecutedCount
        }
        else {
          Add-Blocker "p0_gate_results.json executed_test_count is not a non-negative integer: $($p0.executed_test_count)"
        }
      }

      # Preflight state invariants for artifact integrity.
      if ($null -ne $p0PreflightEnabled -and -not $p0PreflightEnabled -and $p0PreflightRan) {
        Add-Blocker "p0_gate_results.json invalid preflight state: preflight_enabled=false but preflight_ran=true"
      }
      if ($p0PreflightRan -and [string]::IsNullOrWhiteSpace($p0PreflightVerdict)) {
        Add-Blocker "p0_gate_results.json invalid preflight state: preflight_ran=true requires preflight_verdict"
      }
      if ($p0PreflightRan -and $p0PreflightVerdict -in @("NOT_RUN", "SKIPPED")) {
        Add-Blocker "p0_gate_results.json invalid preflight state: preflight_ran=true with preflight_verdict=$p0PreflightVerdict"
      }
      if ($p0PreflightBlocked -and $p0PreflightVerdict -notin @("PREFLIGHT_BLOCKED", "MISSING_SCRIPT")) {
        Add-Blocker "p0_gate_results.json invalid preflight state: preflight_blocked=true requires preflight_verdict PREFLIGHT_BLOCKED|MISSING_SCRIPT (got '$p0PreflightVerdict')"
      }
      if ($p0PreflightRan -and $p0PreflightVerdict -eq "PREFLIGHT_READY" -and $null -ne $p0PreflightExitCode -and $p0PreflightExitCode -ne 0) {
        Add-Blocker "p0_gate_results.json invalid preflight state: PREFLIGHT_READY requires preflight_exit_code=0 (got $p0PreflightExitCode)"
      }
      if ($p0PreflightRan -and $p0PreflightVerdict -eq "PREFLIGHT_BLOCKED" -and $null -ne $p0PreflightExitCode -and $p0PreflightExitCode -eq 0) {
        Add-Blocker "p0_gate_results.json invalid preflight state: PREFLIGHT_BLOCKED with preflight_exit_code=0"
      }

      if ($p0PreflightRan) {
        if (-not (Test-Path "preflight_report.json" -PathType Leaf)) {
          if ($BlockOnPreflightBlocked) {
            Add-Blocker "Missing preflight_report.json while p0_gate_results.json indicates preflight_ran=true"
          }
          else {
            Add-Warning "Missing preflight_report.json while p0_gate_results.json indicates preflight_ran=true"
          }
        }
        else {
          $preflightReport = Read-JsonFile "preflight_report.json"
          if ($null -ne $preflightReport) {
            if (-not ($preflightReport.PSObject.Properties.Name -contains "verdict")) {
              if ($BlockOnPreflightBlocked) {
                Add-Blocker "preflight_report.json missing verdict"
              }
              else {
                Add-Warning "preflight_report.json missing verdict"
              }
            }
            else {
              $preflightVerdict = [string]$preflightReport.verdict
              if ($preflightVerdict -ne "PREFLIGHT_READY") {
                if ($BlockOnPreflightBlocked -or -not $p0PreflightBlocked) {
                  Add-Blocker "preflight_report.json expected verdict=PREFLIGHT_READY, got $preflightVerdict"
                }
                else {
                  Add-Warning "preflight_report.json verdict is '$preflightVerdict' (non-strict preflight mode)"
                }
              }
            }
          }
        }
      }

      if ($p0PreflightBlocked) {
        if ($BlockOnPreflightBlocked) {
          Add-Blocker "p0_gate_results.json indicates preflight_blocked=true"
        }
        else {
          Add-Warning "p0_gate_results.json indicates preflight_blocked=true (non-strict preflight mode)"
        }
        Add-Warning "Skipping strict p0 pass/fail aggregate checks because preflight was blocked."
      }
      else {
        if (-not ($p0.PSObject.Properties.Name -contains "gate_status")) {
          Add-Blocker "p0_gate_results.json missing gate_status"
        }
        elseif ([string]$p0.gate_status -ne "PASS") {
          Add-Blocker "p0_gate_results.json expected gate_status=PASS, got $($p0.gate_status)"
        }

        if ($p0.hard_failures -and $p0.hard_failures.Count -gt 0) {
          Add-Blocker "p0_gate_results.json contains hard_failures: $($p0.hard_failures -join ', ')"
        }

        $actualTestCount = $null
        if (-not ($p0.PSObject.Properties.Name -contains "tests")) {
          Add-Blocker "p0_gate_results.json missing tests array"
        }
        else {
          $testsArray = @($p0.tests)
          $actualTestCount = $testsArray.Count
          $resolvedExecutedTestCount = $actualTestCount
          $failedTests = @($testsArray | Where-Object { $_.Status -eq "FAIL" })
          if ($failedTests.Count -gt 0) {
            Add-Blocker "p0_gate_results.json has failing tests: $($failedTests.Count)"
          }
        }

        $parsedPassed = $null
        if (-not ($p0.PSObject.Properties.Name -contains "passed")) {
          Add-Blocker "p0_gate_results.json missing passed"
        }
        else {
          $tmpPassed = 0
          if ([int]::TryParse([string]$p0.passed, [ref]$tmpPassed)) {
            $parsedPassed = $tmpPassed
          }
          else {
            Add-Blocker "p0_gate_results.json passed is not an integer: $($p0.passed)"
          }
        }

        $parsedFailed = $null
        if (-not ($p0.PSObject.Properties.Name -contains "failed")) {
          Add-Blocker "p0_gate_results.json missing failed"
        }
        else {
          $tmpFailed = 0
          if ([int]::TryParse([string]$p0.failed, [ref]$tmpFailed)) {
            $parsedFailed = $tmpFailed
          }
          else {
            Add-Blocker "p0_gate_results.json failed is not an integer: $($p0.failed)"
          }
        }

        $expectedTotalCount = $resolvedExpectedTestCount
        $expectedP0Count = $resolvedExpectedP0TestCount
        $expectedTelemetryCount = $resolvedExpectedTelemetryTestCount

        if (($null -ne $expectedTotalCount) -and ($null -ne $expectedP0Count) -and ($null -ne $expectedTelemetryCount)) {
          if ($expectedTotalCount -ne ($expectedP0Count + $expectedTelemetryCount)) {
            Add-Blocker "p0_gate_results.json expected count mismatch: expected_test_count=$expectedTotalCount, expected_p0_test_count=$expectedP0Count, expected_telemetry_test_count=$expectedTelemetryCount"
          }
        }
        elseif (($null -eq $expectedTotalCount) -and ($null -ne $expectedP0Count) -and ($null -ne $expectedTelemetryCount)) {
          $expectedTotalCount = $expectedP0Count + $expectedTelemetryCount
        }

        if ($null -eq $expectedTotalCount -and (($p0.PSObject.Properties.Name -contains "skip_api_tests") -or ($p0.PSObject.Properties.Name -contains "skip_telemetry_gate"))) {
          $skipApiFromArtifact = $false
          $skipTelemetryFromArtifact = $false
          if ($p0.PSObject.Properties.Name -contains "skip_api_tests") {
            $tmpBool = $false
            if (Try-ParseStrictBool -Value $p0.skip_api_tests -Result ([ref]$tmpBool)) {
              $skipApiFromArtifact = $tmpBool
            }
            else {
              Add-Blocker "p0_gate_results.json skip_api_tests must be strict boolean true/false"
            }
          }
          if ($p0.PSObject.Properties.Name -contains "skip_telemetry_gate") {
            $tmpBool = $false
            if (Try-ParseStrictBool -Value $p0.skip_telemetry_gate -Result ([ref]$tmpBool)) {
              $skipTelemetryFromArtifact = $tmpBool
            }
            else {
              Add-Blocker "p0_gate_results.json skip_telemetry_gate must be strict boolean true/false"
            }
          }
          $expectedP0Count = if ($skipApiFromArtifact) { 0 } else { $ExpectedP0TestCount }
          $expectedTelemetryCount = if ($skipTelemetryFromArtifact) { 0 } else { 1 }
          $expectedTotalCount = $expectedP0Count + $expectedTelemetryCount
        }

        if ($null -eq $expectedTotalCount) {
          $expectedP0Count = $ExpectedP0TestCount
          $expectedTelemetryCount = 0
          $expectedTotalCount = $expectedP0Count
        }

        if ($null -eq $expectedP0Count -and $null -ne $expectedTotalCount -and $null -ne $expectedTelemetryCount) {
          $expectedP0Count = [Math]::Max(0, $expectedTotalCount - $expectedTelemetryCount)
        }
        if ($null -eq $expectedTelemetryCount -and $null -ne $expectedTotalCount -and $null -ne $expectedP0Count) {
          $expectedTelemetryCount = [Math]::Max(0, $expectedTotalCount - $expectedP0Count)
        }

        if ($null -ne $expectedTotalCount) {
          $resolvedExpectedTestCount = $expectedTotalCount
        }
        if ($null -ne $expectedP0Count) {
          $resolvedExpectedP0TestCount = $expectedP0Count
        }
        if ($null -ne $expectedTelemetryCount) {
          $resolvedExpectedTelemetryTestCount = $expectedTelemetryCount
        }

        if (($null -ne $actualTestCount) -and ($null -ne $expectedTotalCount) -and ($actualTestCount -ne $expectedTotalCount)) {
          Add-Blocker "p0_gate_results.json expected test count=$expectedTotalCount, got tests.Count=$actualTestCount"
        }

        if (($null -ne $actualTestCount) -and ($null -ne $resolvedExecutedTestCount) -and ($actualTestCount -ne $resolvedExecutedTestCount)) {
          Add-Blocker "p0_gate_results.json executed_test_count mismatch: expected tests.Count=$actualTestCount, got $resolvedExecutedTestCount"
        }

        if (($null -ne $parsedPassed) -and ($null -ne $parsedFailed)) {
          if ($parsedFailed -ne 0) {
            Add-Blocker "p0_gate_results.json expected failed=0, got $parsedFailed"
          }
          if ($null -ne $actualTestCount -and (($parsedPassed + $parsedFailed) -ne $actualTestCount)) {
            Add-Blocker "p0_gate_results.json passed+failed mismatch tests.Count (passed=$parsedPassed failed=$parsedFailed tests.Count=$actualTestCount)"
          }
          if (($null -ne $expectedTotalCount) -and ($parsedFailed -eq 0) -and ($parsedPassed -ne $expectedTotalCount)) {
            Add-Blocker "p0_gate_results.json expected passed=$expectedTotalCount, got $parsedPassed"
          }
        }
      }
    }
  }

  # 3) api_negative_tests.json required cases
  if (Test-Path "api_negative_tests.json") {
    $neg = Read-JsonFile "api_negative_tests.json"
    if ($null -ne $neg) {
      $requiredNegatives = @("NONCE_REPLAY", "NONCE_BINDING_MISMATCH", "CONSENT_EXPIRED", "recommendation whitespace rejection")
      $foundNegatives = @()
      $expectedNeg = @{
        "NONCE_REPLAY" = @{ status = 400; code = "NONCE_REPLAY" }
        "NONCE_BINDING_MISMATCH" = @{ status = 400; code = "NONCE_BINDING_MISMATCH" }
        "CONSENT_EXPIRED" = @{ status = 400; code = "CONSENT_EXPIRED" }
        "recommendation whitespace rejection" = @{ status = 400; code = "RECORD_INVALID" }
      }

      if ($neg -is [System.Collections.IEnumerable]) {
        foreach ($item in $neg) {
          if ($null -ne $item -and $item.PSObject.Properties.Name -contains "test_name") {
            $foundNegatives += [string]$item.test_name
          }
        }
      }
      else {
        Add-Blocker "api_negative_tests.json must be a JSON array"
      }

      foreach ($req in $requiredNegatives) {
        if (-not ($foundNegatives -contains $req)) {
          Add-Blocker "api_negative_tests.json missing required test: $req"
        }
      }

      foreach ($name in $expectedNeg.Keys) {
        $row = $neg | Where-Object { $_.test_name -eq $name } | Select-Object -First 1
        if ($null -eq $row) { continue }

        $statusMatchesExpected = $false
        if (-not ($row.PSObject.Properties.Name -contains "status_code")) {
          Add-Blocker "api_negative_tests.json[$name] missing status_code"
        }
        else {
          $parsedStatus = 0
          if (-not [int]::TryParse([string]$row.status_code, [ref]$parsedStatus)) {
            Add-Blocker "api_negative_tests.json[$name] status_code is not an integer: $($row.status_code)"
          }
          elseif ($parsedStatus -ne [int]$expectedNeg[$name].status) {
            Add-Blocker "api_negative_tests.json[$name] expected status $($expectedNeg[$name].status), got $($row.status_code)"
          }
          else {
            $statusMatchesExpected = $true
          }
        }

        if (-not ($row.PSObject.Properties.Name -contains "expected_error_code")) {
          Add-Blocker "api_negative_tests.json[$name] missing expected_error_code"
        }
        elseif ([string]$row.expected_error_code -ne [string]$expectedNeg[$name].code) {
          Add-Blocker "api_negative_tests.json[$name] expected_error_code mismatch: expected $($expectedNeg[$name].code), got $($row.expected_error_code)"
        }

        if ($statusMatchesExpected) {
          if (-not ($row.PSObject.Properties.Name -contains "actual_error_code")) {
            Add-Blocker "api_negative_tests.json[$name] missing actual_error_code"
          }
          elseif ([string]$row.actual_error_code -ne [string]$expectedNeg[$name].code) {
            Add-Blocker "api_negative_tests.json[$name] actual_error_code mismatch: expected $($expectedNeg[$name].code), got $($row.actual_error_code)"
          }
        }
      }
    }
  }

  # 4) checksums strictness (one entry per artifact, hex format)
  if (Test-Path "checksums.txt") {
    $checksumRequiredFiles = @(
      "db_verification_results.sql.out",
      "p0_gate_results.json",
      "telemetry_before.json",
      "telemetry_after.json",
      "api_negative_tests.json",
      "STAGING_EVIDENCE_v2_3.md",
      "p0_ci_gate.ps1",
      "sanctum_v2_2_runtime.sql",
      "openapi_hgmoe_v2_2.yaml",
      "council_contracts_v2_2.json"
    )
    if ($null -ne $newmanArtifact) {
      $checksumRequiredFiles += $newmanArtifact
    }

    $lines = Get-Content "checksums.txt"
    $seen = @{}
    $lineNumber = 0
    foreach ($line in $lines) {
      $lineNumber++
      if ($line -match '^(?i)([a-f0-9]{64})\s+(.+)$') {
        $hash = $matches[1]
        $file = $matches[2].Trim()
        if ($seen.ContainsKey($file)) {
          Add-Blocker "Duplicate entry in checksums.txt for $file"
        }
        $seen[$file] = $hash
        if ($hash.Length -ne 64) {
          Add-Blocker "Invalid hash length for $file"
        }

        if (-not (Test-Path -Path $file -PathType Leaf)) {
          Add-Blocker "checksums.txt references missing file: $file"
        }
        else {
          $actualHash = Get-FileSha256Hex -Path $file
          if ($null -ne $actualHash -and $actualHash -ne $hash) {
            Add-Blocker "Checksum mismatch for $file (expected=$hash, actual=$actualHash)"
          }
        }
      }
      else {
        Add-Blocker "Malformed line in checksums.txt (line $lineNumber): $line"
      }
    }

    foreach ($req in $checksumRequiredFiles) {
      if (-not $seen.ContainsKey($req)) {
        Add-Blocker "checksums.txt missing required artifact entry: $req"
      }
    }
  }

  # Optional evidence checks
  if (Test-Path "newman_summary.json") {
    $newman = Read-JsonFile "newman_summary.json"
    if ($null -ne $newman -and $newman.run.failures -and $newman.run.failures.Count -gt 0) {
      Add-Blocker "newman_summary.json contains failures: $($newman.run.failures.Count)"
    }
  }

  if (Test-Path "db_verification_results.sql.out") {
    $dbOut = Read-TextFile "db_verification_results.sql.out"
    if ($dbOut -match "P0_DB_CHECKS_FAILED|ERROR:") {
      Add-Blocker "db_verification_results.sql.out indicates SQL/check failure"
    }
  }

  # Emit summary report
  $report = [pscustomobject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    evidence_dir = (Resolve-Path ".").Path
    block_on_preflight_blocked = $BlockOnPreflightBlocked
    expected_p0_test_count = if ($null -ne $resolvedExpectedP0TestCount) { $resolvedExpectedP0TestCount } else { $ExpectedP0TestCount }
    requested_expected_p0_test_count = $ExpectedP0TestCount
    resolved_expected_test_count = $resolvedExpectedTestCount
    resolved_expected_p0_test_count = $resolvedExpectedP0TestCount
    resolved_expected_telemetry_test_count = $resolvedExpectedTelemetryTestCount
    resolved_executed_test_count = $resolvedExecutedTestCount
    script_name = $scriptName
    script_version = $scriptVersion
    git_commit = $gitCommit
    host = $hostName
    pwsh_version = $pwshVersion
    blockers = @($blockers)
    warnings = @($warnings)
    blocker_count = $blockers.Count
    warning_count = $warnings.Count
    verdict = if ($blockers.Count -eq 0) { "RC-STAGING-READY" } else { "RC-BLOCKED" }
  }
  $report | ConvertTo-Json -Depth 10 | Set-Content -Path "verify_evidence_report.json" -Encoding UTF8

  if ($warnings.Count -gt 0) {
    Write-Host "Warnings:"
    foreach ($w in $warnings) { Write-Host " - $w" }
  }

  if ($blockers.Count -gt 0) {
    Write-Host "Blockers:"
    foreach ($b in $blockers) { Write-Host " - $b" }
    Write-Host "VERDICT: RC-BLOCKED"
    exit 1
  }

  Write-Host "VERDICT: RC-STAGING-READY"
  exit 0
}
finally {
  Pop-Location
}
