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

$offending = New-Object System.Collections.Generic.List[string]
foreach ($file in $ChangedFiles) {
  if (-not (Test-InScope -Path $file -Allowed @($allowed))) {
    [void]$offending.Add($file)
  }
}

if ($offending.Count -gt 0) {
  Write-Host "FAIL"
  Write-Host "Out-of-scope changed files:"
  foreach ($path in $offending) {
    Write-Host " - $path"
  }
  exit 1
}

Write-Host "PASS"
Write-Host "All changed files are within task scope."
exit 0
