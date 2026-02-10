param(
  [Parameter(Mandatory = $true)][string]$TaskFile,
  [Parameter(Mandatory = $true)][string[]]$ChangedFiles
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

if (-not (Test-Path -Path $TaskFile -PathType Leaf)) {
  Write-Error "Task file not found: $TaskFile"
  exit 2
}

$lines = Get-Content -Path $TaskFile
$scopeStart = -1
$scopeEnd = $lines.Count
for ($i = 0; $i -lt $lines.Count; $i++) {
  if ($lines[$i] -match '^##\s+Scope\b') {
    $scopeStart = $i
    continue
  }
  if ($scopeStart -ge 0 -and $i -gt $scopeStart -and $lines[$i] -match '^##\s+') {
    $scopeEnd = $i
    break
  }
}

if ($scopeStart -lt 0) {
  Write-Error "Unable to locate Scope section in task file: $TaskFile"
  exit 2
}

$allowed = New-Object System.Collections.Generic.List[string]
for ($i = $scopeStart + 1; $i -lt $scopeEnd; $i++) {
  $line = $lines[$i].Trim()
  if ($line -match '^[-*]\s+(.+)$') {
    $entry = $matches[1].Trim()
    $entry = $entry -replace '`', ''
    $entry = $entry -replace '\s+\(.*\)\s*$', ''
    if (-not [string]::IsNullOrWhiteSpace($entry)) {
      [void]$allowed.Add(($entry -replace '\\', '/'))
    }
  }
}

if ($allowed.Count -eq 0) {
  Write-Error "No allowed scope entries found in task file: $TaskFile"
  exit 2
}

$invalidScopeEntries = New-Object System.Collections.Generic.List[string]
foreach ($rule in $allowed) {
  if ([string]::IsNullOrWhiteSpace($rule)) { continue }

  if ($rule.Contains('*')) {
    # Wildcard patterns are intentionally allowed without existence checks.
    continue
  }

  $literal = $rule.Trim()
  if ($literal.EndsWith('/')) {
    $literal = $literal.TrimEnd('/')
  }

  if ([string]::IsNullOrWhiteSpace($literal)) {
    continue
  }

  if (-not (Test-Path -Path $literal -PathType Any)) {
    [void]$invalidScopeEntries.Add($rule)
  }
}

$requiredTaskSections = @(
  "## Objective lane",
  "## Goal (single measurable outcome)",
  "## Scope (allowed files)",
  "## Non-goals",
  "## Acceptance checklist",
  "## Deliverables (SHA, diff summary)",
  "## Rollback anchor",
  "## Execution notes"
)

$taskCardCompletenessErrors = New-Object System.Collections.Generic.List[string]
foreach ($file in $ChangedFiles) {
  $normalized = $file -replace '\\', '/'
  if ($normalized -notmatch '^docs/tasks/TASK-[^/]+\.md$') { continue }
  if (-not (Test-Path -Path $file -PathType Leaf)) { continue }

  $taskLines = Get-Content -Path $file
  $missingSections = New-Object System.Collections.Generic.List[string]
  foreach ($section in $requiredTaskSections) {
    $pattern = '^\s*' + [regex]::Escape($section) + '\s*$'
    if (-not ($taskLines | Where-Object { $_ -match $pattern })) {
      [void]$missingSections.Add($section)
    }
  }

  if ($missingSections.Count -gt 0) {
    [void]$taskCardCompletenessErrors.Add("$file => missing sections: $($missingSections -join '; ')")
  }
}

$sessionLogIntegrityErrors = New-Object System.Collections.Generic.List[string]
foreach ($file in $ChangedFiles) {
  $normalized = $file -replace '\\', '/'
  if ($normalized -ne 'docs/session_log.md') { continue }
  if (-not (Test-Path -Path $file -PathType Leaf)) { continue }

  $logLines = Get-Content -Path $file
  $entriesHeaderIndex = -1
  for ($i = 0; $i -lt $logLines.Count; $i++) {
    if ($logLines[$i].Trim() -eq '## Entries') {
      $entriesHeaderIndex = $i
      break
    }
  }
  if ($entriesHeaderIndex -lt 0) {
    [void]$sessionLogIntegrityErrors.Add("$file => missing '## Entries' section")
    continue
  }

  $entryStarts = New-Object System.Collections.Generic.List[int]
  for ($i = $entriesHeaderIndex + 1; $i -lt $logLines.Count; $i++) {
    if ($logLines[$i] -match '^\s*-\s+Date/Time:\s*(.+)\s*$') {
      [void]$entryStarts.Add($i)
    }
  }

  foreach ($start in $entryStarts) {
    $entryLabel = if ($logLines[$start] -match '^\s*-\s+Date/Time:\s*(.+)\s*$') { $matches[1].Trim() } else { "unknown" }
    $end = $logLines.Count
    foreach ($candidate in $entryStarts) {
      if ($candidate -gt $start) {
        $end = $candidate
        break
      }
    }

    $nextCommandLine = -1
    $inlineValue = ""
    for ($i = $start; $i -lt $end; $i++) {
      if ($logLines[$i] -match '^\s*-\s+Next first command:\s*(.*)$') {
        $nextCommandLine = $i
        $inlineValue = $matches[1].Trim()
        break
      }
    }

    if ($nextCommandLine -lt 0) {
      [void]$sessionLogIntegrityErrors.Add("$file => entry '$entryLabel' missing 'Next first command:' line")
      continue
    }

    if (-not [string]::IsNullOrWhiteSpace($inlineValue)) {
      continue
    }

    $hasIndentedCommand = $false
    for ($i = $nextCommandLine + 1; $i -lt $end; $i++) {
      $line = $logLines[$i]
      if ($line -match '^\s*-\s+[A-Za-z][^:]*:') {
        break
      }
      if ($line -match '^\s{2,}\S+') {
        $hasIndentedCommand = $true
        break
      }
    }

    if (-not $hasIndentedCommand) {
      [void]$sessionLogIntegrityErrors.Add("$file => entry '$entryLabel' has blank 'Next first command:' value")
    }
  }
}

function Test-InScope {
  param(
    [string]$Path,
    [string[]]$Allowed
  )

  $normalized = $Path -replace '\\', '/'
  foreach ($rule in $Allowed) {
    if ([string]::IsNullOrWhiteSpace($rule)) { continue }
    if ($rule.EndsWith('/')) {
      if ($normalized.StartsWith($rule, [System.StringComparison]::OrdinalIgnoreCase)) {
        return $true
      }
      continue
    }
    if ($rule.Contains('*')) {
      if ($normalized -like $rule) { return $true }
      continue
    }
    if ($normalized.Equals($rule, [System.StringComparison]::OrdinalIgnoreCase)) {
      return $true
    }
  }
  return $false
}

$checklistDuplicateErrors = New-Object System.Collections.Generic.List[string]
foreach ($file in $ChangedFiles) {
  $normalized = $file -replace '\\', '/'
  if ($normalized -notmatch '^docs/checklists/.+\.md$') { continue }
  if (-not (Test-Path -Path $file -PathType Leaf)) { continue }

  $checklistLines = Get-Content -Path $file
  $seen = @{}
  foreach ($line in $checklistLines) {
    $trimmed = $line.Trim()
    if ($trimmed -match '^-\s+\[(?:\s|x|X)\]\s+(.+)$') {
      $itemText = ($matches[1].Trim() -replace '\s+', ' ').ToLowerInvariant()
      if ($seen.ContainsKey($itemText)) {
        [void]$checklistDuplicateErrors.Add("$file => $($matches[1].Trim())")
      }
      else {
        $seen[$itemText] = $true
      }
    }
  }
}

$hasFailures = $false
$offending = New-Object System.Collections.Generic.List[string]
foreach ($file in $ChangedFiles) {
  if (-not (Test-InScope -Path $file -Allowed @($allowed))) {
    [void]$offending.Add($file)
  }
}

if ($offending.Count -gt 0) {
  $hasFailures = $true
  Write-Host "FAIL"
  Write-Host "Out-of-scope changed files:"
  foreach ($path in $offending) {
    Write-Host " - $path"
  }
}

if ($checklistDuplicateErrors.Count -gt 0) {
  $hasFailures = $true
  if ($offending.Count -eq 0) {
    Write-Host "FAIL"
  }
  Write-Host "Duplicate checklist entries detected:"
  foreach ($dup in $checklistDuplicateErrors) {
    Write-Host " - $dup"
  }
}

if ($invalidScopeEntries.Count -gt 0) {
  $hasFailures = $true
  if ($offending.Count -eq 0 -and $checklistDuplicateErrors.Count -eq 0) {
    Write-Host "FAIL"
  }
  Write-Host "Invalid scope entries detected (literal paths not found):"
  foreach ($entry in $invalidScopeEntries) {
    Write-Host " - $entry"
  }
}

if ($taskCardCompletenessErrors.Count -gt 0) {
  $hasFailures = $true
  if ($offending.Count -eq 0 -and $checklistDuplicateErrors.Count -eq 0 -and $invalidScopeEntries.Count -eq 0) {
    Write-Host "FAIL"
  }
  Write-Host "Incomplete task cards detected:"
  foreach ($err in $taskCardCompletenessErrors) {
    Write-Host " - $err"
  }
}

if ($sessionLogIntegrityErrors.Count -gt 0) {
  $hasFailures = $true
  if ($offending.Count -eq 0 -and $checklistDuplicateErrors.Count -eq 0 -and $invalidScopeEntries.Count -eq 0 -and $taskCardCompletenessErrors.Count -eq 0) {
    Write-Host "FAIL"
  }
  Write-Host "Session log integrity violations detected:"
  foreach ($err in $sessionLogIntegrityErrors) {
    Write-Host " - $err"
  }
}

if ($hasFailures) {
  exit 1
}

Write-Host "PASS"
Write-Host "All changed files are within task scope."
exit 0
