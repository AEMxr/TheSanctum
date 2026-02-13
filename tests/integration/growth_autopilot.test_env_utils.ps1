function New-GrowthAutopilotTestEnvSnapshot {
  param(
    [string]$Prefix = "SANCTUM_GROWTH_"
  )

  $values = @{}

  foreach ($e in @(Get-ChildItem env: | Where-Object { $_.Name -like ($Prefix + "*") } | Sort-Object Name)) {
    $values[[string]$e.Name] = [string]$e.Value
  }

  return [pscustomobject]@{
    prefix = $Prefix
    values = $values
  }
}

function Restore-GrowthAutopilotTestEnvSnapshot {
  param(
    [Parameter(Mandatory = $true)]$Snapshot
  )

  $prefix = [string]$Snapshot.prefix
  $values = $Snapshot.values
  if ($null -eq $values) { $values = @{} }

  $currentNames = @(
    Get-ChildItem env: |
      Where-Object { $_.Name -like ($prefix + "*") } |
      ForEach-Object { [string]$_.Name }
  )

  foreach ($name in $currentNames) {
    if (-not $values.ContainsKey($name)) {
      [Environment]::SetEnvironmentVariable($name, $null, "Process")
    }
  }

  foreach ($name in @($values.Keys)) {
    [Environment]::SetEnvironmentVariable($name, [string]$values[$name], "Process")
  }
}

