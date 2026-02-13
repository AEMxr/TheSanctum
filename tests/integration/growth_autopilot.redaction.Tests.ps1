Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "growth_autopilot.test_env_utils.ps1")
. (Join-Path $PSScriptRoot "growth_autopilot.test_assert_utils.ps1")

function Read-HttpHeaders {
  param([Parameter(Mandatory = $true)][System.IO.Stream]$Stream)

  $buf = New-Object byte[] 4096
  $ms = New-Object System.IO.MemoryStream
  try {
    while ($true) {
      $n = $Stream.Read($buf, 0, $buf.Length)
      if ($n -le 0) { break }
      $ms.Write($buf, 0, $n)
      $text = [System.Text.Encoding]::ASCII.GetString($ms.ToArray())
      if ($text.Contains("`r`n`r`n")) { break }
      if ($ms.Length -gt 65536) { break }
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
    [Parameter(Mandatory = $true)][string]$Body
  )

  $bodyBytes = [System.Text.Encoding]::UTF8.GetBytes($Body)
  $headers = @(
    "HTTP/1.1 $StatusCode Internal Server Error",
    "Content-Type: application/json",
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

Describe "growth autopilot secret redaction" {
  BeforeAll {
    $script:GrowthEnvSnapshot = New-GrowthAutopilotTestEnvSnapshot
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:LibPath = Join-Path $script:RepoRoot "scripts\lib\growth_autopilot_adapters.ps1"
    Assert-True -Condition (Test-Path -Path $script:LibPath -PathType Leaf) -Message "Missing lib: $script:LibPath"
  }

  AfterEach {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  AfterAll {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  It "does not leak endpoints or API keys into adapter requests or receipts" {
    $listener = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = ([System.Net.IPEndPoint]$listener.LocalEndpoint).Port
    $endpoint = "http://127.0.0.1:$port/private"
    $apiKey = "supersecretkey"

    $assertPath = Join-Path $PSScriptRoot "growth_autopilot.test_assert_utils.ps1"

    $job = Start-Job -ArgumentList @($script:LibPath, $assertPath, $endpoint, $apiKey) -ScriptBlock {
      param($InnerLibPath, $InnerAssertPath, $InnerEndpoint, $InnerApiKey)
      Set-StrictMode -Version Latest
      $ErrorActionPreference = "Stop"

      . $InnerAssertPath
      . $InnerLibPath

      $env:SANCTUM_GROWTH_X_ENDPOINT = $InnerEndpoint
      $env:SANCTUM_GROWTH_X_API_KEY = $InnerApiKey

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
        -CampaignId "redaction-test" `
        -RunSignature "rs1" `
        -Channel "x" `
        -AdapterName "x" `
        -Transport "http" `
        -ActionRecord $action `
        -Policy $policy `
        -MaxAttempts 1 `
        -RetryScheduleMs @(0) `
        -HttpTimeoutSec 2
    }

    try {
      $tcp = $listener.AcceptTcpClient()
      Read-HttpHeaders -Stream $tcp.GetStream()
      Send-HttpResponse -Client $tcp -StatusCode 500 -Body '{\"error\":\"server\"}'

      Wait-Job -Job $job | Out-Null
      $result = @((Receive-Job -Job $job) | ForEach-Object { $_ })[0]

      $reqJson = $result.adapter_request | ConvertTo-Json -Depth 20 -Compress
      $recJson = $result.publish_receipt | ConvertTo-Json -Depth 20 -Compress
      $combined = $reqJson + $recJson

      Assert-NotContainsText -Text $combined -Needle $apiKey -Message "API key leaked into output artifacts."
      Assert-NotContainsText -Text $combined -Needle $endpoint -Message "Endpoint leaked into output artifacts."

      Assert-True -Condition (@($result.publish_receipt.reason_codes) -contains "adapter_http_exception") -Message "Expected adapter_http_exception reason."
      Assert-True -Condition (@($result.publish_receipt.reason_codes) -contains "adapter_attempts_exhausted") -Message "Expected adapter_attempts_exhausted reason."
    }
    finally {
      try { Remove-Job -Job $job -Force -ErrorAction SilentlyContinue } catch {}
      try { $listener.Stop() } catch {}
    }
  }
}
