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

function Read-HttpRequestDrain {
  param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

  $buf = New-Object byte[] 4096
  $ms = New-Object System.IO.MemoryStream
  try {
    $headerText = ""
    $headerEnd = -1
    while ($true) {
      $n = $Stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $ms.Write($buf, 0, $n)
      $text = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
      $headerEnd = $text.IndexOf("`r`n`r`n")
      if ($headerEnd -ge 0) {
        $headerText = $text.Substring(0, $headerEnd + 4)
        break
      }
      if ($ms.Length -gt 65536) { break }
    }

    if ($headerEnd -ge 0) {
      $contentLength = 0
      $m = [regex]::Match($headerText, '(?im)^Content-Length:\\s*(\\d+)')
      if ($m.Success) { [void][int]::TryParse([string]$m.Groups[1].Value, [ref]$contentLength) }

      $already = [int]($ms.Length - ($headerEnd + 4))
      $remaining = $contentLength - $already
      while ($remaining -gt 0) {
        $toRead = [Math]::Min($buf.Length, $remaining)
        $n2 = $Stream.Read($buf, 0, $toRead)
        if ($n2 -le 0) { break }
        $remaining -= $n2
      }
    }
  }
  finally {
    $ms.Dispose()
  }
}

function Send-HttpResponse {
  param(
    [Parameter(Mandatory = $true)][System.Net.Sockets.TcpClient]$Client,
    [Parameter(Mandatory = $true)][int]$StatusCode,
    [Parameter(Mandatory = $true)][string]$Body,
    [string]$ContentType = "application/json"
  )

  $statusText = switch ($StatusCode) {
    200 { "OK" }
    500 { "Internal Server Error" }
    default { "OK" }
  }

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $headers = @(
    "HTTP/1.1 $StatusCode $statusText",
    "Content-Type: $ContentType",
    "Content-Length: $($bodyBytes.Length)",
    "Connection: close",
    "",
    ""
  ) -join "`r`n"
  $headerBytes = [System.Text.Encoding]::ASCII.GetBytes($headers)

  $stream = $Client.GetStream()
  $stream.Write($headerBytes, 0, $headerBytes.Length)
  if ($bodyBytes.Length -gt 0) {
    $stream.Write($bodyBytes, 0, $bodyBytes.Length)
  }
  $stream.Flush()
  $Client.Close()
}

function Invoke-AdapterPublishWithServerPlan {
  param(
    [Parameter(Mandatory = $true)][string]$LibPath,
    [Parameter(Mandatory = $true)][object[]]$ServerPlan,
    [int]$MaxAttempts = 1,
    [int]$HttpTimeoutSec = 5,
    [int[]]$RetryScheduleMs = @(0)
  )

  $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
  $endpoint = "http://127.0.0.1:$port/"

  $job = Start-Job -ArgumentList @($LibPath, $endpoint, $MaxAttempts, $HttpTimeoutSec, @($RetryScheduleMs)) -ScriptBlock {
    param($InnerLibPath, $InnerEndpoint, $InnerMaxAttempts, $InnerTimeoutSec, $InnerRetrySchedule)

    Set-StrictMode -Version Latest
    $ErrorActionPreference = "Stop"

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
      $tcp = $listener.AcceptTcpClient()
      Read-HttpRequestDrain -Stream $tcp.GetStream()

      if ($step.type -eq "sleep_close") {
        Start-Sleep -Seconds ([int]$step.seconds)
        try { $tcp.Close() } catch {}
        continue
      }

      $code = [int]$step.status
      $body = [string]$step.body
      $ct = [string]$step.content_type
      if ([string]::IsNullOrWhiteSpace($ct)) { $ct = "application/json" }
      Send-HttpResponse -Client $tcp -StatusCode $code -Body $body -ContentType $ct
    }

    Wait-Job -Job $job | Out-Null
    if ($job.State -ne "Completed") {
      $err = Receive-Job -Job $job -ErrorAction SilentlyContinue
      throw "Client job failed."
    }

    $out = @((Receive-Job -Job $job) | ForEach-Object { $_ })
    return $out[0]
  }
  finally {
    try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
    try { $listener.Stop() } catch {}
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

    Assert-Equal -Actual ([string]$r.publish_receipt.status) -Expected "published" -Message (
      "Receipt status mismatch. reasons={0} attempts={1} external_ref={2}" -f
        ((@($r.publish_receipt.reason_codes) -join ",")),
        ([int]$r.publish_receipt.attempt_count),
        ([string]$r.publish_receipt.external_ref)
    )
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
