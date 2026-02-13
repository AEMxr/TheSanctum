Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "growth_autopilot.test_assert_utils.ps1")

function Get-FileAst {
  param([Parameter(Mandatory = $true)][string]$Path)

  $tokens = $null
  $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($Path, [ref]$tokens, [ref]$errors)

  if ($null -ne $errors -and $errors.Count -gt 0) {
    $msg = @($errors | ForEach-Object { $_.Message }) -join "; "
    throw ("Parse error in {0}: {1}" -f $Path, $msg)
  }

  return $ast
}

Describe "growth autopilot test conventions" {
  It "does not reintroduce local Assert-* helpers outside the shared helper file" {
    $repoRoot = Resolve-Path (Join-Path $PSScriptRoot "..\..")
    $integrationDir = Join-Path $repoRoot "tests\integration"

    $allowed = @(
      (Join-Path $integrationDir "growth_autopilot.test_assert_utils.ps1")
    ) | ForEach-Object { (Resolve-Path $_).Path }

    $targets = New-Object System.Collections.Generic.List[string]
    [void]$targets.Add((Resolve-Path (Join-Path $repoRoot "tests\growth_autopilot.smoke.Tests.ps1")).Path)

    foreach ($f in @(Get-ChildItem -Path $integrationDir -File -Filter "growth_autopilot*.Tests.ps1")) {
      [void]$targets.Add($f.FullName)
    }

    $forbidden = @(
      "Assert-True",
      "Assert-Equal",
      "Assert-Contains",
      "Assert-NotContainsText",
      "Get-StableHash"
    )

    $violations = New-Object System.Collections.Generic.List[string]

    foreach ($path in @($targets | Sort-Object -Unique)) {
      $resolved = (Resolve-Path $path).Path
      if ($allowed -contains $resolved) { continue }

      $ast = Get-FileAst -Path $resolved
      $funcs = @($ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
      foreach ($fn in $funcs) {
        if ($forbidden -contains [string]$fn.Name) {
          $where = "{0}:{1}:{2}" -f $resolved, $fn.Extent.StartLineNumber, $fn.Name
          [void]$violations.Add($where)
        }
      }
    }

    if ($violations.Count -gt 0) {
      throw ("Local helper definitions reintroduced (must live only in tests/integration/growth_autopilot.test_assert_utils.ps1):`n{0}" -f ($violations -join "`n"))
    }
  }
}
