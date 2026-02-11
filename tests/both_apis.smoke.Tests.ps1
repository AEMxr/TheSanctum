# tests/both_apis.smoke.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester tests/both_apis.smoke.Tests.ps1

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

Describe "dual API smoke contract" {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = (Resolve-Path (Join-Path $here "..")).Path
    $script:ApiScriptPath = Join-Path $script:RepoRoot "apps/api/src/index.ps1"
    $script:RevenueScriptPath = Join-Path $script:RepoRoot "apps/revenue_automation/src/index.ps1"
    $script:PowerShellExe = (Get-Process -Id $PID).Path

    if (-not (Test-Path -Path $script:ApiScriptPath -PathType Leaf)) {
      throw "Missing API script: $script:ApiScriptPath"
    }
    if (-not (Test-Path -Path $script:RevenueScriptPath -PathType Leaf)) {
      throw "Missing revenue script: $script:RevenueScriptPath"
    }
  }

  It "language API health payload is reachable and has minimal keys" {
    $output = @(& $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:ApiScriptPath -Health 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Assert-Equal -Actual $exitCode -Expected 0 -Message "Language API health command should exit 0."

    $json = ($output -join [Environment]::NewLine)
    $health = $json | ConvertFrom-Json
    $required = @("service", "status", "ready", "mode_default", "supported_modes", "supported_languages")
    foreach ($field in $required) {
      Assert-True -Condition ($health.PSObject.Properties.Name -contains $field) -Message "Language API health missing field: $field"
    }
    Assert-Equal -Actual ([string]$health.service) -Expected "language_api" -Message "Language API health service mismatch."
    Assert-Equal -Actual ([string]$health.status) -Expected "ok" -Message "Language API health status mismatch."
    Assert-Equal -Actual ([bool]$health.ready) -Expected $true -Message "Language API health ready mismatch."
  }

  It "revenue API health payload is reachable and has minimal keys" {
    $output = @(& $script:PowerShellExe -NoProfile -ExecutionPolicy Bypass -File $script:RevenueScriptPath -Health 2>&1)
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    Assert-Equal -Actual $exitCode -Expected 0 -Message "Revenue health command should exit 0."

    $json = ($output -join [Environment]::NewLine)
    $health = $json | ConvertFrom-Json
    $required = @("service", "status", "ready", "provider_mode_default", "supported_provider_modes", "supports_safe_mode", "supports_dry_run")
    foreach ($field in $required) {
      Assert-True -Condition ($health.PSObject.Properties.Name -contains $field) -Message "Revenue health missing field: $field"
    }
    Assert-Equal -Actual ([string]$health.service) -Expected "revenue_automation" -Message "Revenue health service mismatch."
    Assert-Equal -Actual ([string]$health.status) -Expected "ok" -Message "Revenue health status mismatch."
    Assert-Equal -Actual ([bool]$health.ready) -Expected $true -Message "Revenue health ready mismatch."
  }
}
