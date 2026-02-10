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

if ($hasFailures) {
  exit 1
}

Write-Host "PASS"
Write-Host "All changed files are within task scope."
exit 0
