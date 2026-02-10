Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Invoke-HttpProvider {
  param(
    [Parameter(Mandatory = $true)][object]$Task,
    [Parameter(Mandatory = $true)][object]$Config
  )

  if ($Config.safe_mode) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "http"
      error = "HTTP provider skipped because safe_mode=true."
      artifacts = @()
    }
  }

  if ($Config.dry_run) {
    return [pscustomobject]@{
      status = "SKIPPED"
      provider_used = "http"
      error = "HTTP provider skipped because dry_run=true in scaffold mode."
      artifacts = @()
    }
  }

  return [pscustomobject]@{
    status = "FAILED"
    provider_used = "http"
    error = "HTTP provider stub is not implemented for live calls in Phase 1 scaffold."
    artifacts = @()
  }
}
