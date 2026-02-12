Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not (Get-Variable -Name HttpRateLimitStore -Scope Script -ErrorAction SilentlyContinue)) {
  $script:HttpRateLimitStore = @{}
}

if (-not (Get-Variable -Name HttpIdempotencyStore -Scope Script -ErrorAction SilentlyContinue)) {
  $script:HttpIdempotencyStore = @{}
}

if (-not (Get-Variable -Name HttpStateConfigRegistry -Scope Script -ErrorAction SilentlyContinue)) {
  $script:HttpStateConfigRegistry = @{}
}

function New-ApiRequestId {
  return [guid]::NewGuid().ToString("N")
}

function Get-ApiUtcNow {
  return (Get-Date).ToUniversalTime()
}

function Get-ApiUnixEpochSeconds {
  return [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
}

function ConvertTo-PlainHashtable {
  param([object]$Value)

  if ($null -eq $Value) { return $null }

  if ($Value -is [hashtable]) {
    $out = @{}
    foreach ($k in $Value.Keys) {
      $out[[string]$k] = ConvertTo-PlainHashtable -Value $Value[$k]
    }
    return $out
  }

  if ($Value -is [System.Collections.IDictionary]) {
    $out = @{}
    foreach ($k in $Value.Keys) {
      $out[[string]$k] = ConvertTo-PlainHashtable -Value $Value[$k]
    }
    return $out
  }

  if ($Value -is [System.Collections.IEnumerable] -and -not ($Value -is [string])) {
    $list = New-Object System.Collections.Generic.List[object]
    foreach ($item in $Value) {
      [void]$list.Add((ConvertTo-PlainHashtable -Value $item))
    }
    return @($list.ToArray())
  }

  if ($Value -is [pscustomobject]) {
    $out = @{}
    foreach ($p in $Value.PSObject.Properties) {
      $out[[string]$p.Name] = ConvertTo-PlainHashtable -Value $p.Value
    }
    return $out
  }

  return $Value
}

function Get-ConfigFieldValue {
  param(
    [object]$Config,
    [string]$FieldName
  )

  if ($null -eq $Config -or [string]::IsNullOrWhiteSpace($FieldName)) { return $null }

  if ($Config -is [System.Collections.IDictionary]) {
    foreach ($key in $Config.Keys) {
      if ([string]::Equals([string]$key, [string]$FieldName, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $Config[$key]
      }
    }
  }

  if ($Config.PSObject.Properties.Name -contains $FieldName) {
    return $Config.$FieldName
  }

  return $null
}

function Get-ApiStateBackendKind {
  param([object]$HttpConfig)

  if ($null -eq $HttpConfig) { return "memory" }
  $backendValue = Get-ConfigFieldValue -Config $HttpConfig -FieldName "state_backend"
  if (-not [string]::IsNullOrWhiteSpace([string]$backendValue)) {
    return ([string]$backendValue).Trim().ToLowerInvariant()
  }
  return "memory"
}

function Get-ApiStatePath {
  param(
    [object]$HttpConfig,
    [string]$ServiceName
  )

  $pathValue = Get-ConfigFieldValue -Config $HttpConfig -FieldName "shared_state_path"
  if (-not [string]::IsNullOrWhiteSpace([string]$pathValue)) {
    return ([string]$pathValue).Trim()
  }

  $safeService = if ([string]::IsNullOrWhiteSpace($ServiceName)) { "service" } else { ($ServiceName -replace '[^A-Za-z0-9_-]', '_') }
  return (Join-Path ([System.IO.Path]::GetTempPath()) ("sanctum_{0}_shared_state.json" -f $safeService))
}

function Get-ApiStateScope {
  param(
    [object]$HttpConfig,
    [string]$ServiceName
  )

  $effectiveConfig = $HttpConfig
  if ($null -eq $effectiveConfig -and -not [string]::IsNullOrWhiteSpace($ServiceName)) {
    $registryKey = ([string]$ServiceName).Trim()
    if ($script:HttpStateConfigRegistry.ContainsKey($registryKey)) {
      $effectiveConfig = $script:HttpStateConfigRegistry[$registryKey]
    }
  }

  $scope = Get-ConfigFieldValue -Config $effectiveConfig -FieldName "shared_state_scope"
  if ([string]::IsNullOrWhiteSpace([string]$scope)) {
    $scope = Get-ConfigFieldValue -Config $effectiveConfig -FieldName "service_name"
  }
  if ([string]::IsNullOrWhiteSpace([string]$scope)) {
    $scope = $ServiceName
  }
  if ([string]::IsNullOrWhiteSpace([string]$scope)) {
    $scope = "service"
  }
  return ([string]$scope).Trim()
}

function Read-HttpSharedState {
  param([Parameter(Mandatory = $true)][string]$Path)

  if (-not (Test-Path -Path $Path -PathType Leaf)) {
    return [pscustomobject]@{
      rate_limit = @{}
      idempotency = @{}
    }
  }

  $raw = Get-Content -Path $Path -Raw -Encoding UTF8
  if ([string]::IsNullOrWhiteSpace($raw)) {
    return [pscustomobject]@{
      rate_limit = @{}
      idempotency = @{}
    }
  }

  $parsed = $raw | ConvertFrom-Json
  $rateStore = @{}
  $idemStore = @{}
  if ($parsed.PSObject.Properties.Name -contains "rate_limit" -and $null -ne $parsed.rate_limit) {
    $rateStore = ConvertTo-PlainHashtable -Value $parsed.rate_limit
  }
  if ($parsed.PSObject.Properties.Name -contains "idempotency" -and $null -ne $parsed.idempotency) {
    $idemStore = ConvertTo-PlainHashtable -Value $parsed.idempotency
  }

  return [pscustomobject]@{
    rate_limit = if ($rateStore -is [hashtable]) { $rateStore } else { @{} }
    idempotency = if ($idemStore -is [hashtable]) { $idemStore } else { @{} }
  }
}

function Write-HttpSharedState {
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [Parameter(Mandatory = $true)][hashtable]$RateStore,
    [Parameter(Mandatory = $true)][hashtable]$IdemStore
  )

  $dir = Split-Path -Parent $Path
  if (-not [string]::IsNullOrWhiteSpace($dir) -and -not (Test-Path -Path $dir -PathType Container)) {
    New-Item -ItemType Directory -Path $dir -Force | Out-Null
  }

  $payload = [ordered]@{
    rate_limit = $RateStore
    idempotency = $IdemStore
  }
  $payload | ConvertTo-Json -Depth 100 | Set-Content -Path $Path -Encoding UTF8
}

function Invoke-HttpStateStoreOperation {
  param(
    [object]$HttpConfig,
    [string]$ServiceName,
    [Parameter(Mandatory = $true)][scriptblock]$Operation
  )

  $effectiveConfig = $HttpConfig
  if ($null -eq $effectiveConfig -and -not [string]::IsNullOrWhiteSpace($ServiceName)) {
    $registryKey = ([string]$ServiceName).Trim()
    if ($script:HttpStateConfigRegistry.ContainsKey($registryKey)) {
      $effectiveConfig = $script:HttpStateConfigRegistry[$registryKey]
    }
  }

  $backend = Get-ApiStateBackendKind -HttpConfig $effectiveConfig
  if ($backend -notin @("memory", "file")) {
    throw "Unsupported state_backend '$backend'. Expected memory|file."
  }

  $debugStateEnabled = [string]::Equals([string][Environment]::GetEnvironmentVariable("SANCTUM_HTTP_DEBUG_STATE"), "1", [System.StringComparison]::OrdinalIgnoreCase)
  if ($debugStateEnabled) {
    $tmpDebugPath = [Environment]::GetEnvironmentVariable("SANCTUM_HTTP_DEBUG_STATE_PATH")
    if ([string]::IsNullOrWhiteSpace($tmpDebugPath)) {
      $tmpDebugPath = Join-Path ([System.IO.Path]::GetTempPath()) "sanctum_http_state_debug.log"
    }
    $tmpService = if ([string]::IsNullOrWhiteSpace($ServiceName)) { "service" } else { $ServiceName }
    $tmpScope = Get-ApiStateScope -HttpConfig $effectiveConfig -ServiceName $tmpService
    $tmpStatePath = Get-ApiStatePath -HttpConfig $effectiveConfig -ServiceName $tmpScope
    $line = "{0} service={1} scope={2} backend={3} state_path={4}" -f (Get-ApiUtcNow.ToString("o")), $tmpService, $tmpScope, $backend, $tmpStatePath
    Add-Content -Path $tmpDebugPath -Value $line -Encoding UTF8
  }

  if ($backend -eq "memory") {
    return & $Operation $script:HttpRateLimitStore $script:HttpIdempotencyStore
  }

  $resolvedService = if ([string]::IsNullOrWhiteSpace($ServiceName)) {
    $serviceValue = Get-ConfigFieldValue -Config $effectiveConfig -FieldName "service_name"
    if (-not [string]::IsNullOrWhiteSpace([string]$serviceValue)) { [string]$serviceValue } else { "service" }
  }
  else {
    $ServiceName
  }
  $scope = Get-ApiStateScope -HttpConfig $effectiveConfig -ServiceName $resolvedService
  $statePath = Get-ApiStatePath -HttpConfig $effectiveConfig -ServiceName $scope
  $mutexName = "Global\SanctumHttpState_{0}" -f ($scope -replace '[^A-Za-z0-9_]', '_')
  $mutex = New-Object System.Threading.Mutex($false, $mutexName)
  $lockTaken = $false
  try {
    $lockTaken = $mutex.WaitOne([TimeSpan]::FromSeconds(15))
    if (-not $lockTaken) {
      throw "Timed out waiting for shared state lock: $mutexName"
    }

    $state = Read-HttpSharedState -Path $statePath
    $rateStore = ConvertTo-PlainHashtable -Value $state.rate_limit
    $idemStore = ConvertTo-PlainHashtable -Value $state.idempotency
    if ($null -eq $rateStore -or -not ($rateStore -is [hashtable])) { $rateStore = @{} }
    if ($null -eq $idemStore -or -not ($idemStore -is [hashtable])) { $idemStore = @{} }

    $result = & $Operation $rateStore $idemStore
    Write-HttpSharedState -Path $statePath -RateStore $rateStore -IdemStore $idemStore
    return $result
  }
  finally {
    if ($lockTaken) {
      try { $mutex.ReleaseMutex() | Out-Null } catch {}
    }
    $mutex.Dispose()
  }
}

function Get-Sha256Hex {
  param([string]$Text)

  $value = if ($null -eq $Text) { "" } else { [string]$Text }
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hash = $sha.ComputeHash($bytes)
  }
  finally {
    $sha.Dispose()
  }

  $builder = New-Object System.Text.StringBuilder
  foreach ($b in $hash) {
    [void]$builder.Append($b.ToString("x2"))
  }
  return $builder.ToString()
}

function ConvertFrom-JsonSafe {
  param(
    [string]$Raw,
    [string]$Label = "JSON payload"
  )

  try {
    return ($Raw | ConvertFrom-Json)
  }
  catch {
    throw "$Label is not valid JSON: $($_.Exception.Message)"
  }
}

function New-ProblemObject {
  param(
    [Parameter(Mandatory = $true)][int]$Status,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Type = "about:blank",
    [string]$Instance = "",
    [string]$RequestId = ""
  )

  return [pscustomobject]@{
    type = $Type
    title = $Title
    status = $Status
    detail = $Detail
    instance = $Instance
    request_id = $RequestId
  }
}

function Write-HttpRawResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][string]$Body,
    [string]$ContentType = "application/json"
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentEncoding = [System.Text.Encoding]::UTF8
  $Response.ContentLength64 = $bytes.LongLength
  $Response.OutputStream.Write($bytes, 0, $bytes.Length)
}

function Write-HttpJsonResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][object]$BodyObject,
    [string]$ContentType = "application/json"
  )

  $json = $BodyObject | ConvertTo-Json -Depth 100 -Compress
  Write-HttpRawResponse -Response $Response -StatusCode $StatusCode -Body $json -ContentType $ContentType
}

function Write-HttpProblemResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
    [Parameter(Mandatory = $true)][int]$Status,
    [Parameter(Mandatory = $true)][string]$Title,
    [Parameter(Mandatory = $true)][string]$Detail,
    [string]$Instance = "",
    [string]$RequestId = ""
  )

  $problem = New-ProblemObject -Status $Status -Title $Title -Detail $Detail -Type "https://httpstatuses.com/$Status" -Instance $Instance -RequestId $RequestId
  Write-HttpJsonResponse -Response $Response -StatusCode $Status -BodyObject $problem -ContentType "application/problem+json"
}

function Read-HttpRequestBodyText {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request,
    [int]$MaxBytes = 65536
  )

  if ($MaxBytes -lt 1) { $MaxBytes = 1 }

  if ($Request.ContentLength64 -gt 0 -and $Request.ContentLength64 -gt $MaxBytes) {
    throw "Request body exceeds maximum allowed bytes ($MaxBytes)."
  }

  $stream = $Request.InputStream
  $buffer = New-Object byte[] 4096
  $ms = New-Object System.IO.MemoryStream
  try {
    while ($true) {
      $read = $stream.Read($buffer, 0, $buffer.Length)
      if ($read -le 0) { break }
      $ms.Write($buffer, 0, $read)
      if ($ms.Length -gt $MaxBytes) {
        throw "Request body exceeds maximum allowed bytes ($MaxBytes)."
      }
    }

    $bytes = $ms.ToArray()
    return [System.Text.Encoding]::UTF8.GetString($bytes)
  }
  finally {
    $ms.Dispose()
  }
}

function Get-ApiHttpConfig {
  param(
    [string]$ServiceName,
    [object]$ConfigObject,
    [int]$DefaultPort,
    [string]$DefaultUsageLedgerPath,
    [string]$DefaultSchemaVersion
  )

  $servicePrefix = ($ServiceName -replace '[^A-Za-z0-9]', '_').ToUpperInvariant()

  $httpConfig = $null
  if ($null -ne $ConfigObject -and $ConfigObject.PSObject.Properties.Name -contains "http") {
    $httpConfig = $ConfigObject.http
  }

  $bindHost = "127.0.0.1"
  $port = $DefaultPort
  $maxRequestBytes = 65536
  $requestTimeoutMs = 15000
  $rateLimitMaxRequests = 60
  $rateLimitWindowSeconds = 60
  $idempotencyTtlSeconds = 300
  $stateBackend = "memory"
  $sharedStateScope = if ([string]::IsNullOrWhiteSpace($ServiceName)) { "service" } else { ([string]$ServiceName).Trim() }
  $safeServiceForPath = if ([string]::IsNullOrWhiteSpace($ServiceName)) { "service" } else { ($ServiceName -replace '[^A-Za-z0-9_-]', '_') }
  $sharedStatePath = Join-Path ([System.IO.Path]::GetTempPath()) ("sanctum_{0}_shared_state.json" -f $safeServiceForPath)
  $schemaVersion = $DefaultSchemaVersion
  $usageLedgerPath = $DefaultUsageLedgerPath
  $apiKeys = @(
    [pscustomobject]@{
      key_id = "dev-local"
      key = "dev-local-key"
      key_sha256 = (Get-Sha256Hex -Text "dev-local-key")
      role = "admin"
    }
  )

  if ($null -ne $httpConfig) {
    if ($httpConfig.PSObject.Properties.Name -contains "host" -and -not [string]::IsNullOrWhiteSpace([string]$httpConfig.host)) {
      $bindHost = ([string]$httpConfig.host).Trim()
    }
    if ($httpConfig.PSObject.Properties.Name -contains "port") {
      $tmpPort = 0
      if ([int]::TryParse([string]$httpConfig.port, [ref]$tmpPort) -and $tmpPort -gt 0) {
        $port = $tmpPort
      }
    }
    if ($httpConfig.PSObject.Properties.Name -contains "max_request_bytes") {
      $tmpMax = 0
      if ([int]::TryParse([string]$httpConfig.max_request_bytes, [ref]$tmpMax) -and $tmpMax -gt 0) {
        $maxRequestBytes = $tmpMax
      }
    }
    if ($httpConfig.PSObject.Properties.Name -contains "request_timeout_ms") {
      $tmpTimeout = 0
      if ([int]::TryParse([string]$httpConfig.request_timeout_ms, [ref]$tmpTimeout) -and $tmpTimeout -gt 0) {
        $requestTimeoutMs = $tmpTimeout
      }
    }
    if ($httpConfig.PSObject.Properties.Name -contains "idempotency_ttl_seconds") {
      $tmpTtl = 0
      if ([int]::TryParse([string]$httpConfig.idempotency_ttl_seconds, [ref]$tmpTtl) -and $tmpTtl -gt 0) {
        $idempotencyTtlSeconds = $tmpTtl
      }
    }
    if ($httpConfig.PSObject.Properties.Name -contains "state_backend" -and -not [string]::IsNullOrWhiteSpace([string]$httpConfig.state_backend)) {
      $tmpBackend = ([string]$httpConfig.state_backend).Trim().ToLowerInvariant()
      if ($tmpBackend -in @("memory", "file")) {
        $stateBackend = $tmpBackend
      }
    }
    if ($httpConfig.PSObject.Properties.Name -contains "shared_state_path" -and -not [string]::IsNullOrWhiteSpace([string]$httpConfig.shared_state_path)) {
      $sharedStatePath = ([string]$httpConfig.shared_state_path).Trim()
    }
    if ($httpConfig.PSObject.Properties.Name -contains "shared_state_scope" -and -not [string]::IsNullOrWhiteSpace([string]$httpConfig.shared_state_scope)) {
      $sharedStateScope = ([string]$httpConfig.shared_state_scope).Trim()
    }
    if ($httpConfig.PSObject.Properties.Name -contains "schema_version" -and -not [string]::IsNullOrWhiteSpace([string]$httpConfig.schema_version)) {
      $schemaVersion = ([string]$httpConfig.schema_version).Trim()
    }
    if ($httpConfig.PSObject.Properties.Name -contains "usage_ledger_path" -and -not [string]::IsNullOrWhiteSpace([string]$httpConfig.usage_ledger_path)) {
      $usageLedgerPath = ([string]$httpConfig.usage_ledger_path).Trim()
    }

    if ($httpConfig.PSObject.Properties.Name -contains "rate_limit" -and $null -ne $httpConfig.rate_limit) {
      $rl = $httpConfig.rate_limit
      if ($rl.PSObject.Properties.Name -contains "max_requests") {
        $tmpMaxReq = 0
        if ([int]::TryParse([string]$rl.max_requests, [ref]$tmpMaxReq) -and $tmpMaxReq -gt 0) {
          $rateLimitMaxRequests = $tmpMaxReq
        }
      }
      if ($rl.PSObject.Properties.Name -contains "window_seconds") {
        $tmpWindow = 0
        if ([int]::TryParse([string]$rl.window_seconds, [ref]$tmpWindow) -and $tmpWindow -gt 0) {
          $rateLimitWindowSeconds = $tmpWindow
        }
      }
    }

    if ($httpConfig.PSObject.Properties.Name -contains "api_keys" -and $null -ne $httpConfig.api_keys) {
      $normalized = New-Object System.Collections.Generic.List[object]
      foreach ($entry in @($httpConfig.api_keys)) {
        if ($null -eq $entry) { continue }
        $keyId = ([string]$entry.key_id).Trim()
        $keyValue = ""
        if ($entry.PSObject.Properties.Name -contains "key" -and -not [string]::IsNullOrWhiteSpace([string]$entry.key)) {
          $keyValue = ([string]$entry.key).Trim()
        }
        $keyHash = ""
        if ($entry.PSObject.Properties.Name -contains "key_sha256" -and -not [string]::IsNullOrWhiteSpace([string]$entry.key_sha256)) {
          $keyHash = ([string]$entry.key_sha256).Trim().ToLowerInvariant()
        }
        elseif ($entry.PSObject.Properties.Name -contains "key_hash" -and -not [string]::IsNullOrWhiteSpace([string]$entry.key_hash)) {
          $keyHash = ([string]$entry.key_hash).Trim().ToLowerInvariant()
        }
        if (-not [string]::IsNullOrWhiteSpace($keyHash) -and ($keyHash -notmatch '^[0-9a-f]{64}$')) {
          continue
        }
        if ([string]::IsNullOrWhiteSpace($keyHash) -and -not [string]::IsNullOrWhiteSpace($keyValue)) {
          $keyHash = Get-Sha256Hex -Text $keyValue
        }
        $role = ([string]$entry.role).Trim().ToLowerInvariant()
        if ([string]::IsNullOrWhiteSpace($keyId) -or ([string]::IsNullOrWhiteSpace($keyValue) -and [string]::IsNullOrWhiteSpace($keyHash))) { continue }
        if ($role -notin @("admin", "standard")) { $role = "standard" }
        [void]$normalized.Add([pscustomobject]@{
          key_id = $keyId
          key = $keyValue
          key_sha256 = $keyHash
          role = $role
        })
      }

      if ($normalized.Count -gt 0) {
        $apiKeys = @($normalized.ToArray())
      }
    }
  }

  $envPortName = "{0}_API_PORT" -f $servicePrefix
  $envPortValue = [Environment]::GetEnvironmentVariable($envPortName)
  if (-not [string]::IsNullOrWhiteSpace($envPortValue)) {
    $tmpEnvPort = 0
    if ([int]::TryParse($envPortValue, [ref]$tmpEnvPort) -and $tmpEnvPort -gt 0) {
      $port = $tmpEnvPort
    }
  }

  $runtime = [pscustomobject]@{
    service_name = $ServiceName
    host = $bindHost
    port = $port
    max_request_bytes = $maxRequestBytes
    request_timeout_ms = $requestTimeoutMs
    rate_limit_max_requests = $rateLimitMaxRequests
    rate_limit_window_seconds = $rateLimitWindowSeconds
    idempotency_ttl_seconds = $idempotencyTtlSeconds
    state_backend = $stateBackend
    shared_state_path = $sharedStatePath
    shared_state_scope = $sharedStateScope
    api_keys = @($apiKeys)
    usage_ledger_path = $usageLedgerPath
    schema_version = $schemaVersion
  }

  $registryKey = if ([string]::IsNullOrWhiteSpace([string]$ServiceName)) { "" } else { ([string]$ServiceName).Trim() }
  if (-not [string]::IsNullOrWhiteSpace($registryKey)) {
    $script:HttpStateConfigRegistry[$registryKey] = [pscustomobject]@{
      service_name = $registryKey
      state_backend = [string]$runtime.state_backend
      shared_state_path = [string]$runtime.shared_state_path
      shared_state_scope = [string]$runtime.shared_state_scope
    }
  }

  return $runtime
}

function Get-ApiKeyPrincipal {
  param(
    [Parameter(Mandatory = $true)][object]$HttpConfig,
    [string]$ProvidedKey
  )

  if ([string]::IsNullOrWhiteSpace($ProvidedKey)) {
    return $null
  }

  $provided = [string]$ProvidedKey
  $providedHash = Get-Sha256Hex -Text $provided

  foreach ($entry in @($HttpConfig.api_keys)) {
    $entryKey = [string]$entry.key
    $entryHash = ([string]$entry.key_sha256).Trim().ToLowerInvariant()
    $matched = $false
    if (-not [string]::IsNullOrWhiteSpace($entryKey) -and $entryKey -ceq $provided) {
      $matched = $true
    }
    elseif (-not [string]::IsNullOrWhiteSpace($entryHash) -and $entryHash -eq $providedHash) {
      $matched = $true
    }

    if ($matched) {
      return [pscustomobject]@{
        key_id = [string]$entry.key_id
        role = [string]$entry.role
      }
    }
  }

  return $null
}

function Test-ApiRequestAllowedByRateLimit {
  param(
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [Parameter(Mandatory = $true)][string]$KeyId,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [int]$WindowSeconds,
    [int]$MaxRequests,
    [object]$HttpConfig = $null
  )

  if ($WindowSeconds -lt 1) { $WindowSeconds = 1 }
  if ($MaxRequests -lt 1) { $MaxRequests = 1 }

  $scope = Get-ApiStateScope -HttpConfig $HttpConfig -ServiceName $ServiceName
  $now = Get-ApiUnixEpochSeconds
  $bucket = [int][Math]::Floor($now / $WindowSeconds)
  $storeKey = "{0}|{1}|{2}|{3}" -f $scope, $KeyId, $Endpoint, $bucket
  $backendUsed = Get-ApiStateBackendKind -HttpConfig $HttpConfig

  $rateDecision = Invoke-HttpStateStoreOperation -HttpConfig $HttpConfig -ServiceName $ServiceName -Operation {
    param([hashtable]$RateStore, [hashtable]$IdemStore)

    $count = 0
    if ($RateStore.ContainsKey($storeKey)) {
      $count = [int]$RateStore[$storeKey]
    }

    $count++
    $RateStore[$storeKey] = $count

    $allowed = ($count -le $MaxRequests)
    $remaining = [Math]::Max(0, ($MaxRequests - $count))
    $resetEpoch = (($bucket + 1) * $WindowSeconds)

    return [pscustomobject]@{
      allowed = $allowed
      remaining = $remaining
      reset_epoch = $resetEpoch
      observed_count = $count
    }
  }

  if ($rateDecision.PSObject.Properties.Name -notcontains "backend_used") {
    $rateDecision | Add-Member -NotePropertyName backend_used -NotePropertyValue $backendUsed -Force
  }
  return $rateDecision
}

function Remove-ExpiredIdempotencyEntries {
  param(
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [int]$TtlSeconds,
    [object]$HttpConfig = $null
  )

  if ($TtlSeconds -lt 1) { $TtlSeconds = 1 }
  $scope = Get-ApiStateScope -HttpConfig $HttpConfig -ServiceName $ServiceName

  Invoke-HttpStateStoreOperation -HttpConfig $HttpConfig -ServiceName $ServiceName -Operation {
    param([hashtable]$RateStore, [hashtable]$IdemStore)

    $now = Get-ApiUnixEpochSeconds
    $prefix = "{0}|" -f $scope
    $keys = @($IdemStore.Keys)
    foreach ($key in $keys) {
      if (-not $key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
        continue
      }

      $entry = $IdemStore[$key]
      if ($null -eq $entry) {
        [void]$IdemStore.Remove($key)
        continue
      }

      $createdEpoch = 0
      [void][int]::TryParse([string]$entry.created_epoch, [ref]$createdEpoch)
      if (($now - $createdEpoch) -gt $TtlSeconds) {
        [void]$IdemStore.Remove($key)
      }
    }
  } | Out-Null
}

function Get-IdempotencyReplayDecision {
  param(
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [Parameter(Mandatory = $true)][string]$KeyId,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][string]$IdempotencyKey,
    [Parameter(Mandatory = $true)][string]$BodyHash,
    [int]$TtlSeconds,
    [object]$HttpConfig = $null
  )

  if ($TtlSeconds -lt 1) { $TtlSeconds = 1 }
  $scope = Get-ApiStateScope -HttpConfig $HttpConfig -ServiceName $ServiceName
  $storeKey = "{0}|{1}|{2}|{3}" -f $scope, $KeyId, $Endpoint, $IdempotencyKey

  return Invoke-HttpStateStoreOperation -HttpConfig $HttpConfig -ServiceName $ServiceName -Operation {
    param([hashtable]$RateStore, [hashtable]$IdemStore)

    $now = Get-ApiUnixEpochSeconds
    $prefix = "{0}|" -f $scope
    $keys = @($IdemStore.Keys)
    foreach ($key in $keys) {
      if (-not $key.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) { continue }
      $entryCandidate = $IdemStore[$key]
      if ($null -eq $entryCandidate) {
        [void]$IdemStore.Remove($key)
        continue
      }
      $createdEpochCandidate = 0
      [void][int]::TryParse([string]$entryCandidate.created_epoch, [ref]$createdEpochCandidate)
      if (($now - $createdEpochCandidate) -gt $TtlSeconds) {
        [void]$IdemStore.Remove($key)
      }
    }

    if (-not $IdemStore.ContainsKey($storeKey)) {
      return [pscustomobject]@{ has_entry = $false; replay = $false; conflict = $false; entry = $null }
    }

    $entry = $IdemStore[$storeKey]
    if ([string]$entry.body_hash -ne [string]$BodyHash) {
      return [pscustomobject]@{ has_entry = $true; replay = $false; conflict = $true; entry = $entry }
    }

    return [pscustomobject]@{ has_entry = $true; replay = $true; conflict = $false; entry = $entry }
  }
}

function Save-IdempotencyResponse {
  param(
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [Parameter(Mandatory = $true)][string]$KeyId,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][string]$IdempotencyKey,
    [Parameter(Mandatory = $true)][string]$BodyHash,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][string]$ContentType,
    [Parameter(Mandatory = $true)][string]$JsonBody,
    [object]$HttpConfig = $null
  )

  $scope = Get-ApiStateScope -HttpConfig $HttpConfig -ServiceName $ServiceName
  $storeKey = "{0}|{1}|{2}|{3}" -f $scope, $KeyId, $Endpoint, $IdempotencyKey
  Invoke-HttpStateStoreOperation -HttpConfig $HttpConfig -ServiceName $ServiceName -Operation {
    param([hashtable]$RateStore, [hashtable]$IdemStore)
    $IdemStore[$storeKey] = [pscustomobject]@{
      body_hash = $BodyHash
      status_code = $StatusCode
      content_type = $ContentType
      json_body = $JsonBody
      created_epoch = Get-ApiUnixEpochSeconds
    }
  } | Out-Null
}

function Add-UsageLedgerEntry {
  param(
    [Parameter(Mandatory = $true)][string]$LedgerPath,
    [Parameter(Mandatory = $true)][string]$ServiceName,
    [Parameter(Mandatory = $true)][string]$RequestId,
    [Parameter(Mandatory = $true)][string]$KeyId,
    [Parameter(Mandatory = $true)][string]$Endpoint,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][int]$LatencyMs,
    [Parameter(Mandatory = $true)][int]$BillableUnits,
    [int]$RequestBytes = 0,
    [int]$ResponseBytes = 0,
    [bool]$IdempotencyReplay = $false
  )

  try {
    $directory = Split-Path -Parent $LedgerPath
    if (-not [string]::IsNullOrWhiteSpace($directory) -and -not (Test-Path -Path $directory -PathType Container)) {
      New-Item -ItemType Directory -Path $directory -Force | Out-Null
    }

    $entry = [pscustomobject]@{
      timestamp_utc = (Get-ApiUtcNow).ToString("o")
      service = $ServiceName
      request_id = $RequestId
      key_id = $KeyId
      endpoint = $Endpoint
      status_code = $StatusCode
      latency_ms = $LatencyMs
      billable_units = $BillableUnits
      request_bytes = $RequestBytes
      response_bytes = $ResponseBytes
      idempotency_replay = $IdempotencyReplay
    }

    $line = $entry | ConvertTo-Json -Depth 10 -Compress
    Add-Content -Path $LedgerPath -Value $line -Encoding UTF8
  }
  catch {
    Write-Warning "Unable to append usage ledger entry: $($_.Exception.Message)"
  }
}

function Get-UsageLedgerEntries {
  param(
    [Parameter(Mandatory = $true)][string]$LedgerPath,
    [datetime]$FromUtc,
    [datetime]$ToUtc
  )

  if (-not (Test-Path -Path $LedgerPath -PathType Leaf)) {
    return @()
  }

  $rows = New-Object System.Collections.Generic.List[object]
  $lines = Get-Content -Path $LedgerPath -Encoding UTF8
  foreach ($line in $lines) {
    if ([string]::IsNullOrWhiteSpace($line)) { continue }
    try {
      $row = $line | ConvertFrom-Json
      $ts = [datetime]::MinValue
      if (-not [datetime]::TryParse([string]$row.timestamp_utc, [ref]$ts)) {
        continue
      }
      $utcTs = $ts.ToUniversalTime()
      if ($PSBoundParameters.ContainsKey("FromUtc") -and $utcTs -lt $FromUtc.ToUniversalTime()) { continue }
      if ($PSBoundParameters.ContainsKey("ToUtc") -and $utcTs -gt $ToUtc.ToUniversalTime()) { continue }
      [void]$rows.Add($row)
    }
    catch {
      continue
    }
  }

  return @($rows.ToArray())
}

function Get-HttpQueryParameters {
  param([Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request)

  $query = @{}
  foreach ($key in $Request.QueryString.AllKeys) {
    if ($null -eq $key) { continue }
    $query[$key] = [string]$Request.QueryString[$key]
  }
  return $query
}
