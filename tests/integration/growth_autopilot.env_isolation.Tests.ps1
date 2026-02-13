Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "growth_autopilot.test_env_utils.ps1")
. (Join-Path $PSScriptRoot "growth_autopilot.test_assert_utils.ps1")

Describe "growth autopilot env isolation" {
  BeforeAll {
    $script:GrowthEnvSnapshot = New-GrowthAutopilotTestEnvSnapshot
  }

  BeforeEach {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  AfterEach {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  AfterAll {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  It "allows SANCTUM_GROWTH_* env mutation within a test" {
    $env:SANCTUM_GROWTH_X_ENDPOINT = "http://example.invalid/endpoint"
    $env:SANCTUM_GROWTH_MOCK_FAIL_CHANNELS = "x"
    Assert-Equal -Actual ([Environment]::GetEnvironmentVariable("SANCTUM_GROWTH_X_ENDPOINT", "Process")) -Expected "http://example.invalid/endpoint" -Message "Expected SANCTUM_GROWTH_X_ENDPOINT to be set for this test."
    Assert-Equal -Actual ([Environment]::GetEnvironmentVariable("SANCTUM_GROWTH_MOCK_FAIL_CHANNELS", "Process")) -Expected "x" -Message "Expected SANCTUM_GROWTH_MOCK_FAIL_CHANNELS to be set for this test."
  }

  It "restores SANCTUM_GROWTH_* env state between tests" {
    $expectedEndpoint = $null
    if ($script:GrowthEnvSnapshot.values.ContainsKey("SANCTUM_GROWTH_X_ENDPOINT")) {
      $expectedEndpoint = [string]$script:GrowthEnvSnapshot.values["SANCTUM_GROWTH_X_ENDPOINT"]
    }
    $expectedFail = $null
    if ($script:GrowthEnvSnapshot.values.ContainsKey("SANCTUM_GROWTH_MOCK_FAIL_CHANNELS")) {
      $expectedFail = [string]$script:GrowthEnvSnapshot.values["SANCTUM_GROWTH_MOCK_FAIL_CHANNELS"]
    }

    $actualEndpoint = [Environment]::GetEnvironmentVariable("SANCTUM_GROWTH_X_ENDPOINT", "Process")
    $actualFail = [Environment]::GetEnvironmentVariable("SANCTUM_GROWTH_MOCK_FAIL_CHANNELS", "Process")

    Assert-Equal -Actual $actualEndpoint -Expected $expectedEndpoint -Message "Expected SANCTUM_GROWTH_X_ENDPOINT to be restored to baseline between tests."
    Assert-Equal -Actual $actualFail -Expected $expectedFail -Message "Expected SANCTUM_GROWTH_MOCK_FAIL_CHANNELS to be restored to baseline between tests."
  }
}

