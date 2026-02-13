Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "growth_autopilot.test_env_utils.ps1")
. (Join-Path $PSScriptRoot "growth_autopilot.test_assert_utils.ps1")

Describe "growth autopilot publish ledger compaction" {
  BeforeAll {
    $script:GrowthEnvSnapshot = New-GrowthAutopilotTestEnvSnapshot
    $script:RepoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $script:LedgerLib = Join-Path $script:RepoRoot "scripts\lib\growth_autopilot_ledger.ps1"
    Assert-True -Condition (Test-Path -Path $script:LedgerLib -PathType Leaf) -Message "Missing ledger lib: $script:LedgerLib"
    . $script:LedgerLib
  }

  AfterEach {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  AfterAll {
    Restore-GrowthAutopilotTestEnvSnapshot -Snapshot $script:GrowthEnvSnapshot
  }

  It "prunes entries older than retention cutoff when first_seen_day_utc is present" {
    $errors = New-Object System.Collections.Generic.List[object]
    $entries = @(
      [pscustomobject]@{ dedupe_key = "a"; run_signature = "old"; first_seen_day_utc = "2000-01-01" },
      [pscustomobject]@{ dedupe_key = "b"; run_signature = "old"; first_seen_day_utc = "2099-01-01" },
      [pscustomobject]@{ dedupe_key = "c"; run_signature = "current"; first_seen_day_utc = "2099-01-01" }
    )

    $out = Compact-GrowthPublishLedger -Entries $entries -CurrentRunSignature "current" -RetentionDays 1 -MaxEntries 5000 -Errors $errors
    $keys = @($out | ForEach-Object { [string]$_.dedupe_key })
    Assert-True -Condition (-not ($keys -contains "a")) -Message "Old entry should be pruned."
    Assert-Contains -Collection $keys -Value "b" -Message "Recent entry should remain."
    Assert-Contains -Collection $keys -Value "c" -Message "Current-run entry should remain."
    Assert-Equal -Actual ($keys -join ",") -Expected "b,c" -Message "Output should be sorted by dedupe_key."
  }

  It "enforces max entries keeping current-run entries and selecting newest others" {
    $errors = New-Object System.Collections.Generic.List[object]
    $entries = @(
      [pscustomobject]@{ dedupe_key = "c1"; run_signature = "r1"; first_seen_day_utc = "2099-01-01" },
      [pscustomobject]@{ dedupe_key = "c2"; run_signature = "r1"; first_seen_day_utc = "2099-01-01" },

      [pscustomobject]@{ dedupe_key = "o1"; run_signature = "old"; first_seen_day_utc = "2020-01-01" },
      [pscustomobject]@{ dedupe_key = "o2"; run_signature = "old"; first_seen_day_utc = "2021-01-01" },
      [pscustomobject]@{ dedupe_key = "o3"; run_signature = "old"; first_seen_day_utc = "2022-01-01" }
    )

    $out = Compact-GrowthPublishLedger -Entries $entries -CurrentRunSignature "r1" -RetentionDays 36500 -MaxEntries 3 -Errors $errors
    $keys = @($out | ForEach-Object { [string]$_.dedupe_key })
    Assert-Equal -Actual $keys.Count -Expected 3 -Message "Expected output to honor MaxEntries."
    Assert-Contains -Collection $keys -Value "c1" -Message "Missing current-run entry c1."
    Assert-Contains -Collection $keys -Value "c2" -Message "Missing current-run entry c2."
    Assert-Contains -Collection $keys -Value "o3" -Message "Expected newest non-current entry to be retained."
  }

  It "emits an error when max entries is less than current-run entry count" {
    $errors = New-Object System.Collections.Generic.List[object]
    $entries = @(
      [pscustomobject]@{ dedupe_key = "c1"; run_signature = "r2"; first_seen_day_utc = "2099-01-01" },
      [pscustomobject]@{ dedupe_key = "c2"; run_signature = "r2"; first_seen_day_utc = "2099-01-01" },
      [pscustomobject]@{ dedupe_key = "c3"; run_signature = "r2"; first_seen_day_utc = "2099-01-01" },
      [pscustomobject]@{ dedupe_key = "o1"; run_signature = "old"; first_seen_day_utc = "2022-01-01" }
    )

    $out = Compact-GrowthPublishLedger -Entries $entries -CurrentRunSignature "r2" -RetentionDays 36500 -MaxEntries 2 -Errors $errors
    $keys = @($out | ForEach-Object { [string]$_.dedupe_key })
    Assert-Equal -Actual $keys.Count -Expected 3 -Message "All current-run entries should be retained even if over max."
    Assert-True -Condition ($errors.Count -ge 1) -Message "Expected at least one error emitted."
    $codes = @($errors | ForEach-Object { [string]$_.code })
    Assert-Contains -Collection $codes -Value "publish_ledger_max_entries_exceeded" -Message "Expected publish_ledger_max_entries_exceeded error code."
  }
}
