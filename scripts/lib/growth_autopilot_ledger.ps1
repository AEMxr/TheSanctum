Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Compact-GrowthPublishLedger {
  param(
    [Parameter(Mandatory = $true)][AllowEmptyCollection()][object[]]$Entries,
    [Parameter(Mandatory = $true)][string]$CurrentRunSignature,
    [int]$RetentionDays = 30,
    [int]$MaxEntries = 5000,
    [object]$Errors
  )

  $retentionDaysInt = 30
  if ($RetentionDays -ge 0) { $retentionDaysInt = [int]$RetentionDays }
  $maxEntriesInt = 5000
  if ($MaxEntries -gt 0) { $maxEntriesInt = [int]$MaxEntries }

  $filtered = New-Object System.Collections.Generic.List[object]
  $cutoff = $null
  if ($retentionDaysInt -gt 0) {
    $cutoff = (Get-Date).ToUniversalTime().Date.AddDays(-$retentionDaysInt)
  }

  foreach ($e in @($Entries)) {
    if ($null -eq $e) { continue }
    if ($null -eq $cutoff) {
      [void]$filtered.Add($e)
      continue
    }

    $keep = $true
    if ($e.PSObject.Properties.Name -contains "first_seen_day_utc") {
      $d = [datetime]::MinValue
      if ([datetime]::TryParse([string]$e.first_seen_day_utc, [ref]$d)) {
        $d = $d.ToUniversalTime().Date
        if ($d -lt $cutoff) { $keep = $false }
      }
    }
    if ($keep) { [void]$filtered.Add($e) }
  }

  $current = @($filtered | Where-Object { [string]$_.run_signature -eq $CurrentRunSignature })
  $others = @($filtered | Where-Object { [string]$_.run_signature -ne $CurrentRunSignature })

  $slots = $maxEntriesInt - @($current).Count
  $keptOthers = @()
  if ($slots -le 0) {
    if ($null -ne $Errors) {
      try {
        [void]$Errors.Add([pscustomobject]@{
          code = "publish_ledger_max_entries_exceeded"
          detail = "publish_ledger_max_entries is less than current-run ledger entries; retaining current-run entries and dropping older entries."
        })
      } catch {}
    }
  }
  else {
    $keptOthers = @(
      $others |
        Sort-Object -Property `
          @{ Expression = {
              $d = [datetime]::MinValue
              if ($_.PSObject.Properties.Name -contains "first_seen_day_utc") {
                [void][datetime]::TryParse([string]$_.first_seen_day_utc, [ref]$d)
                $d = $d.ToUniversalTime().Date
              }
              $d
            } },
          @{ Expression = { [string]$_.dedupe_key } } |
        Select-Object -Last $slots
    )
  }

  $combined = @($current + $keptOthers)
  return @(
    $combined |
      Sort-Object -Property @{ Expression = { [string]$_.dedupe_key } }
  )
}

