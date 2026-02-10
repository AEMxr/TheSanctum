Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-MockProvider {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$Config
  )

  $taskType = [string]$Task.task_type
  $taskId = [string]$Task.task_id
  $supportedTaskTypes = @(
    "lead_enrich",
    "followup_draft",
    "calendar_proposal"
  )

  if ($supportedTaskTypes -notcontains $taskType) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "mock"
      error = "Unsupported task_type for mock provider: $taskType"
      artifacts = @()
    }
  }

  $artifactPrefix = if ($Config.dry_run) { "dryrun" } else { "result" }
  $artifact = "${artifactPrefix}://mock/$taskType/$taskId"

  return [pscustomobject]@{
    status = "SUCCESS"
    provider_used = "mock"
    error = $null
    artifacts = @($artifact)
  }
}
