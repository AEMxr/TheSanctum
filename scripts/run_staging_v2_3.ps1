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

if ([string]::IsNullOrWhiteSpace($UserId)) {
  $UserId = [guid]::NewGuid().ToString()
}

if (-not (Test-Path -Path $EvidenceDir -PathType Container)) {
  Write-Error "Evidence directory not found: $EvidenceDir"
  exit 2
}

$resolvedEvidenceDir = (Resolve-Path $EvidenceDir).Path
$stamp = (Get-Date).ToString("yyyyMMdd_HHmmss")

$script:RunBlockers = New-Object System.Collections.Generic.List[string]
$script:RunWarnings = New-Object System.Collections.Generic.List[string]
$script:RunStepResults = New-Object System.Collections.Generic.List[object]
$script:FallbackArtifacts = New-Object System.Collections.Generic.List[object]

function Add-RunBlocker {
  param([string]$Message)
  [void]$script:RunBlockers.Add($Message)
}

function Add-RunWarning {
  param([string]$Message)
  [void]$script:RunWarnings.Add($Message)
}

function Add-FallbackArtifact {
  param(
    [string]$Artifact,
    [string]$Reason,
    [string]$Type = "synthetic_missing_artifact"
  )

  if ([string]::IsNullOrWhiteSpace($Artifact)) { return }
  $allowedFallbackTypes = @(
    "transport_envelope",
    "synthetic_missing_artifact",
    "derived_failure_output"
  )
  if ([string]::IsNullOrWhiteSpace($Type) -or ($allowedFallbackTypes -notcontains $Type)) {
    $Type = "synthetic_missing_artifact"
  }
  $existing = $script:FallbackArtifacts | Where-Object { $_.artifact -eq $Artifact } | Select-Object -First 1
  if ($null -ne $existing) { return }

  [void]$script:FallbackArtifacts.Add([pscustomobject]@{
    artifact = $Artifact
    reason = $Reason
    type = $Type
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  })
}

function Ensure-Directory {
  param([string]$Path)
  if (-not (Test-Path -Path $Path -PathType Container)) {
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
  }
}

function Resolve-Tool {
  param([string]$ToolName)
  if ([string]::IsNullOrWhiteSpace($ToolName)) { return $null }
  $cmd = Get-Command $ToolName -ErrorAction SilentlyContinue
  if ($null -eq $cmd) { return $null }
  return $cmd.Source
}

function Test-FileExists {
  param([string]$Path)
  return (Test-Path -Path $Path -PathType Leaf)
}

function Invoke-LoggedStep {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$LogPath,
    [Parameter(Mandatory = $true)][scriptblock]$Script
  )

  $start = Get-Date
  $exitCode = -1
  $errorText = ""

  try {
    & $Script *>&1 | Tee-Object -FilePath $LogPath | Out-Host
    if ($null -eq $LASTEXITCODE) {
      $exitCode = 0
    }
    else {
      $exitCode = [int]$LASTEXITCODE
    }
  }
  catch {
    $exitCode = -1
    $errorText = [string]$_.Exception.Message
    "EXCEPTION: $errorText" | Tee-Object -FilePath $LogPath -Append | Out-Null
  }

  $durationMs = [int]((Get-Date) - $start).TotalMilliseconds
  $result = [pscustomobject]@{
    name = $Name
    exit_code = $exitCode
    duration_ms = $durationMs
    log = $LogPath
    success = ($exitCode -eq 0)
    error = $errorText
  }
  [void]$script:RunStepResults.Add($result)

  return $result
}

function Save-TelemetrySnapshot {
  param(
    [Parameter(Mandatory = $true)][string]$Base,
    [Parameter(Mandatory = $true)][string]$Uid,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [string]$ApiToken = "",
    [int]$RequestTimeoutSec = 30
  )

  $headers = @{}
  if (-not [string]::IsNullOrWhiteSpace($ApiToken)) {
    $headers["Authorization"] = "Bearer $ApiToken"
  }

  $uri = "$Base/telemetry/dashboard?user_stable_id=$Uid"
  try {
    $resp = Invoke-RestMethod -Method GET -Uri $uri -Headers $headers -TimeoutSec $RequestTimeoutSec
    $resp | ConvertTo-Json -Depth 50 | Set-Content -Encoding UTF8 -Path $OutFile
    return [pscustomobject]@{
      is_error_envelope = $false
      status_code = 200
      error = ""
      request_url = $uri
    }
  }
  catch {
    $envelope = [pscustomobject]@{
      request_url = $uri
      status_code = -1
      error = [string]$_.Exception.Message
      captured_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    }
    $envelope | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $OutFile
    return [pscustomobject]@{
      is_error_envelope = $true
      status_code = -1
      error = [string]$_.Exception.Message
      request_url = $uri
    }
  }
}

function Ensure-ApiNegativeTestsSkeleton {
  param([string]$Path)

  if (Test-FileExists -Path $Path) { return $false }

  $skeleton = @(
    [pscustomobject]@{
      test_name = "NONCE_REPLAY"
      status_code = -1
      expected_error_code = "NONCE_REPLAY"
      actual_error_code = ""
      notes = "Generated fallback artifact: API negative tests not produced."
    },
    [pscustomobject]@{
      test_name = "NONCE_BINDING_MISMATCH"
      status_code = -1
      expected_error_code = "NONCE_BINDING_MISMATCH"
      actual_error_code = ""
      notes = "Generated fallback artifact: API negative tests not produced."
    },
    [pscustomobject]@{
      test_name = "CONSENT_EXPIRED"
      status_code = -1
      expected_error_code = "CONSENT_EXPIRED"
      actual_error_code = ""
      notes = "Generated fallback artifact: API negative tests not produced."
    },
    [pscustomobject]@{
      test_name = "recommendation whitespace rejection"
      status_code = -1
      expected_error_code = "RECORD_INVALID"
      actual_error_code = ""
      notes = "Generated fallback artifact: API negative tests not produced."
    }
  )

  $skeleton | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 -Path $Path
  return $true
}

function Ensure-NewmanSummarySkeleton {
  param([string]$Path, [string]$Reason)

  if (Test-FileExists -Path $Path) { return $false }

  $summary = [pscustomobject]@{
    run = [pscustomobject]@{
      stats = [pscustomobject]@{
        assertions = [pscustomobject]@{ total = 0; failed = 1 }
      }
      failures = @(
        [pscustomobject]@{
          error = [pscustomobject]@{
            message = $Reason
          }
        }
      )
    }
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
  }
  $summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 -Path $Path
  return $true
}

function Ensure-P0SummarySkeleton {
  param(
    [string]$Path,
    [string]$Base,
    [string]$Uid,
    [bool]$PreflightEnabled,
    [bool]$PreflightRan,
    [bool]$PreflightBlocked,
    [string]$PreflightVerdict,
    [int]$PreflightExitCode,
    [string]$Reason
  )

  if (Test-FileExists -Path $Path) { return $false }

  $summary = [pscustomobject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    base_url = $Base
    user_id = $Uid
    thresholds = [pscustomobject]@{}
    warnings = @()
    hard_failures = @($Reason)
    tests = @()
    passed = 0
    failed = 1
    expected_test_count = 0
    expected_p0_test_count = 0
    expected_telemetry_test_count = 0
    executed_test_count = 0
    gate_status = "FAIL"
    skip_api_tests = $true
    skip_telemetry_gate = $true
    preflight_enabled = $PreflightEnabled
    preflight_ran = $PreflightRan
    preflight_blocked = $PreflightBlocked
    preflight_verdict = $PreflightVerdict
    preflight_exit_code = $PreflightExitCode
    preflight_report_path = "preflight_report.json"
  }
  $summary | ConvertTo-Json -Depth 30 | Set-Content -Encoding UTF8 -Path $Path
  return $true
}

function Ensure-DbVerificationFallback {
  param([string]$OutPath, [string]$Reason)
  if (Test-FileExists -Path $OutPath) { return $false }
  @(
    "# Generated fallback artifact"
    "# $Reason"
    "P0_DB_CHECKS_FAILED"
  ) | Set-Content -Encoding UTF8 -Path $OutPath
  return $true
}

function Write-ChecksumsForExisting {
  param(
    [string]$Dir,
    [string]$NewmanArtifactName
  )

  $targets = @(
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
  if (-not [string]::IsNullOrWhiteSpace($NewmanArtifactName)) {
    $targets += $NewmanArtifactName
  }

  $lines = New-Object System.Collections.Generic.List[string]
  foreach ($f in $targets) {
    $path = Join-Path $Dir $f
    if (Test-FileExists -Path $path) {
      $hash = (Get-FileHash -Path $path -Algorithm SHA256).Hash.ToLowerInvariant()
      [void]$lines.Add("$hash  $f")
    }
  }

  Set-Content -Path (Join-Path $Dir "checksums.txt") -Encoding UTF8 -Value $lines
}

$summarySchemaVersion = "v2.4.0"
$wrapperScriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
$helperModulePath = Join-Path $wrapperScriptDir "lib\release_gate_helpers.psm1"
if (Test-FileExists -Path $helperModulePath) {
  try {
    Import-Module $helperModulePath -Force -ErrorAction Stop
    if (Get-Command Get-ReleaseGateSchemaVersion -ErrorAction SilentlyContinue) {
      $summarySchemaVersion = Get-ReleaseGateSchemaVersion
    }
  }
  catch {
    Add-RunWarning "Helper module import failed ($helperModulePath): $($_.Exception.Message)"
  }
}

Push-Location $resolvedEvidenceDir
try {
  $logsDir = Join-Path $resolvedEvidenceDir "artifacts\logs"
  Ensure-Directory -Path $logsDir

  $preflightLog = Join-Path $logsDir "preflight_$stamp.log"
  $dbLog = Join-Path $logsDir "db_checks_$stamp.log"
  $gateLog = Join-Path $logsDir "p0_gate_$stamp.log"
  $verifyStrictLog = Join-Path $logsDir "verify_strict_$stamp.log"
  $verifyNonStrictLog = Join-Path $logsDir "verify_non_strict_$stamp.log"

  $preflightExit = -1
  $dbExit = -1
  $gateExit = -1
  $strictVerifyExit = -1
  $nonStrictVerifyExit = $null

  # Soft prechecks (record blockers, continue to produce artifacts/logs).
  $preflightScriptExists = Test-FileExists -Path ".\preflight_env.ps1"
  $p0ScriptExists = Test-FileExists -Path ".\p0_ci_gate.ps1"
  $verifyScriptExists = Test-FileExists -Path ".\verify_evidence.ps1"
  $dbChecksExists = Test-FileExists -Path ".\p0_db_checks.sql"
  $stagingEvidenceExists = Test-FileExists -Path ".\STAGING_EVIDENCE_v2_3.md"
  $runtimeSqlExists = Test-FileExists -Path ".\sanctum_v2_2_runtime.sql"
  $openApiExists = Test-FileExists -Path ".\openapi_hgmoe_v2_2.yaml"
  $contractsExists = Test-FileExists -Path ".\council_contracts_v2_2.json"

  if (-not $preflightScriptExists) { Add-RunBlocker "Missing required file: preflight_env.ps1" }
  if (-not $p0ScriptExists) { Add-RunBlocker "Missing required file: p0_ci_gate.ps1" }
  if (-not $verifyScriptExists) { Add-RunBlocker "Missing required file: verify_evidence.ps1" }
  if (-not $dbChecksExists) { Add-RunBlocker "Missing required file: p0_db_checks.sql" }
  if (-not $stagingEvidenceExists) { Add-RunBlocker "Missing required file: STAGING_EVIDENCE_v2_3.md" }
  if (-not $runtimeSqlExists) { Add-RunBlocker "Missing required file: sanctum_v2_2_runtime.sql" }
  if (-not $openApiExists) { Add-RunBlocker "Missing required file: openapi_hgmoe_v2_2.yaml" }
  if (-not $contractsExists) { Add-RunBlocker "Missing required file: council_contracts_v2_2.json" }

  $psqlPath = Resolve-Tool -ToolName $PsqlExe
  $newmanPath = Resolve-Tool -ToolName $NewmanExe
  if ($null -eq $psqlPath) { Add-RunBlocker "Required executable not found on PATH: $PsqlExe" }
  if ($null -eq $newmanPath) { Add-RunBlocker "Required executable not found on PATH: $NewmanExe" }

  if (-not [string]::IsNullOrWhiteSpace($PostmanCollection) -and -not (Test-FileExists -Path $PostmanCollection)) {
    Add-RunBlocker "Postman collection not found: $PostmanCollection"
  }

  $preflightEnabled = $true
  $preflightRan = $false
  $preflightBlocked = $false
  $preflightVerdict = "NOT_RUN"
  $preflightExitCode = -1

  $dbOutputPath = ".\db_verification_results.sql.out"
  $apiNegPath = ".\api_negative_tests.json"
  $newmanSummaryPath = ".\newman_summary.json"
  $p0SummaryPath = ".\p0_gate_results.json"

  try {
    # Step 1: Preflight
    if ($preflightScriptExists) {
      $preflightParams = @{
        BaseUrl = $BaseUrl
        ApiHealthPath = $ApiHealthPath
        TimeoutSec = $TimeoutSec
      }
      if ($null -ne $psqlPath) {
        $preflightParams["PsqlExe"] = $PsqlExe
        if ($PsqlArgs.Count -gt 0) {
          $preflightParams["PsqlArgs"] = $PsqlArgs
        }
      }
      else {
        $preflightParams["SkipPsqlCheck"] = $true
      }
      if ($null -ne $newmanPath) {
        $preflightParams["NewmanExe"] = $NewmanExe
      }
      else {
        $preflightParams["SkipNewmanCheck"] = $true
      }

      $preflightRan = $true
      $preflightStep = Invoke-LoggedStep -Name "preflight" -LogPath $preflightLog -Script {
        & .\preflight_env.ps1 @preflightParams
      }
      $preflightExit = $preflightStep.exit_code
      $preflightExitCode = $preflightExit
      if ($preflightExit -eq 0) {
        $preflightVerdict = "PREFLIGHT_READY"
      }
      else {
        $preflightVerdict = "PREFLIGHT_BLOCKED"
        $preflightBlocked = $true
      }
    }
    else {
      $preflightBlocked = $true
      $preflightVerdict = "MISSING_SCRIPT"
      "preflight_env.ps1 missing" | Set-Content -Path $preflightLog -Encoding UTF8
      [void]$script:RunStepResults.Add([pscustomobject]@{
        name = "preflight"
        exit_code = -1
        duration_ms = 0
        log = $preflightLog
        success = $false
        error = "preflight_env.ps1 missing"
      })
    }

    # Step 2: Telemetry before
    $telemetryBefore = Save-TelemetrySnapshot -Base $BaseUrl -Uid $UserId -OutFile ".\telemetry_before.json" -ApiToken $ApiKey -RequestTimeoutSec $TimeoutSec
    if ($null -ne $telemetryBefore -and $telemetryBefore.is_error_envelope) {
      Add-FallbackArtifact -Artifact "telemetry_before.json" -Reason "Captured transport error envelope: $($telemetryBefore.error)" -Type "transport_envelope"
    }

    # Step 3: DB checks
    if (($null -ne $psqlPath) -and $dbChecksExists) {
      $dbStep = Invoke-LoggedStep -Name "db_checks" -LogPath $dbLog -Script {
        & $PsqlExe @PsqlArgs -v ON_ERROR_STOP=1 -f .\p0_db_checks.sql
      }
      $dbExit = $dbStep.exit_code
    }
    else {
      $dbExit = -1
      $reason = if ($null -eq $psqlPath) { "psql missing" } else { "p0_db_checks.sql missing" }
      @(
        "# DB checks not executed by run wrapper"
        "# Reason: $reason"
        "P0_DB_CHECKS_FAILED"
      ) | Set-Content -Path $dbLog -Encoding UTF8
      [void]$script:RunStepResults.Add([pscustomobject]@{
        name = "db_checks"
        exit_code = -1
        duration_ms = 0
        log = $dbLog
        success = $false
        error = $reason
      })
    }
    Copy-Item -Force -Path $dbLog -Destination $dbOutputPath
    if ($dbExit -ne 0) {
      Add-FallbackArtifact `
        -Artifact "db_verification_results.sql.out" `
        -Reason "DB step failed (exit $dbExit); output derived from failure log." `
        -Type "derived_failure_output"
    }

    # Step 4: P0 gate
    if ($p0ScriptExists) {
      $p0Params = @{
        BaseUrl = $BaseUrl
        UserId = $UserId
        PsqlExe = $PsqlExe
        PsqlArgs = $PsqlArgs
        NewmanExe = $NewmanExe
        NewmanArgs = $NewmanArgs
      }
      if (-not [string]::IsNullOrWhiteSpace($ApiKey)) {
        $p0Params["ApiKey"] = $ApiKey
      }
      if (-not [string]::IsNullOrWhiteSpace($PostmanCollection)) {
        $p0Params["PostmanCollection"] = $PostmanCollection
      }

      $gateStep = Invoke-LoggedStep -Name "p0_gate" -LogPath $gateLog -Script {
        & .\p0_ci_gate.ps1 @p0Params
      }
      $gateExit = $gateStep.exit_code
    }
    else {
      $gateExit = -1
      "p0_ci_gate.ps1 missing" | Set-Content -Path $gateLog -Encoding UTF8
      [void]$script:RunStepResults.Add([pscustomobject]@{
        name = "p0_gate"
        exit_code = -1
        duration_ms = 0
        log = $gateLog
        success = $false
        error = "p0_ci_gate.ps1 missing"
      })
    }
  }
  finally {
    # Always-on artifact finalization for deterministic evidence bundles.
    $telemetryAfter = Save-TelemetrySnapshot -Base $BaseUrl -Uid $UserId -OutFile ".\telemetry_after.json" -ApiToken $ApiKey -RequestTimeoutSec $TimeoutSec
    if ($null -ne $telemetryAfter -and $telemetryAfter.is_error_envelope) {
      Add-FallbackArtifact -Artifact "telemetry_after.json" -Reason "Captured transport error envelope: $($telemetryAfter.error)" -Type "transport_envelope"
    }

    if (Ensure-DbVerificationFallback -OutPath $dbOutputPath -Reason "DB checks did not produce output.") {
      Add-FallbackArtifact -Artifact "db_verification_results.sql.out" -Reason "Generated fallback DB verification artifact." -Type "synthetic_missing_artifact"
    }
    if (Ensure-ApiNegativeTestsSkeleton -Path $apiNegPath) {
      Add-FallbackArtifact -Artifact "api_negative_tests.json" -Reason "Generated fallback API negative tests artifact." -Type "synthetic_missing_artifact"
    }

    if (-not (Test-FileExists -Path ".\newman_summary.json") -and -not (Test-FileExists -Path ".\newman_results.xml")) {
      $newmanReason = if ($null -eq $newmanPath) { "newman executable not found" } else { "newman artifact missing after gate run" }
      if (Ensure-NewmanSummarySkeleton -Path $newmanSummaryPath -Reason $newmanReason) {
        Add-FallbackArtifact -Artifact "newman_summary.json" -Reason "Generated fallback Newman summary artifact: $newmanReason" -Type "synthetic_missing_artifact"
      }
    }

    if (Ensure-P0SummarySkeleton `
      -Path $p0SummaryPath `
      -Base $BaseUrl `
      -Uid $UserId `
      -PreflightEnabled $preflightEnabled `
      -PreflightRan $preflightRan `
      -PreflightBlocked $preflightBlocked `
      -PreflightVerdict $preflightVerdict `
      -PreflightExitCode $preflightExitCode `
      -Reason "Generated fallback artifact: p0 gate summary missing."
    ) {
      Add-FallbackArtifact -Artifact "p0_gate_results.json" -Reason "Generated fallback P0 gate summary artifact." -Type "synthetic_missing_artifact"
    }

    $checksumNewmanArtifact = if (Test-FileExists -Path ".\newman_summary.json") { "newman_summary.json" } elseif (Test-FileExists -Path ".\newman_results.xml") { "newman_results.xml" } else { "" }
    Write-ChecksumsForExisting -Dir $resolvedEvidenceDir -NewmanArtifactName $checksumNewmanArtifact
  }

  # Step 5: Strict verifier
  if ($verifyScriptExists) {
    $strictStep = Invoke-LoggedStep -Name "verify_strict" -LogPath $verifyStrictLog -Script {
      & .\verify_evidence.ps1 -EvidenceDir "."
    }
    $strictVerifyExit = $strictStep.exit_code
    if (Test-FileExists -Path ".\verify_evidence_report.json") {
      Copy-Item -Force -Path ".\verify_evidence_report.json" -Destination ".\verify_evidence_report.strict.json"
    }
  }
  else {
    $strictVerifyExit = -1
    "verify_evidence.ps1 missing" | Set-Content -Path $verifyStrictLog -Encoding UTF8
    [void]$script:RunStepResults.Add([pscustomobject]@{
      name = "verify_strict"
      exit_code = -1
      duration_ms = 0
      log = $verifyStrictLog
      success = $false
      error = "verify_evidence.ps1 missing"
    })
  }

  # Step 6: Non-strict verifier (diagnostic mode)
  if ($AllowPreflightBlocked -and $verifyScriptExists) {
    $nonStrictStep = Invoke-LoggedStep -Name "verify_non_strict" -LogPath $verifyNonStrictLog -Script {
      & .\verify_evidence.ps1 -EvidenceDir "." -AllowPreflightBlocked
    }
    $nonStrictVerifyExit = $nonStrictStep.exit_code
    if (Test-FileExists -Path ".\verify_evidence_report.json") {
      Copy-Item -Force -Path ".\verify_evidence_report.json" -Destination ".\verify_evidence_report.non_strict.json"
    }
  }

  $releaseGateReasons = @()
  if ($strictVerifyExit -ne 0) { $releaseGateReasons += "STRICT_VERIFY_FAILED" }
  if ($script:RunBlockers.Count -gt 0) { $releaseGateReasons += "WRAPPER_BLOCKERS_PRESENT" }
  if ($script:FallbackArtifacts.Count -gt 0) { $releaseGateReasons += "FALLBACK_ARTIFACTS_PRESENT" }
  $releaseGateReasons = @($releaseGateReasons | Select-Object -Unique)
  if (Get-Command Get-OrderedUniqueReleaseGateReasons -ErrorAction SilentlyContinue) {
    $releaseGateReasons = @(Get-OrderedUniqueReleaseGateReasons -Reasons $releaseGateReasons)
  }
  else {
    $reasonOrder = @(
      "STRICT_VERIFY_FAILED",
      "WRAPPER_BLOCKERS_PRESENT",
      "FALLBACK_ARTIFACTS_PRESENT"
    )
    $releaseGateReasons = @(
      $reasonOrder | Where-Object { $releaseGateReasons -contains $_ }
    )
  }
  $strictReleaseGateReady = (($strictVerifyExit -eq 0) -and ($script:RunBlockers.Count -eq 0) -and ($script:FallbackArtifacts.Count -eq 0))

  $summary = [pscustomobject]@{
    generated_at_utc = (Get-Date).ToUniversalTime().ToString("o")
    summary_schema_version = $summarySchemaVersion
    base_url = $BaseUrl
    user_id = $UserId
    evidence_dir = $resolvedEvidenceDir
    allow_preflight_blocked = $AllowPreflightBlocked.IsPresent
    exits = [pscustomobject]@{
      preflight = $preflightExit
      db_checks = $dbExit
      p0_gate = $gateExit
      verify_strict = $strictVerifyExit
      verify_non_strict = $nonStrictVerifyExit
    }
    logs = [pscustomobject]@{
      preflight = $preflightLog
      db_checks = $dbLog
      p0_gate = $gateLog
      verify_strict = $verifyStrictLog
      verify_non_strict = if ($AllowPreflightBlocked) { $verifyNonStrictLog } else { $null }
    }
    run_blockers = @($script:RunBlockers.ToArray())
    run_warnings = @($script:RunWarnings.ToArray())
    used_fallback_artifacts = ($script:FallbackArtifacts.Count -gt 0)
    fallback_artifacts = @($script:FallbackArtifacts.ToArray())
    release_gate_reason = $releaseGateReasons
    strict_release_gate_ready = $strictReleaseGateReady
    release_decision = if ($strictReleaseGateReady) { "PASS" } else { "FAIL" }
    steps = @($script:RunStepResults.ToArray())
    strict_exit = $strictVerifyExit
    non_strict_exit = if ($AllowPreflightBlocked) { $nonStrictVerifyExit } else { $null }
  }
  $summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 -Path ".\run_staging_summary.json"

  $table = @(
    [pscustomobject]@{ Step = "preflight"; ExitCode = $preflightExit; Log = (Split-Path -Leaf $preflightLog) },
    [pscustomobject]@{ Step = "db_checks"; ExitCode = $dbExit; Log = (Split-Path -Leaf $dbLog) },
    [pscustomobject]@{ Step = "p0_gate"; ExitCode = $gateExit; Log = (Split-Path -Leaf $gateLog) },
    [pscustomobject]@{ Step = "verify_strict"; ExitCode = $strictVerifyExit; Log = (Split-Path -Leaf $verifyStrictLog) },
    [pscustomobject]@{ Step = "verify_non_strict"; ExitCode = if ($AllowPreflightBlocked) { $nonStrictVerifyExit } else { "SKIPPED" }; Log = if ($AllowPreflightBlocked) { (Split-Path -Leaf $verifyNonStrictLog) } else { "-" } }
  )

  Write-Host ""
  Write-Host "Run Summary:"
  $table | Format-Table -AutoSize | Out-String | Write-Host
  Write-Host "STRICT_EXIT=$strictVerifyExit"
  if ($AllowPreflightBlocked) {
    Write-Host "NON_STRICT_EXIT=$nonStrictVerifyExit"
  }
  else {
    Write-Host "NON_STRICT_EXIT=SKIPPED"
  }
  Write-Host "RELEASE_DECISION=$($summary.release_decision)"

  if ($script:RunWarnings.Count -gt 0) {
    Write-Host "Warnings:"
    foreach ($w in $script:RunWarnings) { Write-Host " - $w" }
  }
  if ($script:FallbackArtifacts.Count -gt 0) {
    Write-Host "Fallback Artifacts:"
    foreach ($f in $script:FallbackArtifacts) { Write-Host " - $($f.artifact): $($f.reason)" }
  }
  if ($script:RunBlockers.Count -gt 0) {
    Write-Host "Wrapper Blockers:"
    foreach ($b in $script:RunBlockers) { Write-Host " - $b" }
  }

  # Release gate exit follows strict verify. Keep non-zero if wrapper prechecks were blocked.
  if ($strictVerifyExit -eq 0 -and $script:FallbackArtifacts.Count -gt 0) {
    Write-Host "STRICT run produced fallback artifacts; failing release gate."
    exit 1
  }
  if ($strictVerifyExit -ne 0) { exit 1 }
  if ($script:RunBlockers.Count -gt 0) { exit 1 }
  exit 0
}
finally {
  Pop-Location
}
