param(
  [string[]]$RequiredArtifacts = @(
    "run_staging_summary.json",
    "run_release_candidate_summary.json",
    "artifacts/toolchain_manifest.txt"
  )
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

foreach ($artifact in $RequiredArtifacts) {
  if (-not (Test-Path -Path $artifact -PathType Leaf)) {
    Write-Host "::error::Missing required evidence artifact: $artifact"
    throw "Missing required evidence artifact: $artifact"
  }
  Write-Host "Evidence artifact present: $artifact"
}
