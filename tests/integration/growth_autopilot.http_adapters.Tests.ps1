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

function Assert-Contains {
  param([object[]]$Collection, $Value, [string]$Message = "Collection missing value.")
  if (-not ($Collection -contains $Value)) {
    throw "$Message`nExpected value: $Value"
  }
}

function Get-StableHash {
  param([Parameter(Mandatory = $true)][string]$Value)
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
  $sha = [System.Security.Cryptography.SHA256]::Create()
  try {
    $hashBytes = $sha.ComputeHash($bytes)
    return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
  }
  finally {
    $sha.Dispose()
  }
}

function Get-FreeTcpPort {
  $l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $l.Start()
  try {
    return ([System.Net.IPEndPoint]$l.LocalEndpoint).Port
  }
  finally {
    $l.Stop()
  }
}

function Start-TestHttpListener {
  param(
    [string]$BindHost = "127.0.0.1",
    [int]$MaxAttempts = 20
  )

  for ($i = 0; $i -lt $MaxAttempts; $i++) {
    $port = Get-FreeTcpPort
    $prefix = "http://{0}:{1}/" -f $BindHost, $port
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add($prefix)
    try {
      $listener.Start()
      try { $listener.IgnoreWriteExceptions = $true } catch {}
      return [pscustomobject]@{
        listener = $listener
        endpoint = $prefix
      }
    }
    catch {
      try { $listener.Close() } catch {}
    }
  }

  throw "Unable to start HttpListener for test."
}

function Read-HttpRequestBody {
  param([Parameter(Mandatory = $true)][System.Net.HttpListenerRequest]$Request)

  try {
    $sr = New-Object System.IO.StreamReader($Request.InputStream, $Request.ContentEncoding)
    try { [void]$sr.ReadToEnd() } finally { $sr.Dispose() }
  }
  catch {
    # best effort
  }
}

function Send-HttpResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.HttpListenerResponse]$Response,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][string]$Body,
    [string]$ContentType = "application/json"
  )

  $bytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $Response.StatusCode = $StatusCode
  $Response.ContentType = $ContentType
  $Response.ContentLength64 = $bytes.Length
  if ($bytes.Length -gt 0) {
    $Response.OutputStream.Write($bytes, 0, $bytes.Length)
  }
  $Response.OutputStream.Close()
}

function Invoke-AdapterPublishWithServerPlan {
  param(
    [Parameter(Mandatory = $true)][string]$LibPath,
    [Parameter(Mandatory = $true)][object[]]$ServerPlan,
    [int]$MaxAttempts = 1,
    [int]$HttpTimeoutSec = 5,
    [int[]]$RetryScheduleMs = @(0)
  )

  $server = Start-TestHttpListener
  $endpoint = [string]$server.endpoint

  $job = Start-Job -ArgumentList @($LibPath, $endpoint, $MaxAttempts, $HttpTimeoutSec, @($RetryScheduleMs)) -ScriptBlock {
    param($InnerLibPath, $InnerEndpoint, $InnerMaxAttempts, $InnerTimeoutSec, $InnerRetrySchedule)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"
    try { [System.Net.ServicePointManager]::Expect100Continue = $false } catch {}

    function Get-StableHash {
      param([Parameter(Mandatory = $true)][string]$Value)
      $bytes = [System.Text.Encoding]::UTF8.GetBytes($Value)
      $sha = [System.Security.Cryptography.SHA256]::Create()
      try {
        $hashBytes = $sha.ComputeHash($bytes)
        return (($hashBytes | ForEach-Object { $_.ToString("x2") }) -join "")
      }
      finally {
        $sha.Dispose()
      }
    }

    . $InnerLibPath

    $env:SANCTUM_GROWTH_X_ENDPOINT = $InnerEndpoint
    $env:SANCTUM_GROWTH_X_API_KEY = ""

    $action = [pscustomobject]@{
      plan_id = "p1"
      thread_or_target = "t1"
      ad_copy = "hello"
      reply_template = ""
      tracked_url = "https://example.com/pilot"
      disclosure = ""
      required_disclosures = @()
    }

    $policy = [pscustomobject]@{
      known = $true
      channel = "x"
      autopost_allowed = $true
      requires_human_review = $false
      posting_rate_limit_per_day = 10
      policy_confidence = 1.0
      required_disclosures = @()
    }

    Invoke-GrowthAutopilotAdapterPublish `
      -CampaignId "adapter-http-test" `
      -RunSignature "rs1" `
      -Channel "x" `
      -AdapterName "x" `
      -Transport "http" `
      -ActionRecord $action `
      -Policy $policy `
      -MaxAttempts $InnerMaxAttempts `
      -RetryScheduleMs @($InnerRetrySchedule) `
      -HttpTimeoutSec $InnerTimeoutSec
  }

  try {
    foreach ($step in @($ServerPlan)) {
      $ctx = $server.listener.GetContext()
      Read-HttpRequestBody -Request $ctx.Request

      if ($step.type -eq "sleep_close") {
        Start-Sleep -Seconds ([int]$step.seconds)
        try { $ctx.Response.Abort() } catch {}
        continue
      }

      $code = [int]$step.status
      $body = [string]$step.body
      $ct = [string]$step.content_type
      if ([string]::IsNullOrWhiteSpace($ct)) { $ct = "application/json" }
      Send-HttpResponse -Response $ctx.Response -StatusCode $code -Body $body -ContentType $ct
    }

    Wait-Job -Job $job | Out-Null
    if ($job.State -ne "Completed") {
      Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
      throw "Client job failed."
    }

    $out = @((Receive-Job -Job $job) | ForEach-Object { $_ })
    return $out[0]
  }
  finally {
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    try { $server.listener.Stop() } catch {}
    try { $server.listener.Close() } catch {}
  }
}

Describe "growth autopilot http adapter contracts" {
  BeforeAll {
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:LibPath = Join-Path $script:RepoRoot "scripts\lib\growth_autopilot_adapters.ps1"
    Assert-True -Condition (Test-Path -Path $script:LibPath -PathType Leaf) -Message "Missing lib: $script:LibPath"
  }

  It "accepts published response envelope and emits schema version" {
    $r = Invoke-AdapterPublishWithServerPlan -LibPath $script:LibPath -MaxAttempts 1 -HttpTimeoutSec 5 -RetryScheduleMs @(0) -ServerPlan @(
      @{ type = "response"; status = 200; body = '{"status":"published","external_ref":"ext-pub"}'; content_type = "application/json" }
    )

    Assert-Equal -Actual ([string]$r.publish_receipt.receipt_schema_version) -Expected "v1.0.0" -Message "receipt_schema_version mismatch."
    Assert-Equal -Actual ([string]$r.publish_receipt.status) -Expected "published" -Message "Receipt status mismatch."
    Assert-Equal -Actual ([string]$r.publish_receipt.external_ref) -Expected "ext-pub" -Message "external_ref mismatch."
    Assert-Equal -Actual ([int]$r.publish_receipt.attempt_count) -Expected 1 -Message "attempt_count mismatch."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_transport_http" -Message "Missing transport reason."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_http_publish_ok" -Message "Missing publish ok reason."
  }

  It "accepts queued response envelope" {
    $r = Invoke-AdapterPublishWithServerPlan -LibPath $script:LibPath -MaxAttempts 1 -HttpTimeoutSec 5 -RetryScheduleMs @(0) -ServerPlan @(
      @{ type = "response"; status = 200; body = '{"status":"queued","external_ref":"ext-queue"}'; content_type = "application/json" }
    )

    Assert-Equal -Actual ([string]$r.publish_receipt.status) -Expected "queued" -Message "Receipt status mismatch."
    Assert-Equal -Actual ([string]$r.publish_receipt.external_ref) -Expected "ext-queue" -Message "external_ref mismatch."
    Assert-Equal -Actual ([int]$r.publish_receipt.attempt_count) -Expected 1 -Message "attempt_count mismatch."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_http_publish_ok" -Message "Missing publish ok reason."
  }

  It "retries after transient failures and succeeds on later attempt" {
    $r = Invoke-AdapterPublishWithServerPlan -LibPath $script:LibPath -MaxAttempts 2 -HttpTimeoutSec 5 -RetryScheduleMs @(0) -ServerPlan @(
      @{ type = "response"; status = 200; body = 'OK'; content_type = "text/plain" }
      @{ type = "response"; status = 200; body = '{"status":"published","external_ref":"ext-retry"}'; content_type = "application/json" }
    )

    Assert-Equal -Actual ([string]$r.publish_receipt.status) -Expected "published" -Message "Receipt status mismatch."
    Assert-Equal -Actual ([string]$r.publish_receipt.external_ref) -Expected "ext-retry" -Message "external_ref mismatch."
    Assert-Equal -Actual ([int]$r.publish_receipt.attempt_count) -Expected 2 -Message "Expected retry attempt_count=2."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_http_publish_ok" -Message "Missing publish ok reason."
  }

  It "fails closed on malformed 200 response bodies" {
    $r = Invoke-AdapterPublishWithServerPlan -LibPath $script:LibPath -MaxAttempts 1 -HttpTimeoutSec 5 -RetryScheduleMs @(0) -ServerPlan @(
      @{ type = "response"; status = 200; body = 'OK'; content_type = "text/plain" }
    )

    Assert-Equal -Actual ([string]$r.publish_receipt.status) -Expected "failed" -Message "Malformed responses must fail."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_http_malformed_response" -Message "Expected malformed response reason code."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_attempts_exhausted" -Message "Expected attempts exhausted reason code."
  }

  It "treats request timeouts as adapter_http_timeout" {
    $r = Invoke-AdapterPublishWithServerPlan -LibPath $script:LibPath -MaxAttempts 1 -HttpTimeoutSec 1 -RetryScheduleMs @(0) -ServerPlan @(
      @{ type = "sleep_close"; seconds = 2 }
    )

    Assert-Equal -Actual ([string]$r.publish_receipt.status) -Expected "failed" -Message "Timeouts must fail."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_http_timeout" -Message "Expected timeout reason code."
    Assert-Contains -Collection @($r.publish_receipt.reason_codes) -Value "adapter_attempts_exhausted" -Message "Expected attempts exhausted reason code."
  }
}
