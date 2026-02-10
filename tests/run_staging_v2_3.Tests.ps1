# tests/run_staging_v2_3.Tests.ps1
# Pester 3.x / 5.x compatible
# Run: Invoke-Pester tests/run_staging_v2_3.Tests.ps1

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message = 'Assertion failed.'
    )
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param(
        $Actual,
        $Expected,
        [string]$Message = 'Values are not equal.'
    )
    if ($Actual -ne $Expected) {
        throw "$Message`nExpected: $Expected`nActual: $Actual"
    }
}

function Assert-Contains {
    param(
        [object[]]$Collection,
        $Value,
        [string]$Message = 'Collection does not contain expected value.'
    )
    if (-not ($Collection -contains $Value)) {
        throw "$Message`nExpected value: $Value`nCollection: $([string]::Join(', ', @($Collection)))"
    }
}

function Assert-SequenceEqual {
    param(
        [object[]]$Actual,
        [object[]]$Expected,
        [string]$Message = 'Sequences differ.'
    )

    if ($Actual.Count -ne $Expected.Count) {
        throw "$Message`nExpected count: $($Expected.Count)`nActual count: $($Actual.Count)`nExpected: $($Expected -join ', ')`nActual: $($Actual -join ', ')"
    }

    for ($i = 0; $i -lt $Actual.Count; $i++) {
        if ([string]$Actual[$i] -ne [string]$Expected[$i]) {
            throw "$Message`nMismatch at index $i`nExpected: $([string]$Expected[$i])`nActual: $([string]$Actual[$i])"
        }
    }
}

Describe 'run_staging_v2_3 summary contract' {

    BeforeAll {
        $here = Split-Path -Parent $PSCommandPath
        $root = Resolve-Path (Join-Path $here '..')
        $script:SummaryPath = Join-Path $root 'run_staging_summary.json'

        if (-not (Test-Path -Path $script:SummaryPath -PathType Leaf)) {
            throw "Missing run_staging_summary.json at: $script:SummaryPath"
        }

        $raw = Get-Content -Path $script:SummaryPath -Raw -Encoding UTF8
        $script:Summary = $raw | ConvertFrom-Json
    }

    Context '1) strict_release_gate_ready and release_decision consistency' {
        It 'strict_release_gate_ready equals computed predicate from summary fields' {
            $computed = (
                ($script:Summary.exits.verify_strict -eq 0) -and
                (@($script:Summary.run_blockers).Count -eq 0) -and
                (@($script:Summary.fallback_artifacts).Count -eq 0)
            )
            Assert-Equal -Actual ([bool]$script:Summary.strict_release_gate_ready) -Expected $computed -Message 'strict_release_gate_ready predicate mismatch.'
        }

        It 'release_decision matches strict_release_gate_ready' {
            $expected = if ([bool]$script:Summary.strict_release_gate_ready) { 'PASS' } else { 'FAIL' }
            Assert-Equal -Actual ([string]$script:Summary.release_decision) -Expected $expected -Message 'release_decision mismatch.'
        }

        It 'release_decision is only PASS or FAIL' {
            Assert-Contains -Collection @('PASS', 'FAIL') -Value ([string]$script:Summary.release_decision) -Message 'release_decision must be PASS or FAIL.'
        }
    }

    Context '2) release_gate_reason is ordered and deduped' {
        BeforeAll {
            $script:AllowedOrder = @(
                'STRICT_VERIFY_FAILED',
                'WRAPPER_BLOCKERS_PRESENT',
                'FALLBACK_ARTIFACTS_PRESENT'
            )
            $script:Reasons = @($script:Summary.release_gate_reason)
        }

        It 'contains only known reason tokens' {
            foreach ($r in $script:Reasons) {
                Assert-Contains -Collection $script:AllowedOrder -Value $r -Message 'Unknown release_gate_reason token.'
            }
        }

        It 'contains no duplicates' {
            $uniqueCount = (@($script:Reasons | Select-Object -Unique)).Count
            Assert-Equal -Actual $script:Reasons.Count -Expected $uniqueCount -Message 'release_gate_reason has duplicates.'
        }

        It 'is emitted in fixed order' {
            $expectedOrderedSubset = @(
                $script:AllowedOrder | Where-Object { $script:Reasons -contains $_ }
            )
            Assert-SequenceEqual -Actual @($script:Reasons) -Expected $expectedOrderedSubset -Message 'release_gate_reason ordering mismatch.'
        }

        It 'matches gating facts from summary fields' {
            $expected = @()
            if ($script:Summary.exits.verify_strict -ne 0) { $expected += 'STRICT_VERIFY_FAILED' }
            if (@($script:Summary.run_blockers).Count -gt 0) { $expected += 'WRAPPER_BLOCKERS_PRESENT' }
            if (@($script:Summary.fallback_artifacts).Count -gt 0) { $expected += 'FALLBACK_ARTIFACTS_PRESENT' }
            Assert-SequenceEqual -Actual @($script:Reasons) -Expected $expected -Message 'release_gate_reason does not match summary facts.'
        }
    }

    Context '3) fallback artifacts provenance shape and type allow-list' {
        BeforeAll {
            $script:Fallbacks = @($script:Summary.fallback_artifacts)
            $script:AllowedTypes = @(
                'transport_envelope',
                'synthetic_missing_artifact',
                'derived_failure_output'
            )
        }

        It 'used_fallback_artifacts flag matches actual array count' {
            $expected = ($script:Fallbacks.Count -gt 0)
            Assert-Equal -Actual ([bool]$script:Summary.used_fallback_artifacts) -Expected $expected -Message 'used_fallback_artifacts mismatch.'
        }

        It 'every fallback artifact has required fields when present' {
            foreach ($f in $script:Fallbacks) {
                Assert-True -Condition (([string]$f.artifact).Trim().Length -gt 0) -Message 'fallback artifact missing artifact field.'
                Assert-True -Condition (([string]$f.reason).Trim().Length -gt 0) -Message 'fallback artifact missing reason field.'
                Assert-True -Condition (([string]$f.type).Trim().Length -gt 0) -Message 'fallback artifact missing type field.'
                Assert-True -Condition (([string]$f.generated_at_utc).Trim().Length -gt 0) -Message 'fallback artifact missing generated_at_utc field.'
            }
        }

        It 'every fallback artifact type is in allow-list' {
            foreach ($f in $script:Fallbacks) {
                Assert-Contains -Collection $script:AllowedTypes -Value ([string]$f.type) -Message 'fallback artifact has invalid type.'
            }
        }

        It 'fallback artifact records are unique by artifact name' {
            $names = @($script:Fallbacks | ForEach-Object { [string]$_.artifact })
            Assert-Equal -Actual $names.Count -Expected (@($names | Select-Object -Unique).Count) -Message 'fallback artifact names must be unique.'
        }

        It 'db failure provenance type is derived_failure_output when DB step failed' {
            $dbExit = [int]$script:Summary.exits.db_checks
            $dbFallback = $script:Fallbacks | Where-Object { $_.artifact -eq 'db_verification_results.sql.out' } | Select-Object -First 1

            if ($dbExit -ne 0) {
                Assert-True -Condition ($null -ne $dbFallback) -Message 'DB step failed but DB fallback artifact is missing.'
                Assert-Equal -Actual ([string]$dbFallback.type) -Expected 'derived_failure_output' -Message 'DB fallback type must be derived_failure_output when DB step fails.'
            }
        }
    }

    Context '4) release decision all-of invariant' {
        It 'PASS decision implies strict gate readiness and zero blockers/fallbacks' {
            if ([string]$script:Summary.release_decision -eq 'PASS') {
                Assert-Equal -Actual ([bool]$script:Summary.strict_release_gate_ready) -Expected $true -Message 'PASS requires strict_release_gate_ready=true.'
                Assert-Equal -Actual (@($script:Summary.release_gate_reason).Count) -Expected 0 -Message 'PASS requires empty release_gate_reason.'
                Assert-Equal -Actual ([bool]$script:Summary.used_fallback_artifacts) -Expected $false -Message 'PASS requires used_fallback_artifacts=false.'
                Assert-Equal -Actual (@($script:Summary.run_blockers).Count) -Expected 0 -Message 'PASS requires no run_blockers.'
                Assert-Equal -Actual ([int]$script:Summary.exits.verify_strict) -Expected 0 -Message 'PASS requires exits.verify_strict=0.'
            }
        }

        It 'FAIL decision implies at least one failing gate condition' {
            if ([string]$script:Summary.release_decision -eq 'FAIL') {
                $hasStrictFailure = ([int]$script:Summary.exits.verify_strict -ne 0)
                $hasRunBlockers = (@($script:Summary.run_blockers).Count -gt 0)
                $hasFallbacks = ([bool]$script:Summary.used_fallback_artifacts)
                $hasReleaseReasons = (@($script:Summary.release_gate_reason).Count -gt 0)
                $hasAnyFailCondition = ($hasStrictFailure -or $hasRunBlockers -or $hasFallbacks -or $hasReleaseReasons)

                Assert-True -Condition $hasAnyFailCondition -Message 'FAIL requires at least one failing gate condition.'
            }
        }
    }

    Context '5) v2.4 release semantics hardening' {
        It 'FAIL decision requires non-empty release_gate_reason' {
            if ([string]$script:Summary.release_decision -eq 'FAIL') {
                Assert-True -Condition (@($script:Summary.release_gate_reason).Count -gt 0) -Message 'FAIL requires non-empty release_gate_reason.'
            }
        }

        It 'release_decision and strict_release_gate_ready match modeled wrapper exit behavior' {
            $modeledWrapperExit = if (
                ([int]$script:Summary.exits.verify_strict -ne 0) -or
                (@($script:Summary.run_blockers).Count -gt 0) -or
                ([bool]$script:Summary.used_fallback_artifacts)
            ) { 1 } else { 0 }

            $expectedDecision = if ($modeledWrapperExit -eq 0) { 'PASS' } else { 'FAIL' }
            $expectedStrictReady = ($modeledWrapperExit -eq 0)

            Assert-Equal -Actual ([string]$script:Summary.release_decision) -Expected $expectedDecision -Message 'release_decision diverges from modeled wrapper exit behavior.'
            Assert-Equal -Actual ([bool]$script:Summary.strict_release_gate_ready) -Expected $expectedStrictReady -Message 'strict_release_gate_ready diverges from modeled wrapper exit behavior.'
        }
    }

    Context '6) summary schema compatibility' {
        BeforeAll {
            $script:SupportedSummarySchemas = @{
                'v2.4.0-draft1' = @(
                    'summary_schema_version',
                    'release_decision',
                    'strict_release_gate_ready',
                    'release_gate_reason',
                    'used_fallback_artifacts',
                    'fallback_artifacts',
                    'exits',
                    'run_blockers'
                )
                'v2.4.0' = @(
                    'summary_schema_version',
                    'release_decision',
                    'strict_release_gate_ready',
                    'release_gate_reason',
                    'used_fallback_artifacts',
                    'fallback_artifacts',
                    'exits',
                    'run_blockers'
                )
                'v2.4.1' = @(
                    'summary_schema_version',
                    'release_decision',
                    'strict_release_gate_ready',
                    'release_gate_reason',
                    'used_fallback_artifacts',
                    'fallback_artifacts',
                    'exits',
                    'run_blockers'
                )
            }
        }

        It 'summary_schema_version is present and supported' {
            Assert-True -Condition ($script:Summary.PSObject.Properties.Name -contains 'summary_schema_version') -Message 'Missing required field: summary_schema_version'
            $schemaVersion = ([string]$script:Summary.summary_schema_version).Trim()
            Assert-True -Condition (-not [string]::IsNullOrWhiteSpace($schemaVersion)) -Message 'summary_schema_version must be non-empty.'

            Assert-True -Condition $script:SupportedSummarySchemas.ContainsKey($schemaVersion) -Message "Unsupported summary_schema_version '$schemaVersion'. Add compatibility mapping before changing schema."
        }

        It 'summary schema required fields are present per compatibility map' {
            $schemaVersion = ([string]$script:Summary.summary_schema_version).Trim()
            if ($script:SupportedSummarySchemas.ContainsKey($schemaVersion)) {
                $required = @($script:SupportedSummarySchemas[$schemaVersion])
                foreach ($name in $required) {
                    Assert-True -Condition ($script:Summary.PSObject.Properties.Name -contains $name) -Message "$schemaVersion missing required field: $name"
                }
            }
        }
    }
}
