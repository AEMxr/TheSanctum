# tests/release_gate_helpers.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester tests/release_gate_helpers.Tests.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Assert-True {
  param(
    [bool]$Condition,
    [string]$Message = "Assertion failed."
  )
  if (-not $Condition) { throw $Message }
}

function Assert-Equal {
  param(
    $Actual,
    $Expected,
    [string]$Message = "Values are not equal."
  )
  if ($Actual -ne $Expected) {
    throw "$Message`nExpected: $Expected`nActual: $Actual"
  }
}

function Assert-SequenceEqual {
  param(
    [object[]]$Actual,
    [object[]]$Expected,
    [string]$Message = "Sequences differ."
  )

  if ($Actual.Count -ne $Expected.Count) {
    throw "$Message`nExpected count: $($Expected.Count)`nActual count: $($Actual.Count)"
  }

  for ($i = 0; $i -lt $Actual.Count; $i++) {
    if ([string]$Actual[$i] -ne [string]$Expected[$i]) {
      throw "$Message`nMismatch at index $i`nExpected: $([string]$Expected[$i])`nActual: $([string]$Actual[$i])"
    }
  }
}

Describe "release_gate_helpers module contract" {

  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $script:RepoRoot = Resolve-Path (Join-Path $here "..")
    $modulePath = Join-Path $script:RepoRoot "scripts\lib\release_gate_helpers.psm1"
    if (-not (Test-Path -Path $modulePath -PathType Leaf)) {
      throw "Missing module: $modulePath"
    }
    Import-Module $modulePath -Force
  }

  Context "1) schema version helper" {
    It "returns non-empty schema version string" {
      $v = Get-ReleaseGateSchemaVersion
      Assert-True -Condition (-not [string]::IsNullOrWhiteSpace([string]$v)) -Message "Schema version must be non-empty."
    }

    It "returns expected stamped schema version" {
      $v = Get-ReleaseGateSchemaVersion
      Assert-Equal -Actual ([string]$v) -Expected "v2.4.0" -Message "Schema version stamp mismatch."
    }
  }

  Context "2) secret arg parser" {
    It "returns empty array for blank input" {
      $args = @(ConvertTo-SecretArgArray -RawValue "")
      Assert-Equal -Actual $args.Count -Expected 0 -Message "Blank input should return empty array."
    }

    It "parses JSON array input" {
      $args = @(ConvertTo-SecretArgArray -RawValue '["-h","db.local","-U","svc"]')
      Assert-SequenceEqual -Actual $args -Expected @("-h", "db.local", "-U", "svc") -Message "JSON array parsing mismatch."
    }

    It "parses newline-delimited input" {
      $raw = "-h`nlocalhost`n-U`nsvc"
      $args = @(ConvertTo-SecretArgArray -RawValue $raw)
      Assert-SequenceEqual -Actual $args -Expected @("-h", "localhost", "-U", "svc") -Message "Newline parsing mismatch."
    }

    It "parses whitespace-delimited input" {
      $args = @(ConvertTo-SecretArgArray -RawValue "-h localhost -U svc")
      Assert-SequenceEqual -Actual $args -Expected @("-h", "localhost", "-U", "svc") -Message "Whitespace parsing mismatch."
    }

    It "documents whitespace mode as non-quote-aware tokenization" {
      $raw = '-h "db local" -U svc'
      $args = @(ConvertTo-SecretArgArray -RawValue $raw)
      Assert-SequenceEqual -Actual $args -Expected @("-h", '"db', 'local"', "-U", "svc") -Message "Whitespace mode should remain non-quote-aware unless parser semantics are intentionally changed."
    }

    It "throws on malformed JSON-array input" {
      $threw = $false
      try {
        [void](ConvertTo-SecretArgArray -RawValue '["-h",]')
      }
      catch {
        $threw = $true
      }
      Assert-True -Condition $threw -Message "Malformed JSON array should throw."
    }
  }

  Context "3) ordered reason helper" {
    It "dedupes and enforces fixed reason order" {
      $reasons = @("FALLBACK_ARTIFACTS_PRESENT", "STRICT_VERIFY_FAILED", "STRICT_VERIFY_FAILED")
      $ordered = @(Get-OrderedUniqueReleaseGateReasons -Reasons $reasons)
      Assert-SequenceEqual -Actual $ordered -Expected @("STRICT_VERIFY_FAILED", "FALLBACK_ARTIFACTS_PRESENT") -Message "Reason ordering/dedupe mismatch."
    }
  }

  Context "4) schema stamp drift guard" {
    It "wrapper fallback schema literals match helper single source of truth" {
      $stagingPath = Join-Path $script:RepoRoot "scripts\run_staging_v2_3.ps1"
      $rcPath = Join-Path $script:RepoRoot "scripts\run_release_candidate.ps1"

      Assert-True -Condition (Test-Path -Path $stagingPath -PathType Leaf) -Message "Missing staging wrapper at $stagingPath"
      Assert-True -Condition (Test-Path -Path $rcPath -PathType Leaf) -Message "Missing RC wrapper at $rcPath"

      $stagingRaw = Get-Content -Path $stagingPath -Raw -Encoding UTF8
      $rcRaw = Get-Content -Path $rcPath -Raw -Encoding UTF8
      $pattern = '\$summarySchemaVersion\s*=\s*"([^"]+)"'

      $stagingMatches = [regex]::Matches($stagingRaw, $pattern)
      $rcMatches = [regex]::Matches($rcRaw, $pattern)
      Assert-True -Condition ($stagingMatches.Count -gt 0) -Message "Unable to locate schema fallback literal(s) in run_staging_v2_3.ps1."
      Assert-True -Condition ($rcMatches.Count -gt 0) -Message "Unable to locate schema fallback literal(s) in run_release_candidate.ps1."

      $helperVersion = [string](Get-ReleaseGateSchemaVersion)
      foreach ($m in $stagingMatches) {
        $stagingFallback = [string]$m.Groups[1].Value
        Assert-Equal -Actual $stagingFallback -Expected $helperVersion -Message "Staging fallback schema version drifted from helper."
      }
      foreach ($m in $rcMatches) {
        $rcFallback = [string]$m.Groups[1].Value
        Assert-Equal -Actual $rcFallback -Expected $helperVersion -Message "RC fallback schema version drifted from helper."
      }
    }
  }
}
