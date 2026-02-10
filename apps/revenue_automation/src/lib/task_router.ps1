Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$taskRouterScriptRoot = if (-not [string]::IsNullOrWhiteSpace($PSCommandPath)) { Split-Path -Parent $PSCommandPath } else { (Get-Location).Path }
. (Join-Path $taskRouterScriptRoot "mock_provider.ps1")
. (Join-Path $taskRouterScriptRoot "http_provider.ps1")

function Invoke-RevenueTaskRoute {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$Config
  )

  $taskType = [string]$Task.task_type
  $supportedTaskTypes = @(
    "lead_enrich",
    "followup_draft",
    "calendar_proposal"
  )

  if ($supportedTaskTypes -notcontains $taskType) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "none"
      error = "Unsupported task_type: $taskType"
      artifacts = @()
    }
  }

  $providerMode = [string]$Config.provider_mode
  switch ($providerMode) {
    "mock" {
      return Invoke-MockProvider -Task $Task -Config $Config
    }
    "http" {
      return Invoke-HttpProvider -Task $Task -Config $Config
    }
    default {
      return [pscustomobject]@{
        status = "SKIPPED"
        provider_used = "none"
        error = "Unsupported provider_mode: $providerMode"
        artifacts = @()
      }
    }
  }
}
