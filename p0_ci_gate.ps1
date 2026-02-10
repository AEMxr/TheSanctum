param(
  [Parameter(Mandatory = $true)][string]$BaseUrl,
  [Parameter(Mandatory = $true)][string]$UserId,
  [string]$ApiKey = '',
  [string]$PsqlExe = '',
  [string[]]$PsqlArgs = @(),
  [string]$NewmanExe = '',
  [string[]]$NewmanArgs = @(),
  [string]$PostmanCollection = '',
  [string]$ResultsJsonPath = 'p0_gate_results.json',
  [switch]$SkipDbChecks,
  [switch]$SkipApiTests,
  [switch]$SkipTelemetryGate
)

$ErrorActionPreference = 'Stop'

function Get-EnvOrDefault {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][string]$DefaultValue
  )
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
  return $value
}

function Get-EnvBoolOrDefault {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][bool]$DefaultValue
  )
  $value = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
  switch ($value.Trim().ToLowerInvariant()) {
    '1' { return $true }
    'true' { return $true }
    'yes' { return $true }
    'on' { return $true }
    '0' { return $false }
    'false' { return $false }
    'no' { return $false }
    'off' { return $false }
    default { return $DefaultValue }
  }
}

function Get-EnvIntOrDefault {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][int]$DefaultValue
  )
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  $v = 0
  if ([int]::TryParse($raw.Trim(), [ref]$v)) { return $v }
  Write-Warning "Invalid int for env '$Name' ('$raw'); using default $DefaultValue"
  return $DefaultValue
}

function Get-EnvDoubleOrDefault {
  param(
    [Parameter(Mandatory = $true)][string]$Name,
    [Parameter(Mandatory = $true)][double]$DefaultValue
  )
  $raw = [Environment]::GetEnvironmentVariable($Name)
  if ([string]::IsNullOrWhiteSpace($raw)) { return $DefaultValue }
  $v = 0.0
  if ([double]::TryParse($raw.Trim(), [System.Globalization.NumberStyles]::Float, [System.Globalization.CultureInfo]::InvariantCulture, [ref]$v)) {
    return $v
  }
  Write-Warning "Invalid double for env '$Name' ('$raw'); using default $DefaultValue"
  return $DefaultValue
}

# Environment-driven thresholds
$MinBoundaryRespectRate = Get-EnvDoubleOrDefault -Name 'min_boundary_respect_rate' -DefaultValue 0.98
$MaxPolicyFailureRate = Get-EnvDoubleOrDefault -Name 'max_policy_failure_rate' -DefaultValue 0.02
$MaxEntropy7d = Get-EnvDoubleOrDefault -Name 'max_entropy_7d' -DefaultValue 1.2
$MaxOverrideRateByDomain = Get-EnvDoubleOrDefault -Name 'max_override_rate_by_domain' -DefaultValue 0.30
$MinOnboardingCompletionRate = Get-EnvDoubleOrDefault -Name 'min_onboarding_completion_rate' -DefaultValue 0.50
$MaxTelemetryResponseMs = Get-EnvIntOrDefault -Name 'max_telemetry_response_ms' -DefaultValue 1200
$RequestTimeoutSec = Get-EnvIntOrDefault -Name 'request_timeout_sec' -DefaultValue 30
$TelemetryRetryCount = Get-EnvIntOrDefault -Name 'telemetry_retry_count' -DefaultValue 3
$TelemetryRetryDelayMs = Get-EnvIntOrDefault -Name 'telemetry_retry_delay_ms' -DefaultValue 500
$EnforceNonceMisuseHardGate = Get-EnvBoolOrDefault -Name 'enforce_nonce_misuse_hard_gate' -DefaultValue $true
$ExpectedNonceReplayFromP0 = Get-EnvIntOrDefault -Name 'expected_nonce_replay_from_p0' -DefaultValue 1
$ExpectedNonceBindingMismatchFromP0 = Get-EnvIntOrDefault -Name 'expected_nonce_binding_mismatch_from_p0' -DefaultValue 1
$RunPreflight = Get-EnvBoolOrDefault -Name 'run_preflight' -DefaultValue $true
$FailOnPreflightBlocked = Get-EnvBoolOrDefault -Name 'fail_on_preflight_blocked' -DefaultValue $true

$script:HardFailures = New-Object System.Collections.Generic.List[string]
$script:Warnings = New-Object System.Collections.Generic.List[string]
$script:TestResults = New-Object System.Collections.Generic.List[object]

function New-IdempotencyKey {
  return [guid]::NewGuid().ToString()
}

function Add-HardFailure {
  param([string]$Message)
  $script:HardFailures.Add($Message)
}

function Add-Warning {
  param([string]$Message)
  $script:Warnings.Add($Message)
}

function Get-ErrorBodyFromException {
  param([System.Exception]$Exception)

  $bodyText = ''
  $stream = $null
  $reader = $null

  try {
    if ($null -ne $Exception.Response) {
      $stream = $Exception.Response.GetResponseStream()
      if ($null -ne $stream) {
        $reader = New-Object System.IO.StreamReader($stream)
        $bodyText = $reader.ReadToEnd()
      }
    }
  }
  catch {
    # ignore and continue to fallbacks
  }
  finally {
    try { if ($null -ne $reader) { $reader.Dispose() } } catch { }
    try { if ($null -ne $stream) { $stream.Dispose() } } catch { }
  }

  if ([string]::IsNullOrWhiteSpace($bodyText)) {
    try {
      if ($null -ne $Exception.ErrorDetails -and -not [string]::IsNullOrWhiteSpace($Exception.ErrorDetails.Message)) {
        $bodyText = $Exception.ErrorDetails.Message
      }
    }
    catch {
      # ignore
    }
  }

  if ([string]::IsNullOrWhiteSpace($bodyText)) {
    $msg = [string]$Exception.Message
    if ($msg -match '\{.*"error".*"code".*\}') {
      $bodyText = $matches[0]
    }
  }

  return $bodyText
}

function Get-ErrorCodeFromException {
  param([System.Exception]$Exception)

  $bodyText = Get-ErrorBodyFromException -Exception $Exception
  if ([string]::IsNullOrWhiteSpace($bodyText)) { return '' }

  try {
    $body = $bodyText | ConvertFrom-Json
    return $body.error.code
  }
  catch {
    return ''
  }
}

function Get-StatusCodeFromException {
  param([System.Exception]$Exception)
  if ($null -eq $Exception.Response) { return -1 }
  try {
    return [int]$Exception.Response.StatusCode
  }
  catch {
    return -1
  }
}

function Should-RetryApiException {
  param([System.Exception]$Exception)
  $statusCode = Get-StatusCodeFromException -Exception $Exception
  if ($statusCode -eq -1) { return $true } # transport/timeouts/connection errors
  if ($statusCode -in 408, 425, 429) { return $true }
  if ($statusCode -ge 500 -and $statusCode -lt 600) { return $true }
  return $false
}

function Invoke-JsonApi {
  param(
    [string]$Method,
    [string]$Path,
    [object]$Body = $null,
    [hashtable]$ExtraHeaders = @{},
    [string]$IdempotencyKey = '',
    [int]$TimeoutSec = $RequestTimeoutSec
  )

  $normalizedMethod = $Method.ToUpperInvariant()
  $headers = @{}
  $idempotentMethods = @('POST', 'PUT', 'PATCH', 'DELETE')

  if (-not [string]::IsNullOrWhiteSpace($IdempotencyKey)) {
    $headers['Idempotency-Key'] = $IdempotencyKey
  }
  elseif ($idempotentMethods -contains $normalizedMethod) {
    $headers['Idempotency-Key'] = (New-IdempotencyKey)
  }

  if ($null -ne $Body) {
    $headers['Content-Type'] = 'application/json'
  }

  if ($ApiKey -ne '') { $headers['Authorization'] = "Bearer $ApiKey" }
  foreach ($k in $ExtraHeaders.Keys) { $headers[$k] = $ExtraHeaders[$k] }

  $uri = "$BaseUrl$Path"
  if ($null -ne $Body) {
    return Invoke-RestMethod -Method $normalizedMethod -Uri $uri -Headers $headers -Body ($Body | ConvertTo-Json -Depth 30) -TimeoutSec $TimeoutSec
  }
  return Invoke-RestMethod -Method $normalizedMethod -Uri $uri -Headers $headers -TimeoutSec $TimeoutSec
}

function Invoke-JsonApiWithRetry {
  param(
    [string]$Method,
    [string]$Path,
    [object]$Body = $null,
    [hashtable]$ExtraHeaders = @{},
    [int]$MaxAttempts = $TelemetryRetryCount,
    [int]$DelayMs = $TelemetryRetryDelayMs,
    [int]$TimeoutSec = $RequestTimeoutSec
  )

  $attempt = 1
  while ($attempt -le [Math]::Max(1, $MaxAttempts)) {
    try {
      return Invoke-JsonApi -Method $Method -Path $Path -Body $Body -ExtraHeaders $ExtraHeaders -TimeoutSec $TimeoutSec
    }
    catch {
      if ($attempt -ge [Math]::Max(1, $MaxAttempts) -or -not (Should-RetryApiException -Exception $_.Exception)) {
        throw
      }
      Start-Sleep -Milliseconds ([Math]::Max(1, $DelayMs))
      $attempt++
    }
  }
}

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw "ASSERT_FAIL: $Message" }
}

function To-IntOr {
  param($Value, [int]$Default = 0)
  try { return [int]$Value } catch { return $Default }
}

function To-DoubleOr {
  param($Value, [double]$Default = 0.0)
  try { return [double]$Value } catch { return $Default }
}

function Assert-NonEmptyString {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value.Trim())) {
    throw "ASSERT_FAIL: $Message"
  }
}

function Assert-MapLike {
  param(
    [Parameter(Mandatory = $true)]$Value,
    [Parameter(Mandatory = $true)][string]$Message
  )
  if ($null -eq $Value) {
    throw "ASSERT_FAIL: $Message (value is null)"
  }
  if (-not ($Value -is [System.Collections.IDictionary]) -and -not ($Value -is [pscustomobject])) {
    throw "ASSERT_FAIL: $Message (value type '$($Value.GetType().FullName)' is not map-like)"
  }
}

function Get-NonNegativeIntField {
  param(
    [Parameter(Mandatory = $true)]$Object,
    [Parameter(Mandatory = $true)][string]$FieldName,
    [int]$Default = 0
  )
  if ($null -eq $Object -or -not ($Object.PSObject.Properties.Name -contains $FieldName)) {
    return $Default
  }

  $raw = $Object.$FieldName
  if ($null -eq $raw) {
    throw "Telemetry field '$FieldName' is null; expected non-negative integer"
  }

  $parsed = 0
  if (-not [int]::TryParse([string]$raw, [ref]$parsed)) {
    throw "Telemetry field '$FieldName' value '$raw' is not an integer"
  }
  if ($parsed -lt 0) {
    throw "Telemetry field '$FieldName' value '$parsed' is negative; expected >= 0"
  }

  return $parsed
}

function Expect-ApiErrorCode {
  param(
    [scriptblock]$Call,
    [string[]]$ExpectedCodes,
    [int]$ExpectedStatusCode = -1
  )

  try {
    & $Call | Out-Null
    throw 'Expected API error but request succeeded'
  }
  catch {
    $code = Get-ErrorCodeFromException -Exception $_.Exception
    $statusCode = Get-StatusCodeFromException -Exception $_.Exception
    $errorBody = Get-ErrorBodyFromException -Exception $_.Exception
    if ($ExpectedStatusCode -ge 0 -and $statusCode -ne $ExpectedStatusCode) {
      throw "Unexpected HTTP status '$statusCode'. Expected: $ExpectedStatusCode. Body: $errorBody"
    }
    if ($ExpectedCodes -contains $code) { return }
    throw "Unexpected error code '$code'. Expected: $($ExpectedCodes -join ', '). Body: $errorBody"
  }
}

function Run-Test {
  param([string]$Name, [scriptblock]$Script)
  $sw = [System.Diagnostics.Stopwatch]::StartNew()
  try {
    & $Script
    $sw.Stop()
    $script:TestResults.Add([pscustomobject]@{ Name = $Name; Status = 'PASS'; DurationMs = [int]$sw.ElapsedMilliseconds; Error = '' })
    Write-Host "PASS $Name"
  }
  catch {
    $sw.Stop()
    $script:TestResults.Add([pscustomobject]@{ Name = $Name; Status = 'FAIL'; DurationMs = [int]$sw.ElapsedMilliseconds; Error = $_.Exception.Message })
    Write-Host "FAIL $Name :: $($_.Exception.Message)"
  }
}

function Run-DbChecks {
  if ($SkipDbChecks) { return }
  if (-not [string]::IsNullOrWhiteSpace($PsqlExe)) {
    $scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
    $dbChecksPath = Join-Path $scriptDir 'p0_db_checks.sql'
    if (-not (Test-Path -Path $dbChecksPath -PathType Leaf)) {
      Add-HardFailure "p0_db_checks.sql not found at '$dbChecksPath'"
      return
    }
    & $PsqlExe @PsqlArgs -f $dbChecksPath
    if ($LASTEXITCODE -ne 0) {
      Add-HardFailure "p0_db_checks.sql execution failed (exit code $LASTEXITCODE)"
    }
    return
  }

  Add-HardFailure 'PsqlExe/PsqlArgs is required unless -SkipDbChecks is set'
}

function Run-NewmanGate {
  if ([string]::IsNullOrWhiteSpace($PostmanCollection)) { return }

  if (-not [string]::IsNullOrWhiteSpace($NewmanExe)) {
    & $NewmanExe @NewmanArgs run $PostmanCollection --env-var "baseUrl=$BaseUrl" --env-var "userId=$UserId"
    if ($LASTEXITCODE -ne 0) {
      Add-HardFailure "Newman gate failed (exit code $LASTEXITCODE)"
    }
    return
  }
  Add-HardFailure 'NewmanExe is required when PostmanCollection is provided'
}

$preflightEnabled = $RunPreflight
$preflightRan = $false
$preflightBlocked = $false
$preflightReportPath = 'preflight_report.json'
$preflightExitCode = -1
$preflightVerdict = if ($preflightEnabled) { 'NOT_RUN' } else { 'SKIPPED' }

if ($RunPreflight) {
  $scriptDir = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
  $preflightPath = Join-Path $scriptDir 'preflight_env.ps1'

  if (-not (Test-Path -Path $preflightPath -PathType Leaf)) {
    $preflightVerdict = 'MISSING_SCRIPT'
    Add-HardFailure "preflight_env.ps1 not found at '$preflightPath'"
    if ($FailOnPreflightBlocked) {
      $preflightBlocked = $true
      Add-Warning 'Preflight script missing; gate execution skipped and summary artifact will still be written.'
    }
  }
  else {
    $preflightParams = @{
      BaseUrl = $BaseUrl
      ApiHealthPath = '/health'
      TimeoutSec = $RequestTimeoutSec
    }

    if ($SkipDbChecks) {
      $preflightParams['SkipPsqlCheck'] = $true
    }
    else {
      if (-not [string]::IsNullOrWhiteSpace($PsqlExe)) {
        $preflightParams['PsqlExe'] = $PsqlExe
      }
      if ($null -ne $PsqlArgs -and $PsqlArgs.Count -gt 0) {
        $preflightParams['PsqlArgs'] = $PsqlArgs
      }
    }

    if ([string]::IsNullOrWhiteSpace($PostmanCollection)) {
      $preflightParams['SkipNewmanCheck'] = $true
    }
    else {
      if (-not [string]::IsNullOrWhiteSpace($NewmanExe)) {
        $preflightParams['NewmanExe'] = $NewmanExe
      }
    }

    if ($SkipApiTests -and $SkipTelemetryGate) {
      $preflightParams['SkipApiCheck'] = $true
    }

    $preflightRan = $true
    & $preflightPath @preflightParams
    $preflightExit = $LASTEXITCODE
    $preflightExitCode = $preflightExit
    $preflightVerdict = if ($preflightExit -eq 0) { 'PREFLIGHT_READY' } else { 'PREFLIGHT_BLOCKED' }

    if ($preflightExit -ne 0) {
      Add-HardFailure 'Preflight blocked (see preflight_report.json)'
      if ($FailOnPreflightBlocked) {
        $preflightBlocked = $true
        Add-Warning 'Preflight failed; gate execution skipped and summary artifact will still be written.'
      }
    }
  }
}

if ($preflightBlocked) {
  Add-Warning 'Skipping API/DB/Newman/telemetry suites due to preflight block.'
}

if (-not $preflightBlocked) {
  $sessionId = [guid]::NewGuid().ToString()
  $primarchNodeId = ''
  $recordId = ''
  $recommendationId = ''
  $nonce = ''
  $actionHash = 'sha256:p0-base-action'
  $baselineReplayCount = 0
  $baselineBindingMismatchCount = 0

  if (-not $SkipTelemetryGate) {
    try {
      $baseline = Invoke-JsonApiWithRetry -Method GET -Path "/telemetry/dashboard?user_stable_id=$UserId"
      $misuse = $baseline.nonce_misuse_events_7d
      Assert-MapLike -Value $misuse -Message 'baseline nonce_misuse_events_7d must be an object'
      $baselineReplayCount = Get-NonNegativeIntField -Object $misuse -FieldName 'NONCE_REPLAY' -Default 0
      $baselineBindingMismatchCount = Get-NonNegativeIntField -Object $misuse -FieldName 'NONCE_BINDING_MISMATCH' -Default 0
      Assert-True ($baselineReplayCount -ge 0) 'baseline NONCE_REPLAY must be non-negative integer'
      Assert-True ($baselineBindingMismatchCount -ge 0) 'baseline NONCE_BINDING_MISMATCH must be non-negative integer'
    }
    catch {
      Add-HardFailure "Unable to read/validate baseline telemetry snapshot before tests: $($_.Exception.Message)"
    }
  }

  if (-not $SkipApiTests) {
  Run-Test 'P0-01 Onboarding happy path + advisory evaluate' {
    $step1 = Invoke-JsonApi -Method POST -Path '/onboarding/step/1/create-profile' -Body @{
      user_stable_id = $UserId
      declared_values = @('family-first', 'truth-seeking')
      preferences = @{ tone = 'direct'; communication_style = 'concise'; goals_horizon = 'long' }
      current_jurisdiction = 'US-OR'
      is_owner = $true
    }
    Assert-True ($step1.step -eq 1) 'step1 failed'

    $step2 = Invoke-JsonApi -Method POST -Path '/onboarding/step/2/add-boundaries' -Body @{
      user_stable_id = $UserId
      is_owner = $true
      boundaries = @(
        @{ text = 'never recommend high-leverage trading' },
        @{ text = 'no medical diagnosis' }
      )
    }
    Assert-True ($step2.step -eq 2) 'step2 failed'

    $step3 = Invoke-JsonApi -Method POST -Path '/onboarding/step/3/create-policy' -Body @{
      user_stable_id = $UserId
      is_owner = $true
      non_negotiables = @('truth over comfort')
      escalation_rules = @(@{ domain = 'finance'; condition = 'amount > 10000'; action = 'primarch_approval' })
      consent_requirements = @(@{ domain = 'finance'; read_level = 'implicit'; write_level = 'explicit'; share_level = 'never'; act_level = 'explicit' })
    }
    Assert-True ($step3.step -eq 3) 'step3 failed'

    $step4 = Invoke-JsonApi -Method POST -Path '/onboarding/step/4/create-primarch-node' -Body @{
      user_stable_id = $UserId
      is_owner = $true
      name_or_alias = 'Primarch (Self)'
      relationship_type = 'chosen'
      verification_level = 'primarch_verified'
      consent_scope = @{ read = @('*'); write = @('*'); share = @('*'); act = @('*') }
    }
    Assert-True ($step4.step -eq 4) 'step4 failed'
    $script:primarchNodeId = $step4.node_id

    $confirm = Invoke-JsonApi -Method POST -Path '/onboarding/confirm' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      notes = 'P0 run'
    }
    Assert-True ($confirm.status -eq 'confirmed') 'onboarding confirm failed'

    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Should I put 500 into a high-yield savings account?'
      domain = 'finance'
      actionability_level = 'advisory'
      session_id = $sessionId
    }
    Assert-True ($null -ne $eval.record_id) 'evaluate did not return record_id'
    Assert-NonEmptyString -Value $eval.recommendation_id -Message 'evaluate response missing/invalid recommendation_id'
  }

  Run-Test 'P0-02 Material action eval -> nonce create -> confirm' {
    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Move 15000 from savings to index funds'
      domain = 'finance'
      actionability_level = 'material_action'
      session_id = $sessionId
    }
    $script:recordId = $eval.record_id
    Assert-NonEmptyString -Value $eval.recommendation_id -Message 'evaluate response missing/invalid recommendation_id'
    $script:recommendationId = [string]$eval.recommendation_id

    $nonceResp = Invoke-JsonApi -Method POST -Path '/consent/nonce/create' -Body @{
      user_stable_id = $UserId
      session_id = $sessionId
      record_id = $script:recordId
      action_hash = $actionHash
      ttl_seconds = 600
    }
    Assert-True ($null -ne $nonceResp.nonce) 'nonce not returned'
    $script:nonce = $nonceResp.nonce

    $confirm = Invoke-JsonApi -Method POST -Path '/decisions/confirm-material-action' -Body @{
      record_id = $script:recordId
      nonce = $script:nonce
      session_id = $sessionId
      recommendation_id = $script:recommendationId
      action_hash = $actionHash
    }
    Assert-True ($confirm.status -eq 'confirmed') 'material action confirm failed'
  }

  Run-Test 'P0-03 Nonce replay rejected' {
    Expect-ApiErrorCode -Call {
      Invoke-JsonApi -Method POST -Path '/decisions/confirm-material-action' -Body @{
        record_id = $script:recordId
        nonce = $script:nonce
        session_id = $sessionId
        recommendation_id = $script:recommendationId
        action_hash = $actionHash
      }
    } -ExpectedCodes @('NONCE_REPLAY')
  }

  Run-Test 'P0-04 Nonce binding mismatch rejected' {
    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Move 12000 into treasury bills'
      domain = 'finance'
      actionability_level = 'material_action'
      session_id = $sessionId
    }
    $rid = $eval.record_id
    Assert-NonEmptyString -Value $eval.recommendation_id -Message 'evaluate response missing/invalid recommendation_id'
    $rec = [string]$eval.recommendation_id
    $nonceResp = Invoke-JsonApi -Method POST -Path '/consent/nonce/create' -Body @{
      user_stable_id = $UserId
      session_id = $sessionId
      record_id = $rid
      action_hash = 'sha256:good'
      ttl_seconds = 60
    }

    Expect-ApiErrorCode -Call {
      Invoke-JsonApi -Method POST -Path '/decisions/confirm-material-action' -Body @{
        record_id = $rid
        nonce = $nonceResp.nonce
        session_id = $sessionId
        recommendation_id = $rec
        action_hash = 'sha256:tampered'
      }
    } -ExpectedCodes @('NONCE_BINDING_MISMATCH')
  }

  Run-Test 'P0-05 Nonce expiry rejected' {
    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Move 11000 to money market'
      domain = 'finance'
      actionability_level = 'material_action'
      session_id = $sessionId
    }
    $rid = $eval.record_id
    Assert-NonEmptyString -Value $eval.recommendation_id -Message 'evaluate response missing/invalid recommendation_id'
    $rec = [string]$eval.recommendation_id
    $nonceResp = Invoke-JsonApi -Method POST -Path '/consent/nonce/create' -Body @{
      user_stable_id = $UserId
      session_id = $sessionId
      record_id = $rid
      action_hash = 'sha256:exp'
      ttl_seconds = 1
    }
    Start-Sleep -Seconds 2
    Expect-ApiErrorCode -Call {
      Invoke-JsonApi -Method POST -Path '/decisions/confirm-material-action' -Body @{
        record_id = $rid
        nonce = $nonceResp.nonce
        session_id = $sessionId
        recommendation_id = $rec
        action_hash = 'sha256:exp'
      }
    } -ExpectedCodes @('CONSENT_EXPIRED')
  }

  Run-Test 'P0-06 Onboarding step-order bypass rejected' {
    $u2 = [guid]::NewGuid().ToString()
    Invoke-JsonApi -Method POST -Path '/onboarding/step/1/create-profile' -Body @{
      user_stable_id = $u2
      declared_values = @('test')
      preferences = @{ tone = 'direct' }
      current_jurisdiction = 'US-OR'
      is_owner = $true
    } | Out-Null

    Expect-ApiErrorCode -Call {
      Invoke-JsonApi -Method POST -Path '/onboarding/step/3/create-policy' -Body @{
        user_stable_id = $u2
        is_owner = $true
        non_negotiables = @('x')
        escalation_rules = @()
        consent_requirements = @()
      }
    } -ExpectedCodes @('STEP_OUT_OF_ORDER', 'ONBOARDING_NOT_READY_OR_UNAUTHORIZED')
  }

  Run-Test 'P0-07 Arbiter veto enforced' {
    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Recommend a high-leverage margin trade strategy'
      domain = 'finance'
      actionability_level = 'advisory'
      session_id = $sessionId
    }
    Assert-True ($eval.final_output.final_position -eq 'BLOCK') 'final_position should be BLOCK'
    Assert-True (($eval.final_output.final_risks -contains 'values_boundary_violation')) 'final_risks should include values_boundary_violation'
    Assert-True ($eval.final_output.requires_approval -eq $true) 'requires_approval should be true on BLOCK'
  }

  Run-Test 'P0-08 Primarch uniqueness enforced' {
    $u3 = [guid]::NewGuid().ToString()
    Invoke-JsonApi -Method POST -Path '/onboarding/step/1/create-profile' -Body @{
      user_stable_id = $u3
      declared_values = @('x')
      preferences = @{ tone = 'direct' }
      current_jurisdiction = 'US-OR'
      is_owner = $true
    } | Out-Null
    Invoke-JsonApi -Method POST -Path '/onboarding/step/2/add-boundaries' -Body @{
      user_stable_id = $u3
      is_owner = $true
      boundaries = @(@{ text = 'boundary-a' })
    } | Out-Null
    Invoke-JsonApi -Method POST -Path '/onboarding/step/3/create-policy' -Body @{
      user_stable_id = $u3
      is_owner = $true
      non_negotiables = @('x')
      escalation_rules = @()
      consent_requirements = @()
    } | Out-Null
    $firstPrimarch = Invoke-JsonApi -Method POST -Path '/onboarding/step/4/create-primarch-node' -Body @{
      user_stable_id = $u3
      is_owner = $true
      name_or_alias = 'Primarch-A'
      relationship_type = 'chosen'
      verification_level = 'primarch_verified'
      consent_scope = @{ read = @('*'); write = @('*'); share = @('*'); act = @('*') }
    }
    Assert-True (-not [string]::IsNullOrWhiteSpace([string]$firstPrimarch.node_id)) 'first primarch node_id missing'

    Expect-ApiErrorCode -Call {
      Invoke-JsonApi -Method POST -Path '/onboarding/step/4/create-primarch-node' -Body @{
        user_stable_id = $u3
        caller_node_id = $firstPrimarch.node_id
        is_owner = $false
        name_or_alias = 'Primarch-B'
        relationship_type = 'chosen'
        verification_level = 'primarch_verified'
        consent_scope = @{ read = @('*'); write = @('*'); share = @('*'); act = @('*') }
      }
    } -ExpectedCodes @('PRIMARCH_ALREADY_EXISTS') -ExpectedStatusCode 409
  }

  Run-Test 'P0-09 Projection redaction non-primarch' {
    $proj = Invoke-JsonApi -Method GET -Path "/projection/$UserId" -ExtraHeaders @{
      'X-Caller-Role' = 'advisor'
    }
    Assert-True ($null -ne $proj.metadata) 'projection metadata missing'
    if ($proj.active_memories) {
      foreach ($m in $proj.active_memories) {
        Assert-True ($m.sensitivity -ne 'critical') 'critical memory should be redacted for non-primarch'
      }
    }
  }

  Run-Test 'P0-10 Explainability-or-block behavior' {
    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Return answer without assumptions or evidence'
      domain = 'finance'
      actionability_level = 'advisory'
      session_id = $sessionId
      context = @{ test_mode = 'force_missing_evidence' }
    }
    Assert-True ($null -ne $eval.final_output) 'evaluate should respond safely'
  }

  Run-Test 'P0-11 Invalid role output resilience' {
    $eval = Invoke-JsonApi -Method POST -Path '/decisions/evaluate' -Body @{
      user_stable_id = $UserId
      caller_node_id = $script:primarchNodeId
      caller_role = 'primarch'
      query = 'Force malformed economist output'
      domain = 'finance'
      actionability_level = 'advisory'
      session_id = $sessionId
      context = @{ test_mode = 'force_invalid_economist' }
    }
    Assert-True ($null -ne $eval.record_id) 'system should return safe output or controlled block'
  }

  Run-Test 'P0-12 Event log immutability (DB)' {
    if ($SkipDbChecks) { return }
    $prevHardFailureCount = $script:HardFailures.Count
    Run-DbChecks
    if ($script:HardFailures.Count -gt $prevHardFailureCount) {
      throw ($script:HardFailures[$script:HardFailures.Count - 1])
    }
  }
  }

  if ($SkipApiTests) {
    Run-DbChecks
  }
  Run-NewmanGate

  if (-not $SkipTelemetryGate) {
    Run-Test 'Telemetry dashboard hard/warn gates' {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $dash = Invoke-JsonApiWithRetry -Method GET -Path "/telemetry/dashboard?user_stable_id=$UserId"
    $sw.Stop()

    if ($sw.ElapsedMilliseconds -gt $MaxTelemetryResponseMs) {
      Add-HardFailure "Telemetry response ${($sw.ElapsedMilliseconds)}ms exceeds max_telemetry_response_ms=$MaxTelemetryResponseMs"
    }

    $required = @(
      'material_action_without_valid_nonce_7d',
      'boundary_respect_rate_7d',
      'policy_check_failure_rate_7d',
      'council_disagreement_entropy_7d',
      'nonce_misuse_events_7d',
      'onboarding_completion_rate_current',
      'override_rate_by_domain_7d'
    )
    foreach ($k in $required) {
      if ($null -eq $dash.$k) { Add-HardFailure "Missing telemetry field: $k" }
    }

    $materialWithoutNonce = To-IntOr -Value $dash.material_action_without_valid_nonce_7d -Default 0
    $boundaryRate = To-DoubleOr -Value $dash.boundary_respect_rate_7d -Default 0.0
    $policyFailure = To-DoubleOr -Value $dash.policy_check_failure_rate_7d -Default 0.0
    $entropy = To-DoubleOr -Value $dash.council_disagreement_entropy_7d -Default 0.0
    $onboardingRate = if ($null -eq $dash.onboarding_completion_rate_current) { -1.0 } else { To-DoubleOr -Value $dash.onboarding_completion_rate_current -Default -1.0 }

    if ($materialWithoutNonce -ne 0) {
      Add-HardFailure "material_action_without_valid_nonce_7d must be 0 (actual=$materialWithoutNonce)"
    }
    if ($boundaryRate -lt $MinBoundaryRespectRate) {
      Add-HardFailure "boundary_respect_rate_7d below threshold (actual=$boundaryRate, min=$MinBoundaryRespectRate)"
    }
    if ($policyFailure -gt $MaxPolicyFailureRate) {
      Add-HardFailure "policy_check_failure_rate_7d above threshold (actual=$policyFailure, max=$MaxPolicyFailureRate)"
    }

    $nonceMisuse = $dash.nonce_misuse_events_7d
    Assert-MapLike -Value $nonceMisuse -Message 'nonce_misuse_events_7d must be an object'
    $replayCount = Get-NonNegativeIntField -Object $nonceMisuse -FieldName 'NONCE_REPLAY' -Default 0
    $bindingCount = Get-NonNegativeIntField -Object $nonceMisuse -FieldName 'NONCE_BINDING_MISMATCH' -Default 0
    $deltaReplay = [Math]::Max(0, $replayCount - $baselineReplayCount)
    $deltaBinding = [Math]::Max(0, $bindingCount - $baselineBindingMismatchCount)
    $expectedReplay = if ($SkipApiTests) { 0 } else { [Math]::Max(0, $ExpectedNonceReplayFromP0) }
    $expectedBinding = if ($SkipApiTests) { 0 } else { [Math]::Max(0, $ExpectedNonceBindingMismatchFromP0) }
    $unexpectedReplay = [Math]::Max(0, $deltaReplay - $expectedReplay)
    $unexpectedBinding = [Math]::Max(0, $deltaBinding - $expectedBinding)

    if ($EnforceNonceMisuseHardGate) {
      if ($unexpectedReplay -gt 0) {
        Add-HardFailure "Unexpected NONCE_REPLAY misuse above expected P0 negative-test allowance (baseline=$baselineReplayCount, current=$replayCount, delta=$deltaReplay, expected=$expectedReplay)"
      }
      if ($unexpectedBinding -gt 0) {
        Add-HardFailure "Unexpected NONCE_BINDING_MISMATCH misuse above expected P0 negative-test allowance (baseline=$baselineBindingMismatchCount, current=$bindingCount, delta=$deltaBinding, expected=$expectedBinding)"
      }
    } else {
      if ($deltaReplay -gt 0) {
        Add-Warning "NONCE_REPLAY misuse observed (baseline=$baselineReplayCount, current=$replayCount, delta=$deltaReplay)"
      }
      if ($deltaBinding -gt 0) {
        Add-Warning "NONCE_BINDING_MISMATCH misuse observed (baseline=$baselineBindingMismatchCount, current=$bindingCount, delta=$deltaBinding)"
      }
    }

    # Warnings only
    if ($entropy -gt $MaxEntropy7d) {
      Add-Warning "council_disagreement_entropy_7d above warning threshold (actual=$entropy, max=$MaxEntropy7d)"
    }

    $overrideMap = $dash.override_rate_by_domain_7d
    if ($null -ne $overrideMap) {
      Assert-MapLike -Value $overrideMap -Message 'override_rate_by_domain_7d must be an object'
      foreach ($prop in $overrideMap.PSObject.Properties) {
        $rate = To-DoubleOr -Value $prop.Value -Default 0.0
        if ($rate -gt $MaxOverrideRateByDomain) {
          Add-Warning "override rate warning for domain '$($prop.Name)' (actual=$rate, max=$MaxOverrideRateByDomain)"
        }
      }
    }

    if ($onboardingRate -ge 0 -and $onboardingRate -lt $MinOnboardingCompletionRate) {
      Add-Warning "onboarding_completion_rate_current below warning threshold (actual=$onboardingRate, min=$MinOnboardingCompletionRate)"
    }
    }
  }
}

$script:TestResults | Format-Table -AutoSize

$summaryWarnings = @($script:Warnings.ToArray())
$summaryHardFailures = @($script:HardFailures.ToArray())
$summaryTests = @($script:TestResults.ToArray())
$summaryFailedCount = @($summaryTests | Where-Object { $_.Status -eq 'FAIL' }).Count
$summaryPassedCount = [Math]::Max(0, $summaryTests.Count - $summaryFailedCount)
$summaryGateStatus = if ($summaryHardFailures.Count -eq 0 -and $summaryFailedCount -eq 0) { 'PASS' } else { 'FAIL' }
$summaryExpectedP0TestCount = if ($preflightBlocked -or $SkipApiTests) { 0 } else { 12 }
$summaryExpectedTelemetryTestCount = if ($preflightBlocked -or $SkipTelemetryGate) { 0 } else { 1 }
$summaryExpectedTotalTestCount = $summaryExpectedP0TestCount + $summaryExpectedTelemetryTestCount

$summary = [pscustomobject]@{
  generated_at_utc = (Get-Date).ToUniversalTime().ToString('o')
  base_url = $BaseUrl
  user_id = $UserId
  thresholds = [pscustomobject]@{
    min_boundary_respect_rate = $MinBoundaryRespectRate
    max_policy_failure_rate = $MaxPolicyFailureRate
    max_entropy_7d = $MaxEntropy7d
    max_override_rate_by_domain = $MaxOverrideRateByDomain
    min_onboarding_completion_rate = $MinOnboardingCompletionRate
    max_telemetry_response_ms = $MaxTelemetryResponseMs
  }
  warnings = $summaryWarnings
  hard_failures = $summaryHardFailures
  tests = $summaryTests
  passed = $summaryPassedCount
  failed = $summaryFailedCount
  expected_test_count = $summaryExpectedTotalTestCount
  expected_p0_test_count = $summaryExpectedP0TestCount
  expected_telemetry_test_count = $summaryExpectedTelemetryTestCount
  executed_test_count = $summaryTests.Count
  gate_status = $summaryGateStatus
  skip_api_tests = [bool]$SkipApiTests
  skip_telemetry_gate = [bool]$SkipTelemetryGate
  skip_db_checks = [bool]$SkipDbChecks
  preflight_enabled = $preflightEnabled
  preflight_ran = $preflightRan
  preflight_blocked = $preflightBlocked
  preflight_verdict = $preflightVerdict
  preflight_exit_code = $preflightExitCode
  preflight_report_path = $preflightReportPath
}

try {
  $summary | ConvertTo-Json -Depth 20 | Set-Content -Encoding UTF8 $ResultsJsonPath
}
catch {
  Add-Warning "Could not write test artifact '$ResultsJsonPath': $($_.Exception.Message)"
}

if ($script:Warnings.Count -gt 0) {
  Write-Host "`nWarnings:"
  foreach ($w in $script:Warnings) { Write-Host " - $w" }
}

if ($script:HardFailures.Count -gt 0) {
  Write-Host "`nHard failures:"
  foreach ($h in $script:HardFailures) { Write-Host " - $h" }
  Write-Host "P0/telemetry gate failed with $($script:HardFailures.Count) hard failures"
  exit 1
}

$failed = $script:TestResults | Where-Object { $_.Status -eq 'FAIL' }
if ($failed.Count -gt 0) {
  Write-Host "P0 test suite failed: $($failed.Count) tests"
  exit 1
}

Write-Host 'P0 + telemetry gate passed'
exit 0
