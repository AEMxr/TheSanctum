param(
  [Parameter(Mandatory = $true)][string]$BaseUrl,
  [string]$EvidenceDir = ".",
  [string]$UserId = "",
  [string]$ApiKey = "",
  [string]$ApiHealthPath = "/health",
  [int]$TimeoutSec = 30,
  [string]$PsqlExe = "psql",
  [string[]]$PsqlArgs = @(),
  [string]$NewmanExe = "newman",
  [string[]]$NewmanArgs = @(),
  [string]$PostmanCollection = "",
  [switch]$AllowPreflightBlocked
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -Path $EvidenceDir -PathType Container)) {
  Write-Error "Evidence directory not found: $EvidenceDir"
  exit 2
}

$resolvedEvidenceDir = (Resolve-Path $EvidenceDir).Path
$scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$stagingWrapperPath = Join-Path $scriptDir "run_staging_v2_3.ps1"
$rcSummaryPath = Join-Path $resolvedEvidenceDir "run_release_candidate_summary.json"
$stagingSummaryPath = Join-Path $resolvedEvidenceDir "run_staging_summary.json"
$strictVerifyReportPath = Join-Path $resolvedEvidenceDir "verify_evidence_report.strict.json"
$helperModulePath = Join-Path $scriptDir "lib\release_gate_helpers.psm1"
$summarySchemaVersion = "v2.4.0"

if (Test-Path -Path $helperModulePath -PathType Leaf) {
  try {
    Import-Module $helperModulePath -Force -ErrorAction Stop
    if (Get-Command Get-ReleaseGateSchemaVersion -ErrorAction SilentlyContinue) {
      $summarySchemaVersion = Get-ReleaseGateSchemaVersion
    }
  }
  catch {
    # Keep default schema version when helper import fails.
  }
}

if (-not (Test-Path -Path $stagingWrapperPath -PathType Leaf)) {
  Write-Error "Missing staging wrapper: $stagingWrapperPath"
  exit 2
}

$criteriaFailures = New-Object System.Collections.Generic.List[string]
function Add-CriteriaFailure {
  param([string]$Message)
  [void]$criteriaFailures.Add($Message)
}

# Execute staging wrapper first.
$wrapperParams = @{
  BaseUrl = $BaseUrl
  EvidenceDir = $resolvedEvidenceDir
  ApiHealthPath = $ApiHealthPath
  TimeoutSec = $TimeoutSec
  PsqlExe = $PsqlExe
  PsqlArgs = $PsqlArgs
  NewmanExe = $NewmanExe
  NewmanArgs = $NewmanArgs
}
if (-not [string]::IsNullOrWhiteSpace($UserId)) { $wrapperParams["UserId"] = $UserId }
if (-not [string]::IsNullOrWhiteSpace($ApiKey)) { $wrapperParams["ApiKey"] = $ApiKey }
if (-not [string]::IsNullOrWhiteSpace($PostmanCollection)) { $wrapperParams["PostmanCollection"] = $PostmanCollection }
if ($AllowPreflightBlocked) { $wrapperParams["AllowPreflightBlocked"] = $true }

Write-Host "Executing staging wrapper: $stagingWrapperPath"
& $stagingWrapperPath @wrapperParams
$stagingWrapperExit = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }

$releaseDecision = "UNKNOWN"
$strictReleaseGateReady = $false
$strictExit = $null
$usedFallbackArtifacts = $null
$runBlockerCount = 0
$releaseGateReasons = @()
$strictVerifyReportVerdict = ""
$strictVerifyReportBlockerCount = $null
$strictVerifyReportWarningCount = $null

if (-not (Test-Path -Path $stagingSummaryPath -PathType Leaf)) {
  Add-CriteriaFailure "Missing run_staging_summary.json at $stagingSummaryPath"
}
else {
  try {
    $summary = Get-Content -Path $stagingSummaryPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($summary.PSObject.Properties.Name -contains "release_decision") {
      $releaseDecision = ([string]$summary.release_decision).Trim()
    }
    else {
      Add-CriteriaFailure "run_staging_summary.json missing release_decision"
    }

    if ($summary.PSObject.Properties.Name -contains "strict_release_gate_ready") {
      try {
        $strictReleaseGateReady = [System.Convert]::ToBoolean($summary.strict_release_gate_ready)
      }
      catch {
        Add-CriteriaFailure "run_staging_summary.json strict_release_gate_ready is not boolean-like: $($summary.strict_release_gate_ready)"
      }
    }
    else {
      Add-CriteriaFailure "run_staging_summary.json missing strict_release_gate_ready"
    }

    if ($summary.PSObject.Properties.Name -contains "strict_exit") {
      $tmpStrictExit = 0
      if ([int]::TryParse([string]$summary.strict_exit, [ref]$tmpStrictExit)) {
        $strictExit = $tmpStrictExit
      }
      else {
        Add-CriteriaFailure "run_staging_summary.json strict_exit is not an integer: $($summary.strict_exit)"
      }
    }
    else {
      Add-CriteriaFailure "run_staging_summary.json missing strict_exit"
    }

    if ($summary.PSObject.Properties.Name -contains "used_fallback_artifacts") {
      try {
        $usedFallbackArtifacts = [System.Convert]::ToBoolean($summary.used_fallback_artifacts)
      }
      catch {
        Add-CriteriaFailure "run_staging_summary.json used_fallback_artifacts is not boolean-like: $($summary.used_fallback_artifacts)"
      }
    }
    else {
      Add-CriteriaFailure "run_staging_summary.json missing used_fallback_artifacts"
    }

    $runBlockerCount = @($summary.run_blockers).Count
    $releaseGateReasons = @($summary.release_gate_reason)
  }
  catch {
    Add-CriteriaFailure "Unable to parse run_staging_summary.json: $($_.Exception.Message)"
  }
}

# Enrich and validate against strict verifier report for standalone RC auditing.
if (-not (Test-Path -Path $strictVerifyReportPath -PathType Leaf)) {
  Add-CriteriaFailure "Missing verify_evidence_report.strict.json at $strictVerifyReportPath"
}
else {
  try {
    $strictReport = Get-Content -Path $strictVerifyReportPath -Raw -Encoding UTF8 | ConvertFrom-Json

    if ($strictReport.PSObject.Properties.Name -contains "verdict") {
      $strictVerifyReportVerdict = ([string]$strictReport.verdict).Trim()
    }
    else {
      Add-CriteriaFailure "verify_evidence_report.strict.json missing verdict"
    }

    if ($strictReport.PSObject.Properties.Name -contains "blocker_count") {
      $tmpBlockers = 0
      if ([int]::TryParse([string]$strictReport.blocker_count, [ref]$tmpBlockers)) {
        $strictVerifyReportBlockerCount = $tmpBlockers
      }
      else {
        Add-CriteriaFailure "verify_evidence_report.strict.json blocker_count is not an integer: $($strictReport.blocker_count)"
      }
    }
    else {
      Add-CriteriaFailure "verify_evidence_report.strict.json missing blocker_count"
    }

    if ($strictReport.PSObject.Properties.Name -contains "warning_count") {
      $tmpWarnings = 0
      if ([int]::TryParse([string]$strictReport.warning_count, [ref]$tmpWarnings)) {
        $strictVerifyReportWarningCount = $tmpWarnings
      }
    }
  }
  catch {
    Add-CriteriaFailure "Unable to parse verify_evidence_report.strict.json: $($_.Exception.Message)"
  }
}

# Release-candidate hard criteria.
if ($stagingWrapperExit -ne 0) { Add-CriteriaFailure "Staging wrapper exit code is non-zero: $stagingWrapperExit" }
if ($releaseDecision -ne "PASS") { Add-CriteriaFailure "release_decision must be PASS (got '$releaseDecision')" }
if (-not $strictReleaseGateReady) { Add-CriteriaFailure "strict_release_gate_ready must be true" }
if ($null -eq $strictExit -or $strictExit -ne 0) { Add-CriteriaFailure "strict_exit must be 0 (got '$strictExit')" }
if ($null -eq $usedFallbackArtifacts -or $usedFallbackArtifacts) { Add-CriteriaFailure "used_fallback_artifacts must be false (got '$usedFallbackArtifacts')" }
if ($runBlockerCount -gt 0) { Add-CriteriaFailure "run_blockers must be empty (count=$runBlockerCount)" }
if (@($releaseGateReasons).Count -gt 0) { Add-CriteriaFailure "release_gate_reason must be empty for release candidate promotion" }
if ($strictVerifyReportVerdict -and $strictVerifyReportVerdict -ne "RC-STAGING-READY") { Add-CriteriaFailure "verify_evidence_report.strict.json verdict must be RC-STAGING-READY (got '$strictVerifyReportVerdict')" }
if ($null -ne $strictVerifyReportBlockerCount -and $strictVerifyReportBlockerCount -ne 0) { Add-CriteriaFailure "verify_evidence_report.strict.json blocker_count must be 0 (got $strictVerifyReportBlockerCount)" }

$verdict = if ($criteriaFailures.Count -eq 0) { "RELEASE_CANDIDATE_READY" } else { "RELEASE_CANDIDATE_BLOCKED" }
$rcSummary = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  summary_schema_version = $summarySchemaVersion
  base_url = $BaseUrl
  evidence_dir = $resolvedEvidenceDir
  staging_wrapper_path = $stagingWrapperPath
  staging_summary_path = $stagingSummaryPath
  strict_verify_report_path = $strictVerifyReportPath
  staging_wrapper_exit_code = $stagingWrapperExit
  release_decision = $releaseDecision
  strict_release_gate_ready = $strictReleaseGateReady
  strict_exit = $strictExit
  strict_verify_report_verdict = $strictVerifyReportVerdict
  strict_verify_report_blocker_count = $strictVerifyReportBlockerCount
  strict_verify_report_warning_count = $strictVerifyReportWarningCount
  used_fallback_artifacts = $usedFallbackArtifacts
  run_blocker_count = $runBlockerCount
  release_gate_reason = @($releaseGateReasons)
  criteria_failures = @($criteriaFailures.ToArray())
  criteria_failure_count = $criteriaFailures.Count
  verdict = $verdict
}
$rcSummary | ConvertTo-Json -Depth 20 | Set-Content -Path $rcSummaryPath -Encoding UTF8

Write-Host "STAGING_WRAPPER_EXIT=$stagingWrapperExit"
Write-Host "RELEASE_DECISION=$releaseDecision"
Write-Host "RC_VERDICT=$verdict"

if ($criteriaFailures.Count -gt 0) {
  Write-Host "Release Gate Blockers:"
  foreach ($failure in $criteriaFailures) {
    Write-Host " - $failure"
  }
  exit 1
}

exit 0
