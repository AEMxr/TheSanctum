-- HG-MoE Telemetry Pack v2.1
-- Canonical grain: daily UTC
-- Canonical windows: trailing 7d and trailing 30d
--
-- This pack defines:
-- 1) material_action_without_valid_nonce
-- 2) boundary_respect_rate
-- 3) policy_check_failure_rate
-- 4) council_disagreement_entropy
-- 5) override_rate_by_domain
-- 6) nonce_misuse_events
-- 7) onboarding_completion_rate
--
-- Expected core tables:
-- - decision_records
-- - consent_nonces
-- - event_log
-- - onboarding_status

CREATE SCHEMA IF NOT EXISTS telemetry;

-- Safe JSON parser for text-backed JSON payloads.
CREATE OR REPLACE FUNCTION telemetry.try_parse_jsonb(p_text text)
RETURNS jsonb
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN COALESCE(p_text::jsonb, '{}'::jsonb);
EXCEPTION
  WHEN others THEN
    RETURN '{}'::jsonb;
END;
$$;

-- Safe boolean parser with fallback.
CREATE OR REPLACE FUNCTION telemetry.try_parse_bool(p_text text, p_default boolean DEFAULT true)
RETURNS boolean
LANGUAGE plpgsql
IMMUTABLE
AS $$
BEGIN
  RETURN COALESCE(p_text::boolean, p_default);
EXCEPTION
  WHEN others THEN
    RETURN p_default;
END;
$$;

DROP VIEW IF EXISTS telemetry.v_decision_base CASCADE;
CREATE VIEW telemetry.v_decision_base AS
SELECT
  dr.record_id,
  dr.user_stable_id,
  dr.domain,
  timezone('UTC', dr.timestamp)::date AS day_utc,
  dr.timestamp,
  dr.actionability,
  dr.user_override,
  dr.session_id,
  dr.recommendation_id,
  dr.consent_nonce,
  COALESCE(
    UPPER(NULLIF(s.synth->>'final_position', '')),
    UPPER(NULLIF(s.synth->>'position', '')),
    ''
  ) AS final_position,
  CASE
    WHEN jsonb_typeof(s.synth->'final_risks') = 'array' THEN s.synth->'final_risks'
    WHEN jsonb_typeof(s.synth->'risk_flags') = 'array' THEN s.synth->'risk_flags'
    ELSE COALESCE(to_jsonb(dr.risk_flags), '[]'::jsonb)
  END AS final_risks,
  COALESCE(telemetry.try_parse_jsonb(dr.council_views::text), '[]'::jsonb) AS council_views_json
FROM decision_records dr
CROSS JOIN LATERAL (
  SELECT telemetry.try_parse_jsonb(dr.synthesized_output::text) AS synth
) s;

-- 1) material_action_without_valid_nonce
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_material_action_without_valid_nonce_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_material_action_without_valid_nonce_daily AS
WITH material_decisions AS (
  SELECT
    b.record_id,
    b.user_stable_id,
    b.day_utc,
    b.session_id,
    b.recommendation_id,
    b.consent_nonce
  FROM telemetry.v_decision_base b
  WHERE b.actionability = 'material_action'
),
confirmed AS (
  SELECT DISTINCT
    el.user_stable_id,
    (el.payload->>'record_id')::uuid AS record_id,
    NULLIF(el.payload->>'action_hash', '') AS confirmed_action_hash
  FROM event_log el
  WHERE el.event_type = 'decision_confirmed'
    AND el.payload ? 'record_id'
),
nonce_join AS (
  SELECT
    d.*,
    c.record_id AS confirmed_record_id,
    c.confirmed_action_hash,
    cn.nonce AS matched_nonce,
    cn.action_hash AS nonce_action_hash,
    cn.used_at,
    cn.expires_at
  FROM material_decisions d
  LEFT JOIN confirmed c
    ON c.user_stable_id = d.user_stable_id
   AND c.record_id = d.record_id
  LEFT JOIN consent_nonces cn
    ON cn.nonce = d.consent_nonce
   AND cn.user_stable_id = d.user_stable_id
   AND cn.session_id = d.session_id
   AND cn.recommendation_id = d.recommendation_id
)
SELECT
  n.user_stable_id,
  n.day_utc,
  COUNT(*) AS material_total,
  COUNT(*) FILTER (WHERE n.confirmed_record_id IS NOT NULL) AS material_confirmed_total,
  COUNT(*) FILTER (
    WHERE n.confirmed_record_id IS NOT NULL
      AND (
        n.consent_nonce IS NULL
        OR n.matched_nonce IS NULL
        OR n.used_at IS NULL
        OR n.expires_at IS NULL
        OR n.used_at > n.expires_at
        OR (n.confirmed_action_hash IS NOT NULL AND n.nonce_action_hash IS DISTINCT FROM n.confirmed_action_hash)
      )
  ) AS material_action_without_valid_nonce
FROM nonce_join n
GROUP BY 1, 2;

CREATE UNIQUE INDEX uq_mv_material_action_without_valid_nonce_daily
  ON telemetry.mv_material_action_without_valid_nonce_daily(user_stable_id, day_utc);

-- 2) boundary_respect_rate
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_boundary_respect_rate_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_boundary_respect_rate_daily AS
SELECT
  b.user_stable_id,
  b.day_utc,
  COUNT(*) FILTER (WHERE b.actionability IN ('advisory', 'material_action')) AS advisory_or_material_total,
  COUNT(*) FILTER (
    WHERE b.actionability IN ('advisory', 'material_action')
      AND b.final_position = 'BLOCK'
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(COALESCE(b.final_risks, '[]'::jsonb)) r(val)
        WHERE r.val = 'values_boundary_violation'
      )
  ) AS blocked_for_boundary_violation,
  CASE
    WHEN COUNT(*) FILTER (WHERE b.actionability IN ('advisory', 'material_action')) = 0 THEN NULL
    ELSE 1.0 - (
      COUNT(*) FILTER (
        WHERE b.actionability IN ('advisory', 'material_action')
          AND b.final_position = 'BLOCK'
          AND EXISTS (
            SELECT 1
            FROM jsonb_array_elements_text(COALESCE(b.final_risks, '[]'::jsonb)) r(val)
            WHERE r.val = 'values_boundary_violation'
          )
      )::numeric
      / COUNT(*) FILTER (WHERE b.actionability IN ('advisory', 'material_action'))::numeric
    )
  END AS boundary_respect_rate
FROM telemetry.v_decision_base b
GROUP BY 1, 2;

CREATE UNIQUE INDEX uq_mv_boundary_respect_rate_daily
  ON telemetry.mv_boundary_respect_rate_daily(user_stable_id, day_utc);

-- 3) policy_check_failure_rate
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_policy_check_failure_rate_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_policy_check_failure_rate_daily AS
WITH exploded AS (
  SELECT
    b.user_stable_id,
    b.day_utc,
    role_json
  FROM telemetry.v_decision_base b
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(b.council_views_json) = 'array' THEN b.council_views_json
      ELSE '[]'::jsonb
    END
  ) AS role_json
),
scored AS (
  SELECT
    e.user_stable_id,
    e.day_utc,
    1 AS role_eval_count,
    CASE
      WHEN telemetry.try_parse_bool(e.role_json->'policy_checks'->>'boundaries_respected', false) = false
        OR telemetry.try_parse_bool(e.role_json->'policy_checks'->>'non_negotiables_respected', false) = false
        OR telemetry.try_parse_bool(e.role_json->'policy_checks'->>'consent_ok', false) = false
      THEN 1
      ELSE 0
    END AS policy_failure
  FROM exploded e
)
SELECT
  s.user_stable_id,
  s.day_utc,
  SUM(s.role_eval_count) AS role_evaluations_total,
  SUM(s.policy_failure) AS policy_check_failures,
  CASE
    WHEN SUM(s.role_eval_count) = 0 THEN NULL
    ELSE SUM(s.policy_failure)::numeric / SUM(s.role_eval_count)::numeric
  END AS policy_check_failure_rate
FROM scored s
GROUP BY 1, 2;

CREATE UNIQUE INDEX uq_mv_policy_check_failure_rate_daily
  ON telemetry.mv_policy_check_failure_rate_daily(user_stable_id, day_utc);

-- 4) council_disagreement_entropy
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_council_disagreement_entropy_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_council_disagreement_entropy_daily AS
WITH positions AS (
  SELECT
    b.record_id,
    b.user_stable_id,
    b.domain,
    b.day_utc,
    COALESCE(NULLIF(role_json->>'position', ''), 'DEFER') AS position
  FROM telemetry.v_decision_base b
  CROSS JOIN LATERAL jsonb_array_elements(
    CASE
      WHEN jsonb_typeof(b.council_views_json) = 'array' THEN b.council_views_json
      ELSE '[]'::jsonb
    END
  ) AS role_json
),
counts AS (
  SELECT
    p.record_id,
    p.user_stable_id,
    p.domain,
    p.day_utc,
    p.position,
    COUNT(*)::numeric AS n_position
  FROM positions p
  GROUP BY 1, 2, 3, 4, 5
),
totals AS (
  SELECT
    c.record_id,
    c.user_stable_id,
    c.domain,
    c.day_utc,
    SUM(c.n_position) AS n_total
  FROM counts c
  GROUP BY 1, 2, 3, 4
),
entropy_per_record AS (
  SELECT
    c.record_id,
    c.user_stable_id,
    c.domain,
    c.day_utc,
    SUM(
      CASE
        WHEN c.n_position = 0 OR t.n_total = 0 THEN 0
        ELSE - (c.n_position / t.n_total) * (LN(c.n_position / t.n_total) / LN(2))
      END
    ) AS disagreement_entropy
  FROM counts c
  JOIN totals t
    ON t.record_id = c.record_id
   AND t.user_stable_id = c.user_stable_id
   AND t.domain = c.domain
   AND t.day_utc = c.day_utc
  GROUP BY 1, 2, 3, 4
)
SELECT
  e.user_stable_id,
  e.domain,
  e.day_utc,
  AVG(e.disagreement_entropy) AS council_disagreement_entropy
FROM entropy_per_record e
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX uq_mv_council_disagreement_entropy_daily
  ON telemetry.mv_council_disagreement_entropy_daily(user_stable_id, domain, day_utc);

-- 5) override_rate_by_domain
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_override_rate_by_domain_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_override_rate_by_domain_daily AS
SELECT
  b.user_stable_id,
  b.domain,
  b.day_utc,
  COUNT(*) AS total_decisions,
  COUNT(*) FILTER (WHERE b.user_override IN ('rejected', 'modified')) AS override_count,
  CASE
    WHEN COUNT(*) = 0 THEN NULL
    ELSE COUNT(*) FILTER (WHERE b.user_override IN ('rejected', 'modified'))::numeric / COUNT(*)::numeric
  END AS override_rate_by_domain
FROM telemetry.v_decision_base b
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX uq_mv_override_rate_by_domain_daily
  ON telemetry.mv_override_rate_by_domain_daily(user_stable_id, domain, day_utc);

-- 6) nonce_misuse_events
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_nonce_misuse_events_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_nonce_misuse_events_daily AS
SELECT
  el.user_stable_id,
  timezone('UTC', el.timestamp)::date AS day_utc,
  el.payload->>'error_code' AS error_code,
  COUNT(*) AS event_count
FROM event_log el
WHERE el.event_type = 'nonce_validation_failed'
  AND (el.payload->>'error_code') IN (
    'NONCE_REPLAY',
    'NONCE_BINDING_MISMATCH',
    'CONSENT_EXPIRED',
    'NONCE_INVALID'
  )
GROUP BY 1, 2, 3;

CREATE UNIQUE INDEX uq_mv_nonce_misuse_events_daily
  ON telemetry.mv_nonce_misuse_events_daily(user_stable_id, day_utc, error_code);

-- 7) onboarding_completion_rate
-- Cumulative completion-to-date metric by day_utc (not cohort completion).
DROP MATERIALIZED VIEW IF EXISTS telemetry.mv_onboarding_completion_rate_daily CASCADE;
CREATE MATERIALIZED VIEW telemetry.mv_onboarding_completion_rate_daily AS
WITH bounds AS (
  SELECT
    COALESCE(MIN(timezone('UTC', os.created_at)::date), timezone('UTC', now())::date) AS start_day,
    timezone('UTC', now())::date AS end_day
  FROM onboarding_status os
),
calendar AS (
  SELECT generate_series(
    (SELECT start_day FROM bounds),
    (SELECT end_day FROM bounds),
    interval '1 day'
  )::date AS day_utc
),
started AS (
  SELECT
    c.day_utc,
    COUNT(*) AS started_users
  FROM calendar c
  JOIN onboarding_status os
    ON timezone('UTC', os.created_at)::date <= c.day_utc
  GROUP BY c.day_utc
),
confirmed AS (
  SELECT
    c.day_utc,
    COUNT(*) AS confirmed_users
  FROM calendar c
  JOIN onboarding_status os
    ON timezone('UTC', COALESCE(os.confirmed_at, os.completed_at))::date <= c.day_utc
  GROUP BY c.day_utc
)
SELECT
  c.day_utc,
  COALESCE(s.started_users, 0) AS users_with_onboarding_started,
  COALESCE(k.confirmed_users, 0) AS users_with_onboarding_confirmed,
  CASE
    WHEN COALESCE(s.started_users, 0) = 0 THEN NULL
    ELSE COALESCE(k.confirmed_users, 0)::numeric / s.started_users::numeric
  END AS onboarding_completion_rate
FROM calendar c
LEFT JOIN started s ON s.day_utc = c.day_utc
LEFT JOIN confirmed k ON k.day_utc = c.day_utc;

CREATE UNIQUE INDEX uq_mv_onboarding_completion_rate_daily
  ON telemetry.mv_onboarding_completion_rate_daily(day_utc);

-- Snapshot function: returns 7d + 30d metrics in one JSON object.
-- Optional user filter:
-- - pass NULL for global
-- - pass UUID for one user
CREATE OR REPLACE FUNCTION telemetry.get_dashboard_snapshot(
  p_user_stable_id uuid DEFAULT NULL,
  p_as_of_day date DEFAULT timezone('UTC', now())::date,
  p_short_window_days integer DEFAULT 7,
  p_long_window_days integer DEFAULT 30
)
RETURNS jsonb
LANGUAGE sql
STABLE
AS $$
WITH window_days AS (
  SELECT
    p_as_of_day AS as_of_day,
    (p_as_of_day - LEAST(365, GREATEST(1, p_short_window_days)) + 1) AS start_7d,
    (p_as_of_day - LEAST(365, GREATEST(1, p_long_window_days)) + 1) AS start_30d,
    LEAST(365, GREATEST(1, p_short_window_days)) AS short_window_days,
    LEAST(365, GREATEST(1, p_long_window_days)) AS long_window_days
),
nonce_7d AS (
  SELECT
    COALESCE(SUM(m.material_total), 0) AS material_total_7d,
    COALESCE(SUM(m.material_confirmed_total), 0) AS material_confirmed_total_7d,
    COALESCE(SUM(m.material_action_without_valid_nonce), 0) AS material_action_without_valid_nonce_7d
  FROM telemetry.mv_material_action_without_valid_nonce_daily m
  CROSS JOIN window_days w
  WHERE m.day_utc BETWEEN w.start_7d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR m.user_stable_id = p_user_stable_id)
),
nonce_30d AS (
  SELECT
    COALESCE(SUM(m.material_total), 0) AS material_total_30d,
    COALESCE(SUM(m.material_confirmed_total), 0) AS material_confirmed_total_30d,
    COALESCE(SUM(m.material_action_without_valid_nonce), 0) AS material_action_without_valid_nonce_30d
  FROM telemetry.mv_material_action_without_valid_nonce_daily m
  CROSS JOIN window_days w
  WHERE m.day_utc BETWEEN w.start_30d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR m.user_stable_id = p_user_stable_id)
),
boundary_7d AS (
  SELECT
    CASE
      WHEN COALESCE(SUM(b.advisory_or_material_total), 0) = 0 THEN NULL
      ELSE 1.0 - (SUM(b.blocked_for_boundary_violation)::numeric / SUM(b.advisory_or_material_total)::numeric)
    END AS boundary_respect_rate_7d
  FROM telemetry.mv_boundary_respect_rate_daily b
  CROSS JOIN window_days w
  WHERE b.day_utc BETWEEN w.start_7d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR b.user_stable_id = p_user_stable_id)
),
boundary_30d AS (
  SELECT
    CASE
      WHEN COALESCE(SUM(b.advisory_or_material_total), 0) = 0 THEN NULL
      ELSE 1.0 - (SUM(b.blocked_for_boundary_violation)::numeric / SUM(b.advisory_or_material_total)::numeric)
    END AS boundary_respect_rate_30d
  FROM telemetry.mv_boundary_respect_rate_daily b
  CROSS JOIN window_days w
  WHERE b.day_utc BETWEEN w.start_30d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR b.user_stable_id = p_user_stable_id)
),
policy_7d AS (
  SELECT
    CASE
      WHEN COALESCE(SUM(p.role_evaluations_total), 0) = 0 THEN NULL
      ELSE SUM(p.policy_check_failures)::numeric / SUM(p.role_evaluations_total)::numeric
    END AS policy_check_failure_rate_7d
  FROM telemetry.mv_policy_check_failure_rate_daily p
  CROSS JOIN window_days w
  WHERE p.day_utc BETWEEN w.start_7d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR p.user_stable_id = p_user_stable_id)
),
policy_30d AS (
  SELECT
    CASE
      WHEN COALESCE(SUM(p.role_evaluations_total), 0) = 0 THEN NULL
      ELSE SUM(p.policy_check_failures)::numeric / SUM(p.role_evaluations_total)::numeric
    END AS policy_check_failure_rate_30d
  FROM telemetry.mv_policy_check_failure_rate_daily p
  CROSS JOIN window_days w
  WHERE p.day_utc BETWEEN w.start_30d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR p.user_stable_id = p_user_stable_id)
),
entropy_7d AS (
  SELECT AVG(e.council_disagreement_entropy) AS council_disagreement_entropy_7d
  FROM telemetry.mv_council_disagreement_entropy_daily e
  CROSS JOIN window_days w
  WHERE e.day_utc BETWEEN w.start_7d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR e.user_stable_id = p_user_stable_id)
),
entropy_30d AS (
  SELECT AVG(e.council_disagreement_entropy) AS council_disagreement_entropy_30d
  FROM telemetry.mv_council_disagreement_entropy_daily e
  CROSS JOIN window_days w
  WHERE e.day_utc BETWEEN w.start_30d AND w.as_of_day
    AND (p_user_stable_id IS NULL OR e.user_stable_id = p_user_stable_id)
),
override_7d AS (
  SELECT COALESCE(
    jsonb_object_agg(x.domain, x.override_rate),
    '{}'::jsonb
  ) AS override_rate_by_domain_7d
  FROM (
    SELECT
      o.domain,
      CASE
        WHEN SUM(o.total_decisions) = 0 THEN NULL
        ELSE SUM(o.override_count)::numeric / SUM(o.total_decisions)::numeric
      END AS override_rate
    FROM telemetry.mv_override_rate_by_domain_daily o
    CROSS JOIN window_days w
    WHERE o.day_utc BETWEEN w.start_7d AND w.as_of_day
      AND (p_user_stable_id IS NULL OR o.user_stable_id = p_user_stable_id)
    GROUP BY o.domain
  ) x
),
override_30d AS (
  SELECT COALESCE(
    jsonb_object_agg(x.domain, x.override_rate),
    '{}'::jsonb
  ) AS override_rate_by_domain_30d
  FROM (
    SELECT
      o.domain,
      CASE
        WHEN SUM(o.total_decisions) = 0 THEN NULL
        ELSE SUM(o.override_count)::numeric / SUM(o.total_decisions)::numeric
      END AS override_rate
    FROM telemetry.mv_override_rate_by_domain_daily o
    CROSS JOIN window_days w
    WHERE o.day_utc BETWEEN w.start_30d AND w.as_of_day
      AND (p_user_stable_id IS NULL OR o.user_stable_id = p_user_stable_id)
    GROUP BY o.domain
  ) x
),
misuse_7d AS (
  SELECT COALESCE(
    jsonb_object_agg(x.error_code, x.event_count),
    '{}'::jsonb
  ) AS nonce_misuse_events_7d
  FROM (
    SELECT
      n.error_code,
      SUM(n.event_count) AS event_count
    FROM telemetry.mv_nonce_misuse_events_daily n
    CROSS JOIN window_days w
    WHERE n.day_utc BETWEEN w.start_7d AND w.as_of_day
      AND (p_user_stable_id IS NULL OR n.user_stable_id = p_user_stable_id)
    GROUP BY n.error_code
  ) x
),
misuse_30d AS (
  SELECT COALESCE(
    jsonb_object_agg(x.error_code, x.event_count),
    '{}'::jsonb
  ) AS nonce_misuse_events_30d
  FROM (
    SELECT
      n.error_code,
      SUM(n.event_count) AS event_count
    FROM telemetry.mv_nonce_misuse_events_daily n
    CROSS JOIN window_days w
    WHERE n.day_utc BETWEEN w.start_30d AND w.as_of_day
      AND (p_user_stable_id IS NULL OR n.user_stable_id = p_user_stable_id)
    GROUP BY n.error_code
  ) x
),
onboarding_current AS (
  SELECT
    CASE
      WHEN p_user_stable_id IS NULL THEN (
        SELECT o.onboarding_completion_rate
        FROM telemetry.mv_onboarding_completion_rate_daily o
        CROSS JOIN window_days w
        WHERE o.day_utc = w.as_of_day
      )
      ELSE (
        SELECT
          CASE
            WHEN os.user_stable_id IS NULL THEN NULL
            WHEN COALESCE(os.confirmed_at, os.completed_at) IS NOT NULL THEN 1.0
            ELSE 0.0
          END
        FROM onboarding_status os
        WHERE os.user_stable_id = p_user_stable_id
      )
    END AS onboarding_completion_rate
)
SELECT jsonb_build_object(
  'as_of_day_utc', (SELECT as_of_day FROM window_days),
  'window_standard', jsonb_build_object(
    'short_window_days', (SELECT short_window_days FROM window_days),
    'long_window_days', (SELECT long_window_days FROM window_days)
  ),
  'material_action_without_valid_nonce_7d', COALESCE((SELECT material_action_without_valid_nonce_7d FROM nonce_7d), 0),
  'material_action_without_valid_nonce_30d', COALESCE((SELECT material_action_without_valid_nonce_30d FROM nonce_30d), 0),
  'material_action_total_7d', COALESCE((SELECT material_total_7d FROM nonce_7d), 0),
  'material_action_total_30d', COALESCE((SELECT material_total_30d FROM nonce_30d), 0),
  'material_action_confirmed_total_7d', COALESCE((SELECT material_confirmed_total_7d FROM nonce_7d), 0),
  'material_action_confirmed_total_30d', COALESCE((SELECT material_confirmed_total_30d FROM nonce_30d), 0),
  'boundary_respect_rate_7d', CASE
    WHEN (SELECT boundary_respect_rate_7d FROM boundary_7d) IS NULL THEN NULL
    ELSE LEAST(1.0, GREATEST(0.0, (SELECT boundary_respect_rate_7d FROM boundary_7d)))
  END,
  'boundary_respect_rate_30d', CASE
    WHEN (SELECT boundary_respect_rate_30d FROM boundary_30d) IS NULL THEN NULL
    ELSE LEAST(1.0, GREATEST(0.0, (SELECT boundary_respect_rate_30d FROM boundary_30d)))
  END,
  'policy_check_failure_rate_7d', CASE
    WHEN (SELECT policy_check_failure_rate_7d FROM policy_7d) IS NULL THEN NULL
    ELSE LEAST(1.0, GREATEST(0.0, (SELECT policy_check_failure_rate_7d FROM policy_7d)))
  END,
  'policy_check_failure_rate_30d', CASE
    WHEN (SELECT policy_check_failure_rate_30d FROM policy_30d) IS NULL THEN NULL
    ELSE LEAST(1.0, GREATEST(0.0, (SELECT policy_check_failure_rate_30d FROM policy_30d)))
  END,
  'council_disagreement_entropy_7d', (SELECT council_disagreement_entropy_7d FROM entropy_7d),
  'council_disagreement_entropy_30d', (SELECT council_disagreement_entropy_30d FROM entropy_30d),
  'override_rate_by_domain_7d', COALESCE((SELECT override_rate_by_domain_7d FROM override_7d), '{}'::jsonb),
  'override_rate_by_domain_30d', COALESCE((SELECT override_rate_by_domain_30d FROM override_30d), '{}'::jsonb),
  'nonce_misuse_events_7d', COALESCE((SELECT nonce_misuse_events_7d FROM misuse_7d), '{}'::jsonb),
  'nonce_misuse_events_30d', COALESCE((SELECT nonce_misuse_events_30d FROM misuse_30d), '{}'::jsonb),
  'onboarding_completion_rate_current', CASE
    WHEN (SELECT onboarding_completion_rate FROM onboarding_current) IS NULL THEN NULL
    ELSE LEAST(1.0, GREATEST(0.0, (SELECT onboarding_completion_rate FROM onboarding_current)))
  END
);
$$;

-- Optional rolling window view for chart backends.
DROP VIEW IF EXISTS telemetry.v_boundary_respect_rate_windows CASCADE;
CREATE VIEW telemetry.v_boundary_respect_rate_windows AS
SELECT
  b.user_stable_id,
  b.day_utc,
  AVG(b.boundary_respect_rate) OVER (
    PARTITION BY b.user_stable_id
    ORDER BY b.day_utc
    ROWS BETWEEN 6 PRECEDING AND CURRENT ROW
  ) AS boundary_respect_rate_7d,
  AVG(b.boundary_respect_rate) OVER (
    PARTITION BY b.user_stable_id
    ORDER BY b.day_utc
    ROWS BETWEEN 29 PRECEDING AND CURRENT ROW
  ) AS boundary_respect_rate_30d
FROM telemetry.mv_boundary_respect_rate_daily b;

-- Refresh notes:
-- 1) For production reads with minimal lock impact, use CONCURRENTLY from scheduler:
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_material_action_without_valid_nonce_daily;
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_boundary_respect_rate_daily;
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_policy_check_failure_rate_daily;
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_council_disagreement_entropy_daily;
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_override_rate_by_domain_daily;
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_nonce_misuse_events_daily;
--    REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_onboarding_completion_rate_daily;
-- 2) Recommended cadence for alpha: every 5 minutes.

-- -----------------------------------------------------------------------------
-- Refresh procedure (dependency-safe order)
-- -----------------------------------------------------------------------------
CREATE OR REPLACE PROCEDURE telemetry.refresh_all_telemetry(p_use_concurrently boolean DEFAULT true)
LANGUAGE plpgsql
AS $$
BEGIN
  IF p_use_concurrently THEN
    BEGIN
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_material_action_without_valid_nonce_daily';
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_boundary_respect_rate_daily';
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_policy_check_failure_rate_daily';
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_council_disagreement_entropy_daily';
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_override_rate_by_domain_daily';
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_nonce_misuse_events_daily';
      EXECUTE 'REFRESH MATERIALIZED VIEW CONCURRENTLY telemetry.mv_onboarding_completion_rate_daily';
      RETURN;
    EXCEPTION
      WHEN feature_not_supported OR object_not_in_prerequisite_state THEN
        -- Fall back to non-concurrent refresh when called inside a transaction
        -- or when concurrent prerequisites are not met.
        NULL;
    END;
  END IF;

  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_material_action_without_valid_nonce_daily';
  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_boundary_respect_rate_daily';
  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_policy_check_failure_rate_daily';
  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_council_disagreement_entropy_daily';
  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_override_rate_by_domain_daily';
  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_nonce_misuse_events_daily';
  EXECUTE 'REFRESH MATERIALIZED VIEW telemetry.mv_onboarding_completion_rate_daily';
END;
$$;

-- -----------------------------------------------------------------------------
-- Optional least-privilege role for telemetry consumers
-- -----------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'telemetry_reader') THEN
    CREATE ROLE telemetry_reader;
  END IF;
END;
$$;

GRANT USAGE ON SCHEMA telemetry TO telemetry_reader;
GRANT SELECT ON ALL TABLES IN SCHEMA telemetry TO telemetry_reader;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA telemetry TO telemetry_reader;
GRANT EXECUTE ON ALL PROCEDURES IN SCHEMA telemetry TO telemetry_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA telemetry
GRANT SELECT ON TABLES TO telemetry_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA telemetry
GRANT EXECUTE ON FUNCTIONS TO telemetry_reader;

ALTER DEFAULT PRIVILEGES IN SCHEMA telemetry
GRANT EXECUTE ON PROCEDURES TO telemetry_reader;
