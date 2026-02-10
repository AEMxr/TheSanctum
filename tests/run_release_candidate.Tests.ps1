# tests/run_release_candidate.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester tests/run_release_candidate.Tests.ps1

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

function Assert-NotNullOrEmptyString {
  param(
    [string]$Value,
    [string]$Message = "Expected non-empty string."
  )
  if ([string]::IsNullOrWhiteSpace($Value)) {
    throw $Message
  }
}

function Assert-IntLike {
  param(
    $Value,
    [string]$FieldName
  )
  $tmp = 0
  if (-not [int]::TryParse([string]$Value, [ref]$tmp)) {
    throw "$FieldName must be integer-like. Actual: $Value"
  }
}

function Assert-BoolLike {
  param(
    $Value,
    [string]$FieldName
  )
  try {
    [void][System.Convert]::ToBoolean($Value)
  }
  catch {
    throw "$FieldName must be boolean-like. Actual: $Value"
  }
}

Describe "run_release_candidate summary contract" {

  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $root = Resolve-Path (Join-Path $here "..")
    $script:SummaryPath = Join-Path $root "run_release_candidate_summary.json"

    if (-not (Test-Path -Path $script:SummaryPath -PathType Leaf)) {
      throw "Missing run_release_candidate_summary.json at: $script:SummaryPath"
    }

    $raw = Get-Content -Path $script:SummaryPath -Raw -Encoding UTF8
    $script:Summary = $raw | ConvertFrom-Json
  }

  Context "1) verdict consistency" {
    It "criteria_failure_count equals criteria_failures.Count" {
      Assert-Equal -Actual ([int]$script:Summary.criteria_failure_count) -Expected (@($script:Summary.criteria_failures).Count) -Message "criteria_failure_count mismatch."
    }

    It "verdict matches criteria failure count" {
      $expectedVerdict = if (([int]$script:Summary.criteria_failure_count) -eq 0) { "RELEASE_CANDIDATE_READY" } else { "RELEASE_CANDIDATE_BLOCKED" }
      Assert-Equal -Actual ([string]$script:Summary.verdict) -Expected $expectedVerdict -Message "verdict mismatch from criteria failure count."
    }
  }

  Context "2) ready-state invariants" {
    It "READY requires all strict clean-state conditions" {
      if ([string]$script:Summary.verdict -eq "RELEASE_CANDIDATE_READY") {
        Assert-Equal -Actual ([int]$script:Summary.staging_wrapper_exit_code) -Expected 0 -Message "READY requires staging_wrapper_exit_code=0."
        Assert-Equal -Actual ([string]$script:Summary.release_decision) -Expected "PASS" -Message "READY requires release_decision=PASS."
        Assert-Equal -Actual ([bool]$script:Summary.strict_release_gate_ready) -Expected $true -Message "READY requires strict_release_gate_ready=true."
        Assert-Equal -Actual ([int]$script:Summary.strict_exit) -Expected 0 -Message "READY requires strict_exit=0."
        Assert-Equal -Actual ([bool]$script:Summary.used_fallback_artifacts) -Expected $false -Message "READY requires used_fallback_artifacts=false."
        Assert-Equal -Actual ([int]$script:Summary.run_blocker_count) -Expected 0 -Message "READY requires run_blocker_count=0."
        Assert-Equal -Actual (@($script:Summary.release_gate_reason).Count) -Expected 0 -Message "READY requires empty release_gate_reason."
        Assert-Equal -Actual ([string]$script:Summary.strict_verify_report_verdict) -Expected "RC-STAGING-READY" -Message "READY requires strict verifier verdict RC-STAGING-READY."
        Assert-Equal -Actual ([int]$script:Summary.strict_verify_report_blocker_count) -Expected 0 -Message "READY requires strict verifier blocker_count=0."
      }
    }
  }

  Context "3) blocked-state invariants" {
    It "BLOCKED requires non-empty criteria failures" {
      if ([string]$script:Summary.verdict -eq "RELEASE_CANDIDATE_BLOCKED") {
        Assert-True -Condition (([int]$script:Summary.criteria_failure_count) -gt 0) -Message "BLOCKED requires criteria_failure_count > 0."
        Assert-True -Condition (@($script:Summary.criteria_failures).Count -gt 0) -Message "BLOCKED requires non-empty criteria_failures."
      }
    }
  }

  Context "4) strict verifier report linkage integrity" {
    It "strict verifier linkage fields are coherent and parseable" {
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.strict_verify_report_path) -Message "strict_verify_report_path must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.strict_verify_report_verdict) -Message "strict_verify_report_verdict must be non-empty."
      Assert-IntLike -Value $script:Summary.strict_verify_report_blocker_count -FieldName "strict_verify_report_blocker_count"

      if ($script:Summary.PSObject.Properties.Name -contains "strict_verify_report_warning_count") {
        if ($null -ne $script:Summary.strict_verify_report_warning_count -and -not [string]::IsNullOrWhiteSpace([string]$script:Summary.strict_verify_report_warning_count)) {
          Assert-IntLike -Value $script:Summary.strict_verify_report_warning_count -FieldName "strict_verify_report_warning_count"
        }
      }

      if (Test-Path -Path ([string]$script:Summary.strict_verify_report_path) -PathType Leaf) {
        $strictRaw = Get-Content -Path ([string]$script:Summary.strict_verify_report_path) -Raw -Encoding UTF8
        $strictReport = $strictRaw | ConvertFrom-Json

        if ($strictReport.PSObject.Properties.Name -contains "verdict") {
          Assert-Equal -Actual ([string]$script:Summary.strict_verify_report_verdict) -Expected ([string]$strictReport.verdict) -Message "strict verifier verdict mismatch between RC summary and strict report."
        }
        if ($strictReport.PSObject.Properties.Name -contains "blocker_count") {
          Assert-Equal -Actual ([int]$script:Summary.strict_verify_report_blocker_count) -Expected ([int]$strictReport.blocker_count) -Message "strict verifier blocker_count mismatch between RC summary and strict report."
        }
      }
    }
  }

  Context "5) schema sanity" {
    It "contains required top-level fields and parseable primitive types" {
      $required = @(
        "summary_schema_version",
        "generated_at_utc",
        "base_url",
        "evidence_dir",
        "staging_wrapper_path",
        "staging_summary_path",
        "strict_verify_report_path",
        "staging_wrapper_exit_code",
        "release_decision",
        "strict_release_gate_ready",
        "strict_exit",
        "strict_verify_report_verdict",
        "strict_verify_report_blocker_count",
        "used_fallback_artifacts",
        "run_blocker_count",
        "release_gate_reason",
        "criteria_failures",
        "criteria_failure_count",
        "verdict"
      )

      foreach ($name in $required) {
        Assert-True -Condition ($script:Summary.PSObject.Properties.Name -contains $name) -Message "Missing required field: $name"
      }

      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.generated_at_utc) -Message "generated_at_utc must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.summary_schema_version) -Message "summary_schema_version must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.base_url) -Message "base_url must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.evidence_dir) -Message "evidence_dir must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.staging_wrapper_path) -Message "staging_wrapper_path must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.staging_summary_path) -Message "staging_summary_path must be non-empty."
      Assert-NotNullOrEmptyString -Value ([string]$script:Summary.strict_verify_report_path) -Message "strict_verify_report_path must be non-empty."

      Assert-IntLike -Value $script:Summary.staging_wrapper_exit_code -FieldName "staging_wrapper_exit_code"
      Assert-BoolLike -Value $script:Summary.strict_release_gate_ready -FieldName "strict_release_gate_ready"
      Assert-IntLike -Value $script:Summary.strict_exit -FieldName "strict_exit"
      Assert-IntLike -Value $script:Summary.strict_verify_report_blocker_count -FieldName "strict_verify_report_blocker_count"
      Assert-BoolLike -Value $script:Summary.used_fallback_artifacts -FieldName "used_fallback_artifacts"
      Assert-IntLike -Value $script:Summary.run_blocker_count -FieldName "run_blocker_count"
      Assert-IntLike -Value $script:Summary.criteria_failure_count -FieldName "criteria_failure_count"

      Assert-True -Condition (([string]$script:Summary.release_decision) -in @("PASS", "FAIL", "UNKNOWN")) -Message "release_decision must be PASS|FAIL|UNKNOWN."
      Assert-True -Condition (([string]$script:Summary.verdict) -in @("RELEASE_CANDIDATE_READY", "RELEASE_CANDIDATE_BLOCKED")) -Message "verdict must be RELEASE_CANDIDATE_READY|RELEASE_CANDIDATE_BLOCKED."
    }
  }

  Context "6) summary schema compatibility" {
    BeforeAll {
      $script:SupportedRcSummarySchemas = @{
        "v2.4.0-draft1" = @(
          "summary_schema_version",
          "strict_verify_report_path",
          "strict_verify_report_verdict",
          "strict_verify_report_blocker_count",
          "release_decision",
          "strict_release_gate_ready",
          "criteria_failures",
          "criteria_failure_count",
          "verdict"
        )
        "v2.4.0" = @(
          "summary_schema_version",
          "strict_verify_report_path",
          "strict_verify_report_verdict",
          "strict_verify_report_blocker_count",
          "release_decision",
          "strict_release_gate_ready",
          "criteria_failures",
          "criteria_failure_count",
          "verdict"
        )
        "v2.4.1" = @(
          "summary_schema_version",
          "strict_verify_report_path",
          "strict_verify_report_verdict",
          "strict_verify_report_blocker_count",
          "release_decision",
          "strict_release_gate_ready",
          "criteria_failures",
          "criteria_failure_count",
          "verdict"
        )
      }
    }

    It "summary_schema_version is present and supported" {
      Assert-True -Condition ($script:Summary.PSObject.Properties.Name -contains "summary_schema_version") -Message "Missing required field: summary_schema_version"
      $schemaVersion = ([string]$script:Summary.summary_schema_version).Trim()
      Assert-NotNullOrEmptyString -Value $schemaVersion -Message "summary_schema_version must be non-empty."

      Assert-True -Condition $script:SupportedRcSummarySchemas.ContainsKey($schemaVersion) -Message "Unsupported summary_schema_version '$schemaVersion'. Add compatibility mapping before changing schema."
    }

    It "summary schema includes required RC linkage fields per compatibility map" {
      $schemaVersion = ([string]$script:Summary.summary_schema_version).Trim()
      if ($script:SupportedRcSummarySchemas.ContainsKey($schemaVersion)) {
        $requiredForSchema = @($script:SupportedRcSummarySchemas[$schemaVersion])
        foreach ($name in $requiredForSchema) {
          Assert-True -Condition ($script:Summary.PSObject.Properties.Name -contains $name) -Message "$schemaVersion missing required field: $name"
        }
      }
    }
  }
}
