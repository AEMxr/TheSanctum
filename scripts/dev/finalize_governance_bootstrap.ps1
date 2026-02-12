param(
  [string]$Repo = "AEMxr/TheSanctum",
  [Parameter(Mandatory=$true)][string]$SecondApprover,
  [string]$GhExe = "D:\tools\gh-cli\gh_2.86.0\bin\gh.exe"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$SecondApprover = $SecondApprover.Trim().ToLowerInvariant()

function Invoke-Gh {
  param(
    [Parameter(Mandatory=$true)][string[]]$Args,
    [switch]$Capture
  )
  if ($Capture) {
    $out = & $GhExe @Args 2>&1
    if ($LASTEXITCODE -ne 0) { throw "gh failed: gh $($Args -join ' ')`n$out" }
    return ($out -join "`n")
  } else {
    & $GhExe @Args
    if ($LASTEXITCODE -ne 0) { throw "gh failed: gh $($Args -join ' ')" }
  }
}

function Get-Pr {
  param([int]$Number)
  $raw = Invoke-Gh -Capture -Args @(
    "pr","view",[string]$Number,
    "--repo",$Repo,
    "--json","number,state,headRefName,reviewDecision,mergeStateStatus,statusCheckRollup,labels,url"
  )
  return ($raw | ConvertFrom-Json)
}

# Step 0: approver allowlist
Invoke-Gh -Args @(
  "api","--method","PATCH","repos/$Repo/actions/variables/GOVERNANCE_APPROVERS",
  "-f","name=GOVERNANCE_APPROVERS",
  "-f","value=aemxr,$SecondApprover"
)
Write-Host "Updated GOVERNANCE_APPROVERS -> aemxr,$SecondApprover"

# Step 2: rerun exception gate if needed (dynamic PR #7 branch)
$pr7 = Get-Pr -Number 7
if ($pr7.state -eq "MERGED") {
  Write-Host "PR #7 already merged; skipping Step 2 rerun/check."
} else {
  $excBranch = [string]$pr7.headRefName
  if ([string]::IsNullOrWhiteSpace($excBranch)) { throw "PR #7 headRefName missing." }

  $runsRaw = Invoke-Gh -Capture -Args @(
    "run","list","--repo",$Repo,
    "--workflow","hardening-pr-gate",
    "--branch",$excBranch,
    "--limit","1",
    "--json","databaseId,conclusion,status"
  )
  $runs = $runsRaw | ConvertFrom-Json
  if (@($runs).Count -eq 0) { throw "No hardening-pr-gate runs found for branch $excBranch." }

  $runId = [string]$runs[0].databaseId
  $conclusion = [string]$runs[0].conclusion

  if ($conclusion -ne "success") {
    Write-Host "Re-running exception gate run_id=$runId (current=$conclusion)"
    Invoke-Gh -Args @("run","rerun",$runId,"--repo",$Repo)
    Invoke-Gh -Args @("run","watch",$runId,"--repo",$Repo)
  }

  Invoke-Gh -Args @("pr","checks","7","--repo",$Repo,"--watch")
}

# Step 3: merge order 8 -> 6 -> 7 (idempotent)
foreach ($prNum in 8,6,7) {
  $pr = Get-Pr -Number $prNum
  if ($pr.state -eq "MERGED") {
    Write-Host "PR #$prNum already merged; skipping."
    continue
  }

  Invoke-Gh -Args @("pr","checks",[string]$prNum,"--repo",$Repo,"--watch")
  Invoke-Gh -Args @("pr","merge",[string]$prNum,"--repo",$Repo,"--merge","--delete-branch")
  Write-Host "Merged PR #$prNum"
}

# Step 4: run governance bootstrap audit workflow
$dispatchStart = [DateTime]::UtcNow

Invoke-Gh -Args @(
  "workflow","run","governance-bootstrap-audit.yml",
  "--repo",$Repo,
  "--ref","main",
  "-f","second_approver=$SecondApprover",
  "-f","pr_standard=6",
  "-f","pr_exception=7"
)

# Find the run that was just dispatched (avoid grabbing older one)
$auditRunId = $null
for ($i=0; $i -lt 30; $i++) {
  Start-Sleep -Seconds 2
  $auditRunsRaw = Invoke-Gh -Capture -Args @(
    "run","list","--repo",$Repo,
    "--workflow","governance-bootstrap-audit",
    "--limit","10",
    "--json","databaseId,createdAt,headBranch,event,status,conclusion"
  )
  $auditRuns = $auditRunsRaw | ConvertFrom-Json

  $candidate = @($auditRuns | Where-Object {
      $_.event -eq "workflow_dispatch" -and
      $_.headBranch -eq "main" -and
      ([DateTime]::Parse($_.createdAt).ToUniversalTime() -ge $dispatchStart.AddMinutes(-1))
    } | Sort-Object {[DateTime]::Parse($_.createdAt)} -Descending)[0]

  if ($null -ne $candidate) {
    $auditRunId = [string]$candidate.databaseId
    break
  }
}
if ([string]::IsNullOrWhiteSpace($auditRunId)) { throw "No governance-bootstrap-audit run found after dispatch." }

Invoke-Gh -Args @("run","watch",$auditRunId,"--repo",$Repo)
New-Item -ItemType Directory -Force -Path "artifacts/governance/downloaded" | Out-Null
Invoke-Gh -Args @(
  "run","download",$auditRunId,
  "--repo",$Repo,
  "-n","governance-bootstrap-audit",
  "-D","artifacts/governance/downloaded"
)

# Step 5: final enforcement proof
Invoke-Gh -Args @("api","repos/$Repo/branches/main/protection")
Invoke-Gh -Args @("run","list","--repo",$Repo,"--workflow","hardening-pr-gate","--limit","5")

Write-Host "`nALL DONE: governance bootstrap sequence completed."
