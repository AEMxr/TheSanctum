Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Get-ReleaseGateSchemaVersion {
  [CmdletBinding()]
  param()
  return "v2.4.0"
}

function ConvertTo-SecretArgArray {
  [CmdletBinding()]
  param(
    [AllowNull()][AllowEmptyString()][string]$RawValue
  )

  if ([string]::IsNullOrWhiteSpace($RawValue)) {
    return @()
  }

  $trimmed = $RawValue.Trim()
  if ($trimmed.StartsWith("[")) {
    try {
      $parsed = $trimmed | ConvertFrom-Json
    }
    catch {
      throw "Secret argument value failed JSON-array parsing: $($_.Exception.Message)"
    }

    if ($null -eq $parsed) { return @() }
    return @($parsed | ForEach-Object { [string]$_ })
  }

  if ($trimmed -match "`r|`n") {
    return @(
      $trimmed -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ }
    )
  }

  return @(
    $trimmed -split "\s+" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { [string]$_ }
  )
}

function Get-OrderedUniqueReleaseGateReasons {
  [CmdletBinding()]
  param(
    [AllowNull()][string[]]$Reasons = @(),
    [AllowNull()][string[]]$ReasonOrder = @(
      "STRICT_VERIFY_FAILED",
      "WRAPPER_BLOCKERS_PRESENT",
      "FALLBACK_ARTIFACTS_PRESENT"
    )
  )

  if ($null -eq $Reasons) { $Reasons = @() }
  if ($null -eq $ReasonOrder) { $ReasonOrder = @() }

  $unique = @($Reasons | Select-Object -Unique)
  return @($ReasonOrder | Where-Object { $unique -contains $_ })
}

Export-ModuleMember -Function `
  Get-ReleaseGateSchemaVersion, `
  ConvertTo-SecretArgArray, `
  Get-OrderedUniqueReleaseGateReasons
