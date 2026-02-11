# apps/core/tests/trend_aggregator.Tests.ps1
# Pester 3.x / 5.x compatible

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

function Assert-Contains {
  param(
    [object[]]$Collection,
    $Value,
    [string]$Message = "Collection does not contain expected value."
  )
  if (-not ($Collection -contains $Value)) {
    throw "$Message`nExpected value: $Value"
  }
}

Describe "cross-language trend aggregator" {
  BeforeAll {
    $here = Split-Path -Parent $PSCommandPath
    $coreRoot = Resolve-Path (Join-Path $here "..")
    $script:AggregatorPath = Join-Path $coreRoot "telemetry/trend_aggregator.ps1"

    if (-not (Test-Path -Path $script:AggregatorPath -PathType Leaf)) {
      throw "Missing aggregator script: $script:AggregatorPath"
    }

    . $script:AggregatorPath
  }

  Context "schema contract" {
    It "schema includes language_code, region_code, geo_coarse fields" {
      $schema = Get-TrendEventSchema
      Assert-Contains -Collection @($schema.required_fields) -Value "language_code" -Message "Schema missing language_code."
      Assert-Contains -Collection @($schema.required_fields) -Value "region_code" -Message "Schema missing region_code."
      Assert-Contains -Collection @($schema.required_fields) -Value "geo_coarse" -Message "Schema missing geo_coarse."
    }
  }

  Context "segmented aggregation behavior" {
    It "outputs conversion metrics by language_code, offer_tier, channel" {
      $events = @(
        [pscustomobject]@{ event_id = "e1"; event_type = "impression"; timestamp_utc = "2026-02-11T00:00:00Z"; campaign_id = "c1"; channel = "reddit"; offer_tier = "pro"; language_code = "en-US"; region_code = "US"; geo_coarse = "US-CA" },
        [pscustomobject]@{ event_id = "e2"; event_type = "click_cta_buy"; timestamp_utc = "2026-02-11T00:01:00Z"; campaign_id = "c1"; channel = "reddit"; offer_tier = "pro"; language_code = "en-US"; region_code = "US"; geo_coarse = "US-CA" },
        [pscustomobject]@{ event_id = "e3"; event_type = "purchase_complete"; timestamp_utc = "2026-02-11T00:02:00Z"; campaign_id = "c1"; channel = "reddit"; offer_tier = "pro"; language_code = "en-US"; region_code = "US"; geo_coarse = "US-CA" },
        [pscustomobject]@{ event_id = "e4"; event_type = "impression"; timestamp_utc = "2026-02-11T01:00:00Z"; campaign_id = "c2"; channel = "reddit"; offer_tier = "pro"; language_code = "es-MX"; region_code = "MX"; geo_coarse = "MX-CMX" },
        [pscustomobject]@{ event_id = "e5"; event_type = "click_cta_subscribe"; timestamp_utc = "2026-02-11T01:01:00Z"; campaign_id = "c2"; channel = "reddit"; offer_tier = "pro"; language_code = "es-MX"; region_code = "MX"; geo_coarse = "MX-CMX" }
      )

      $summary = Get-LanguageSegmentedTrendMetrics -Events $events
      $segments = @($summary.segments)
      Assert-Equal -Actual $segments.Count -Expected 2 -Message "Expected two language segments."

      $en = @($segments | Where-Object { $_.language_code -eq "en" -and $_.offer_tier -eq "pro" -and $_.channel -eq "reddit" } | Select-Object -First 1)
      $es = @($segments | Where-Object { $_.language_code -eq "es" -and $_.offer_tier -eq "pro" -and $_.channel -eq "reddit" } | Select-Object -First 1)

      Assert-Equal -Actual $en.Count -Expected 1 -Message "Expected one english segment."
      Assert-Equal -Actual $es.Count -Expected 1 -Message "Expected one spanish segment."

      Assert-Equal -Actual ([int]$en[0].counts.impressions) -Expected 1 -Message "English impressions mismatch."
      Assert-Equal -Actual ([int]$en[0].counts.purchase_complete) -Expected 1 -Message "English purchase count mismatch."
      Assert-Equal -Actual ([int]$en[0].metrics.conversion_bps) -Expected 10000 -Message "English conversion_bps mismatch."

      Assert-Equal -Actual ([int]$es[0].counts.impressions) -Expected 1 -Message "Spanish impressions mismatch."
      Assert-Equal -Actual ([int]$es[0].counts.click_cta_subscribe) -Expected 1 -Message "Spanish subscribe click count mismatch."
      Assert-Equal -Actual ([int]$es[0].metrics.ctr_bps) -Expected 10000 -Message "Spanish ctr_bps mismatch."
    }

    It "remains deterministic for repeated same dataset" {
      $events = @(
        [pscustomobject]@{ event_id = "e1"; event_type = "impression"; timestamp_utc = "2026-02-11T00:00:00Z"; campaign_id = "c1"; channel = "x"; offer_tier = "starter"; language_code = "fr-FR"; region_code = "FR"; geo_coarse = "FR-IDF" },
        [pscustomobject]@{ event_id = "e2"; event_type = "click_cta_buy"; timestamp_utc = "2026-02-11T00:01:00Z"; campaign_id = "c1"; channel = "x"; offer_tier = "starter"; language_code = "fr-FR"; region_code = "FR"; geo_coarse = "FR-IDF" }
      )

      $a = Get-LanguageSegmentedTrendMetrics -Events $events
      $b = Get-LanguageSegmentedTrendMetrics -Events $events

      $aNormalized = [pscustomobject]@{
        schema_version = $a.schema_version
        grouping_key = @($a.grouping_key)
        segments = @($a.segments)
        reason_codes = @($a.reason_codes)
      }
      $bNormalized = [pscustomobject]@{
        schema_version = $b.schema_version
        grouping_key = @($b.grouping_key)
        segments = @($b.segments)
        reason_codes = @($b.reason_codes)
      }

      Assert-Equal -Actual ($aNormalized | ConvertTo-Json -Depth 20 -Compress) -Expected ($bNormalized | ConvertTo-Json -Depth 20 -Compress) -Message "Repeated dataset should produce deterministic segmented output."
    }
  }
}
