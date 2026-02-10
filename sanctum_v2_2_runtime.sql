
-- Sanctum HG-MoE v2.2 Runtime Foundation
-- Scope:
-- 1) Governance/invariant DB rails
-- 2) Projection function (role-aware)
-- 3) Consent nonce flow
-- 4) Onboarding state machine
--
-- Notes:
-- - This script is idempotent where practical.
-- - Requires PostgreSQL 13+ and pgcrypto.

CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- -----------------------------------------------------------------------------
-- Core tables
-- -----------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS users (
  stable_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  current_jurisdiction text
);

CREATE TABLE IF NOT EXISTS user_profiles (
  profile_id bigserial PRIMARY KEY,
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  version integer NOT NULL DEFAULT 1,
  declared_values jsonb NOT NULL DEFAULT '[]'::jsonb,
  preferences jsonb NOT NULL DEFAULT '{}'::jsonb,
  last_const_check timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_stable_id, version)
);

CREATE TABLE IF NOT EXISTS change_tickets (
  ticket_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  requested_by uuid,
  target_type text NOT NULL CHECK (target_type IN ('boundary', 'policy', 'lineage')),
  target_id uuid NOT NULL,
  proposed_change jsonb NOT NULL DEFAULT '{}'::jsonb,
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending', 'approved', 'rejected', 'expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  approved_at timestamptz,
  expires_at timestamptz NOT NULL DEFAULT (now() + interval '7 days')
);

CREATE TABLE IF NOT EXISTS hard_boundaries (
  boundary_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  text text NOT NULL,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'deprecated', 'superseded')),
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz,
  change_ticket_id uuid REFERENCES change_tickets(ticket_id),
  superseded_by uuid REFERENCES hard_boundaries(boundary_id),
  CONSTRAINT hard_boundaries_no_self_supersede CHECK (superseded_by IS DISTINCT FROM boundary_id)
);

CREATE TABLE IF NOT EXISTS lineage_nodes (
  node_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  name_or_alias text,
  relationship_type text CHECK (relationship_type IN ('blood', 'chosen', 'legal', 'advisor', 'observer')),
  verification_level text CHECK (verification_level IN ('unverified', 'self_declared', 'document', 'biometric', 'multi_sig', 'primarch_verified')),
  governance_role text NOT NULL DEFAULT 'none' CHECK (governance_role IN ('primarch', 'co_primarch', 'advisor', 'observer', 'none')),
  consent_scope jsonb NOT NULL DEFAULT '{"read":[],"write":[],"share":[],"act":[]}'::jsonb,
  status text NOT NULL DEFAULT 'active' CHECK (status IN ('active', 'suspended', 'revoked')),
  added_at timestamptz NOT NULL DEFAULT now(),
  suspended_at timestamptz,
  change_ticket_id uuid REFERENCES change_tickets(ticket_id)
);

CREATE TABLE IF NOT EXISTS policy_objects (
  policy_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  non_negotiables jsonb NOT NULL DEFAULT '[]'::jsonb,
  escalation_rules jsonb NOT NULL DEFAULT '[]'::jsonb,
  policy_version integer NOT NULL DEFAULT 1,
  last_updated timestamptz NOT NULL DEFAULT now(),
  change_ticket_id uuid REFERENCES change_tickets(ticket_id),
  UNIQUE (user_stable_id, policy_version)
);

CREATE TABLE IF NOT EXISTS policy_consent_rules (
  rule_id bigserial PRIMARY KEY,
  policy_id uuid NOT NULL REFERENCES policy_objects(policy_id) ON DELETE CASCADE,
  domain text NOT NULL,
  read_level text NOT NULL CHECK (read_level IN ('explicit', 'implicit', 'never')),
  write_level text NOT NULL CHECK (write_level IN ('explicit', 'implicit', 'never')),
  share_level text NOT NULL CHECK (share_level IN ('explicit', 'implicit', 'never')),
  act_level text NOT NULL CHECK (act_level IN ('explicit', 'implicit', 'never')),
  UNIQUE (policy_id, domain)
);
CREATE TABLE IF NOT EXISTS memory_items (
  memory_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  type text NOT NULL CHECK (type IN ('episodic', 'semantic', 'procedural')),
  content jsonb NOT NULL DEFAULT '{}'::jsonb,
  embedding_ref jsonb,
  source text NOT NULL CHECK (source IN ('user_input', 'system_inference', 'external_tool', 'lineage_input', 'user_correction')),
  confidence real CHECK (confidence >= 0 AND confidence <= 1),
  sensitivity text NOT NULL CHECK (sensitivity IN ('low', 'medium', 'high', 'critical')),
  retention text NOT NULL CHECK (retention IN ('forever', 'review_1y', 'review_5y', 'until_revoked')),
  provenance_hash text NOT NULL,
  timestamp timestamptz NOT NULL DEFAULT now(),
  time_validity jsonb,
  state text NOT NULL DEFAULT 'active' CHECK (state IN ('active', 'superseded', 'revoked', 'expired')),
  superseded_by uuid REFERENCES memory_items(memory_id),
  tags text[] NOT NULL DEFAULT '{}'::text[],
  CONSTRAINT memory_items_no_self_supersede CHECK (superseded_by IS DISTINCT FROM memory_id)
);

CREATE TABLE IF NOT EXISTS decision_records (
  record_id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  session_id text NOT NULL,
  recommendation_id text NOT NULL,
  domain text NOT NULL,
  actionability text NOT NULL CHECK (actionability IN ('info_only', 'advisory', 'material_action')),
  options_json jsonb,
  selected_json jsonb,
  rationale text,
  risk_flags text[] NOT NULL DEFAULT '{}'::text[],
  synthesized_output jsonb NOT NULL DEFAULT '{}'::jsonb,
  user_override text NOT NULL DEFAULT 'none' CHECK (user_override IN ('accepted', 'rejected', 'modified', 'none')),
  override_rationale text,
  constitution_passed boolean NOT NULL DEFAULT false,
  consent_nonce text,
  material_action_confirmed boolean NOT NULL DEFAULT false,
  council_views jsonb NOT NULL DEFAULT '[]'::jsonb,
  timestamp timestamptz NOT NULL DEFAULT now()
);

-- Upgrade safety: existing installs may predate this column even if the CREATE
-- statement above now includes it.
ALTER TABLE decision_records
  ADD COLUMN IF NOT EXISTS material_action_confirmed boolean NOT NULL DEFAULT false;

DO $$
BEGIN
  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_material_action_nonce_when_confirmed'
      AND conrelid = 'decision_records'::regclass
  ) THEN
    ALTER TABLE decision_records
      ADD CONSTRAINT chk_material_action_nonce_when_confirmed
      CHECK (
        actionability <> 'material_action'
        OR material_action_confirmed = false
        OR consent_nonce IS NOT NULL
      );
  END IF;
END;
$$;

DO $$
BEGIN
  -- Replace legacy weaker constraint, then enforce non-blank recommendation ids.
  IF EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_recommendation_id_nonempty'
      AND conrelid = 'decision_records'::regclass
  ) THEN
    ALTER TABLE decision_records
      DROP CONSTRAINT chk_recommendation_id_nonempty;
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM pg_constraint
    WHERE conname = 'chk_recommendation_id_not_blank'
      AND conrelid = 'decision_records'::regclass
  ) THEN
    ALTER TABLE decision_records
      ADD CONSTRAINT chk_recommendation_id_not_blank
      CHECK (btrim(recommendation_id) <> '');
  END IF;
END;
$$;

CREATE TABLE IF NOT EXISTS council_views (
  view_id bigserial PRIMARY KEY,
  record_id uuid NOT NULL REFERENCES decision_records(record_id) ON DELETE CASCADE,
  role text NOT NULL,
  position text NOT NULL CHECK (position IN ('ALLOW', 'ALLOW_WITH_CONDITIONS', 'BLOCK', 'DEFER')),
  confidence real NOT NULL CHECK (confidence >= 0 AND confidence <= 1),
  assumptions jsonb NOT NULL DEFAULT '[]'::jsonb,
  evidence_refs jsonb NOT NULL DEFAULT '[]'::jsonb,
  risks jsonb NOT NULL DEFAULT '[]'::jsonb,
  recommended_action text,
  policy_checks jsonb NOT NULL DEFAULT '{"boundaries_respected":true,"non_negotiables_respected":true,"consent_ok":true}'::jsonb,
  failure_mode text,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS event_log (
  event_id bigserial PRIMARY KEY,
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  event_type text NOT NULL,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  provenance_hash text,
  timestamp timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS consent_nonces (
  nonce text PRIMARY KEY,
  user_stable_id uuid NOT NULL REFERENCES users(stable_id) ON DELETE CASCADE,
  session_id text NOT NULL,
  recommendation_id text NOT NULL,
  action_hash text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  used_at timestamptz
);

CREATE TABLE IF NOT EXISTS onboarding_status (
  user_stable_id uuid PRIMARY KEY REFERENCES users(stable_id) ON DELETE CASCADE,
  current_step integer NOT NULL DEFAULT 0 CHECK (current_step BETWEEN 0 AND 5),
  completed_at timestamptz,
  primarch_node_id uuid REFERENCES lineage_nodes(node_id),
  confirmed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS idempotency_keys (
  idempotency_key text NOT NULL,
  endpoint text NOT NULL,
  request_hash text,
  response_status integer,
  response_body jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (idempotency_key, endpoint)
);

-- -----------------------------------------------------------------------------
-- Indexes
-- -----------------------------------------------------------------------------

CREATE INDEX IF NOT EXISTS idx_user_profiles_user_version ON user_profiles(user_stable_id, version DESC);
CREATE INDEX IF NOT EXISTS idx_boundaries_user_status ON hard_boundaries(user_stable_id, status, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_lineage_user_role_status ON lineage_nodes(user_stable_id, governance_role, status);
CREATE INDEX IF NOT EXISTS idx_policy_user_version ON policy_objects(user_stable_id, policy_version DESC);
CREATE INDEX IF NOT EXISTS idx_policy_rules_policy_domain ON policy_consent_rules(policy_id, domain);
CREATE INDEX IF NOT EXISTS idx_memory_user_state_ts ON memory_items(user_stable_id, state, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_memory_user_state_sensitivity ON memory_items(user_stable_id, state, sensitivity);
CREATE INDEX IF NOT EXISTS idx_decision_user_ts ON decision_records(user_stable_id, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_decision_user_domain_ts ON decision_records(user_stable_id, domain, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_decision_actionability_ts ON decision_records(actionability, timestamp DESC);
CREATE INDEX IF NOT EXISTS idx_event_user_ts ON event_log(user_stable_id, event_id DESC);
CREATE INDEX IF NOT EXISTS idx_event_type_ts_user ON event_log(event_type, timestamp DESC, user_stable_id);

CREATE UNIQUE INDEX IF NOT EXISTS uq_one_active_primarch
  ON lineage_nodes(user_stable_id)
  WHERE governance_role = 'primarch' AND status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS uq_boundary_text_ci
  ON hard_boundaries(user_stable_id, lower(text))
  WHERE status = 'active';

CREATE UNIQUE INDEX IF NOT EXISTS uq_nonce_binding_active
  ON consent_nonces(user_stable_id, session_id, recommendation_id, action_hash)
  WHERE used_at IS NULL;

CREATE INDEX IF NOT EXISTS idx_nonce_lookup
  ON consent_nonces(nonce, used_at, expires_at)
  INCLUDE (user_stable_id, session_id, recommendation_id, action_hash);

CREATE INDEX IF NOT EXISTS idx_onboarding_step ON onboarding_status(user_stable_id, current_step);
CREATE INDEX IF NOT EXISTS idx_ln_caller_read_scope
  ON lineage_nodes(node_id, user_stable_id, status)
  INCLUDE (consent_scope);
-- -----------------------------------------------------------------------------
-- Utility functions
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.log_event(
  p_user_stable_id uuid,
  p_event_type text,
  p_payload jsonb DEFAULT '{}'::jsonb,
  p_provenance_hash text DEFAULT NULL
)
RETURNS bigint
LANGUAGE plpgsql
AS $$
DECLARE
  v_event_id bigint;
BEGIN
  INSERT INTO event_log(user_stable_id, event_type, payload, provenance_hash, timestamp)
  VALUES (p_user_stable_id, p_event_type, COALESCE(p_payload, '{}'::jsonb), p_provenance_hash, now())
  RETURNING event_id INTO v_event_id;

  RETURN v_event_id;
END;
$$;

CREATE OR REPLACE FUNCTION public.is_active_primarch(
  p_user_stable_id uuid,
  p_caller_node_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
SELECT EXISTS (
  SELECT 1
  FROM lineage_nodes ln
  WHERE ln.user_stable_id = p_user_stable_id
    AND ln.node_id = p_caller_node_id
    AND ln.status = 'active'
    AND ln.governance_role = 'primarch'
);
$$;

CREATE OR REPLACE FUNCTION public.is_valid_change_ticket(
  p_ticket_id uuid,
  p_user_stable_id uuid,
  p_target_type text,
  p_target_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
AS $$
SELECT EXISTS (
  SELECT 1
  FROM change_tickets ct
  WHERE ct.ticket_id = p_ticket_id
    AND ct.user_stable_id = p_user_stable_id
    AND ct.target_type = p_target_type
    AND ct.target_id = p_target_id
    AND ct.status = 'approved'
    AND now() < ct.expires_at
);
$$;

-- -----------------------------------------------------------------------------
-- Invariant enforcement triggers
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.deny_delete_governed()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'DELETE forbidden on governed table: %', TG_TABLE_NAME;
END;
$$;

DROP TRIGGER IF EXISTS trg_no_delete_hard_boundaries ON hard_boundaries;
CREATE TRIGGER trg_no_delete_hard_boundaries
BEFORE DELETE ON hard_boundaries
FOR EACH ROW EXECUTE FUNCTION public.deny_delete_governed();

DROP TRIGGER IF EXISTS trg_no_delete_lineage_nodes ON lineage_nodes;
CREATE TRIGGER trg_no_delete_lineage_nodes
BEFORE DELETE ON lineage_nodes
FOR EACH ROW EXECUTE FUNCTION public.deny_delete_governed();

DROP TRIGGER IF EXISTS trg_no_delete_policy_objects ON policy_objects;
CREATE TRIGGER trg_no_delete_policy_objects
BEFORE DELETE ON policy_objects
FOR EACH ROW EXECUTE FUNCTION public.deny_delete_governed();

DROP TRIGGER IF EXISTS trg_no_delete_memory_items ON memory_items;
CREATE TRIGGER trg_no_delete_memory_items
BEFORE DELETE ON memory_items
FOR EACH ROW EXECUTE FUNCTION public.deny_delete_governed();

CREATE OR REPLACE FUNCTION public.deny_event_log_mutation()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  RAISE EXCEPTION 'event_log is append-only: UPDATE/DELETE forbidden';
END;
$$;

DROP TRIGGER IF EXISTS trg_event_log_no_update ON event_log;
CREATE TRIGGER trg_event_log_no_update
BEFORE UPDATE ON event_log
FOR EACH ROW EXECUTE FUNCTION public.deny_event_log_mutation();

DROP TRIGGER IF EXISTS trg_event_log_no_delete ON event_log;
CREATE TRIGGER trg_event_log_no_delete
BEFORE DELETE ON event_log
FOR EACH ROW EXECUTE FUNCTION public.deny_event_log_mutation();

DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_role') THEN
    REVOKE UPDATE, DELETE ON event_log FROM app_role;
    GRANT SELECT, INSERT ON event_log TO app_role;
  END IF;
END;
$$;

CREATE OR REPLACE FUNCTION public.enforce_boundary_governance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.status IS DISTINCT FROM NEW.status
     OR OLD.superseded_by IS DISTINCT FROM NEW.superseded_by
     OR OLD.text IS DISTINCT FROM NEW.text THEN
    IF NEW.change_ticket_id IS NULL THEN
      RAISE EXCEPTION 'TICKET_REQUIRED';
    END IF;

    IF NOT public.is_valid_change_ticket(
      NEW.change_ticket_id,
      NEW.user_stable_id,
      'boundary',
      NEW.boundary_id
    ) THEN
      RAISE EXCEPTION 'GOVERNANCE_TICKET_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_boundary_governance ON hard_boundaries;
CREATE TRIGGER trg_boundary_governance
BEFORE UPDATE OF status, superseded_by, text ON hard_boundaries
FOR EACH ROW EXECUTE FUNCTION public.enforce_boundary_governance();

CREATE OR REPLACE FUNCTION public.enforce_lineage_governance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.consent_scope IS DISTINCT FROM NEW.consent_scope
     OR OLD.governance_role IS DISTINCT FROM NEW.governance_role
     OR OLD.status IS DISTINCT FROM NEW.status THEN
    IF NEW.change_ticket_id IS NULL THEN
      RAISE EXCEPTION 'TICKET_REQUIRED';
    END IF;

    IF NOT public.is_valid_change_ticket(
      NEW.change_ticket_id,
      NEW.user_stable_id,
      'lineage',
      NEW.node_id
    ) THEN
      RAISE EXCEPTION 'GOVERNANCE_TICKET_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_lineage_governance ON lineage_nodes;
CREATE TRIGGER trg_lineage_governance
BEFORE UPDATE OF consent_scope, governance_role, status ON lineage_nodes
FOR EACH ROW EXECUTE FUNCTION public.enforce_lineage_governance();

CREATE OR REPLACE FUNCTION public.enforce_policy_governance()
RETURNS trigger
LANGUAGE plpgsql
AS $$
BEGIN
  IF OLD.non_negotiables IS DISTINCT FROM NEW.non_negotiables
     OR OLD.escalation_rules IS DISTINCT FROM NEW.escalation_rules
     OR OLD.policy_version IS DISTINCT FROM NEW.policy_version THEN
    IF NEW.change_ticket_id IS NULL THEN
      RAISE EXCEPTION 'TICKET_REQUIRED';
    END IF;

    IF NOT public.is_valid_change_ticket(
      NEW.change_ticket_id,
      NEW.user_stable_id,
      'policy',
      NEW.policy_id
    ) THEN
      RAISE EXCEPTION 'GOVERNANCE_TICKET_INVALID';
    END IF;
  END IF;
  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_policy_governance ON policy_objects;
CREATE TRIGGER trg_policy_governance
BEFORE UPDATE ON policy_objects
FOR EACH ROW EXECUTE FUNCTION public.enforce_policy_governance();

CREATE OR REPLACE FUNCTION public.enforce_memory_supersession()
RETURNS trigger
LANGUAGE plpgsql
AS $$
DECLARE
  cur uuid;
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.state IS DISTINCT FROM NEW.state THEN
    IF NOT (
      OLD.state = 'active' AND NEW.state IN ('superseded', 'revoked', 'expired')
    ) THEN
      RAISE EXCEPTION 'INVALID_MEMORY_STATE_TRANSITION';
    END IF;
  END IF;

  IF NEW.state = 'superseded' AND NEW.superseded_by IS NULL THEN
    RAISE EXCEPTION 'SUPERSEDED_MEMORY_REQUIRES_SUPERSEDED_BY';
  END IF;

  IF NEW.superseded_by IS NOT NULL AND NEW.state <> 'superseded' THEN
    RAISE EXCEPTION 'SUPERSEDED_BY_REQUIRES_SUPERSEDED_STATE';
  END IF;

  cur := NEW.superseded_by;
  WHILE cur IS NOT NULL LOOP
    IF cur = NEW.memory_id THEN
      RAISE EXCEPTION 'CYCLE_DETECTED';
    END IF;
    SELECT mi.superseded_by INTO cur
    FROM memory_items mi
    WHERE mi.memory_id = cur;
    IF NOT FOUND THEN
      cur := NULL;
    END IF;
  END LOOP;

  RETURN NEW;
END;
$$;

DROP TRIGGER IF EXISTS trg_memory_supersession ON memory_items;
CREATE TRIGGER trg_memory_supersession
BEFORE INSERT OR UPDATE OF superseded_by, state ON memory_items
FOR EACH ROW EXECUTE FUNCTION public.enforce_memory_supersession();
-- -----------------------------------------------------------------------------
-- Projection function (v0.1 ship path)
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.get_user_projection(
  p_user_stable_id uuid,
  p_caller_node_id uuid DEFAULT NULL,
  p_caller_role text DEFAULT 'observer'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
AS $$
DECLARE
  v_profile jsonb;
  v_boundaries jsonb;
  v_policy jsonb;
  v_memories jsonb;
  v_decisions jsonb;
  v_last_event_id bigint;
  v_read_domains text[] := ARRAY[]::text[];
  v_has_all_read boolean := false;
  v_is_privileged boolean := false;
BEGIN
  v_is_privileged := p_caller_role IN ('primarch', 'co_primarch');

  IF p_caller_node_id IS NOT NULL THEN
    SELECT COALESCE(array_agg(v.value), ARRAY[]::text[])
    INTO v_read_domains
    FROM lineage_nodes ln
    CROSS JOIN LATERAL jsonb_array_elements_text(
      COALESCE(ln.consent_scope->'read', '[]'::jsonb)
    ) v(value)
    WHERE ln.node_id = p_caller_node_id
      AND ln.user_stable_id = p_user_stable_id
      AND ln.status = 'active';
  END IF;

  v_has_all_read := '*' = ANY(v_read_domains);

  SELECT to_jsonb(up.*)
  INTO v_profile
  FROM user_profiles up
  WHERE up.user_stable_id = p_user_stable_id
  ORDER BY up.version DESC
  LIMIT 1;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'boundary_id', hb.boundary_id,
      'text', hb.text,
      'status', hb.status,
      'created_at', hb.created_at
    ) ORDER BY hb.created_at DESC
  ), '[]'::jsonb)
  INTO v_boundaries
  FROM hard_boundaries hb
  WHERE hb.user_stable_id = p_user_stable_id
    AND hb.status = 'active';

  WITH latest_policy AS (
    SELECT po.*
    FROM policy_objects po
    WHERE po.user_stable_id = p_user_stable_id
    ORDER BY po.policy_version DESC
    LIMIT 1
  ),
  allowed_rules AS (
    SELECT pcr.*
    FROM policy_consent_rules pcr
    JOIN latest_policy lp ON lp.policy_id = pcr.policy_id
    WHERE v_is_privileged
       OR v_has_all_read
       OR pcr.domain = ANY(v_read_domains)
  )
  SELECT COALESCE(jsonb_build_object(
    'policy_id', lp.policy_id,
    'policy_version', lp.policy_version,
    'non_negotiables', lp.non_negotiables,
    'escalation_rules', lp.escalation_rules,
    'consent_requirements', COALESCE((
      SELECT jsonb_agg(jsonb_build_object(
        'domain', ar.domain,
        'read', ar.read_level,
        'write', ar.write_level,
        'share', ar.share_level,
        'act', ar.act_level
      ) ORDER BY ar.domain)
      FROM allowed_rules ar
    ), '[]'::jsonb)
  ), '{}'::jsonb)
  INTO v_policy
  FROM latest_policy lp;

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'memory_id', mi.memory_id,
      'type', mi.type,
      'content_summary', CASE
        WHEN mi.sensitivity = 'critical' AND NOT v_is_privileged THEN '[REDACTED]'
        WHEN mi.sensitivity = 'high' AND NOT v_is_privileged THEN '[REDACTED - high sensitivity]'
        ELSE mi.content
      END,
      'sensitivity', mi.sensitivity,
      'timestamp', mi.timestamp,
      'source', mi.source,
      'tags', mi.tags
    ) ORDER BY mi.timestamp DESC
  ), '[]'::jsonb)
  INTO v_memories
  FROM memory_items mi
  WHERE mi.user_stable_id = p_user_stable_id
    AND mi.state = 'active'
    AND (v_is_privileged OR mi.sensitivity <> 'critical');

  SELECT COALESCE(jsonb_agg(
    jsonb_build_object(
      'record_id', x.record_id,
      'recommendation_id', x.recommendation_id,
      'domain', x.domain,
      'actionability', x.actionability,
      'timestamp', x.timestamp,
      'user_override', x.user_override,
      'risk_flags_count', COALESCE(cardinality(x.risk_flags), 0),
      'constitution_passed', x.constitution_passed
    ) ORDER BY x.timestamp DESC
  ), '[]'::jsonb)
  INTO v_decisions
  FROM (
    SELECT dr.*
    FROM decision_records dr
    WHERE dr.user_stable_id = p_user_stable_id
      AND (v_is_privileged OR v_has_all_read OR dr.domain = ANY(v_read_domains))
    ORDER BY dr.timestamp DESC
    LIMIT 20
  ) x;

  SELECT COALESCE(MAX(el.event_id), 0)
  INTO v_last_event_id
  FROM event_log el
  WHERE el.user_stable_id = p_user_stable_id;

  RETURN jsonb_build_object(
    'user_stable_id', p_user_stable_id,
    'profile', COALESCE(v_profile, '{}'::jsonb),
    'active_boundaries', v_boundaries,
    'current_policy', v_policy,
    'active_memories', v_memories,
    'recent_decisions_summary', v_decisions,
    'metadata', jsonb_build_object(
      'generated_at', now(),
      'last_event_id', v_last_event_id,
      'projection_version', 'ev-' || v_last_event_id::text,
      'caller_role', p_caller_role,
      'read_domains', v_read_domains
    )
  );
END;
$$;

ALTER FUNCTION public.get_user_projection(uuid, uuid, text)
SET search_path = pg_catalog, public;

DO $$
BEGIN
  REVOKE ALL ON FUNCTION public.get_user_projection(uuid, uuid, text) FROM PUBLIC;
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_role') THEN
    GRANT EXECUTE ON FUNCTION public.get_user_projection(uuid, uuid, text) TO app_role;
  END IF;
END;
$$;
-- -----------------------------------------------------------------------------
-- Consent nonce functions
-- -----------------------------------------------------------------------------
-- Security note: nonce generation uses strong random tokens.
-- Binding/authorization is enforced at confirmation against:
-- user + session + recommendation_id + action_hash + expiry + single-use.

CREATE OR REPLACE FUNCTION public.create_or_get_consent_nonce(
  p_user_stable_id uuid,
  p_session_id text,
  p_record_id uuid,
  p_action_hash text,
  p_ttl_seconds integer DEFAULT 1800
)
RETURNS TABLE (
  nonce text,
  expires_at timestamptz,
  event_id bigint,
  reused boolean
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_nonce text;
  v_expires_at timestamptz;
  v_event_id bigint;
  v_recommendation_id text;
BEGIN
  SELECT dr.recommendation_id
  INTO v_recommendation_id
  FROM decision_records dr
  WHERE dr.record_id = p_record_id
    AND dr.user_stable_id = p_user_stable_id
    AND dr.actionability = 'material_action'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECORD_INVALID';
  END IF;

  p_ttl_seconds := LEAST(1800, GREATEST(1, COALESCE(p_ttl_seconds, 1800)));

  SELECT cn.nonce, cn.expires_at
  INTO v_nonce, v_expires_at
  FROM consent_nonces cn
  WHERE cn.user_stable_id = p_user_stable_id
    AND cn.session_id = p_session_id
    AND cn.recommendation_id = v_recommendation_id
    AND cn.action_hash = p_action_hash
    AND cn.used_at IS NULL
    AND now() < cn.expires_at
  LIMIT 1;

  IF FOUND THEN
    RETURN QUERY
    SELECT v_nonce, v_expires_at, NULL::bigint, true;
    RETURN;
  END IF;

  -- Nonce itself is random; binding is enforced at confirm time.
  v_nonce := encode(gen_random_bytes(32), 'hex');
  v_expires_at := now() + make_interval(secs => p_ttl_seconds);

  BEGIN
    INSERT INTO consent_nonces(
      nonce, user_stable_id, session_id, recommendation_id, action_hash, created_at, expires_at
    ) VALUES (
      v_nonce, p_user_stable_id, p_session_id, v_recommendation_id, p_action_hash, now(), v_expires_at
    );
  EXCEPTION
    WHEN unique_violation THEN
      SELECT cn.nonce, cn.expires_at
      INTO v_nonce, v_expires_at
      FROM consent_nonces cn
      WHERE cn.user_stable_id = p_user_stable_id
        AND cn.session_id = p_session_id
        AND cn.recommendation_id = v_recommendation_id
        AND cn.action_hash = p_action_hash
        AND cn.used_at IS NULL
      ORDER BY cn.created_at DESC
      LIMIT 1;

      IF NOT FOUND THEN
        RAISE;
      END IF;
  END;

  SELECT public.log_event(
    p_user_stable_id,
    'consent_nonce_created',
    jsonb_build_object(
      'nonce_hash', encode(digest(v_nonce::bytea, 'sha256'), 'hex'),
      'record_id', p_record_id,
      'session_id', p_session_id,
      'recommendation_id', v_recommendation_id,
      'action_hash', p_action_hash,
      'expires_at', v_expires_at
    ),
    encode(digest(v_nonce || p_record_id::text || now()::text, 'sha256'), 'hex')
  ) INTO v_event_id;

  RETURN QUERY
  SELECT v_nonce, v_expires_at, v_event_id, false;
END;
$$;

CREATE OR REPLACE FUNCTION public.confirm_material_action(
  p_record_id uuid,
  p_nonce text,
  p_session_id text,
  p_recommendation_id text,
  p_action_hash text
)
RETURNS TABLE (
  status text,
  confirmed_at timestamptz,
  event_id bigint
)
LANGUAGE plpgsql
AS $$
DECLARE
  v_user_stable_id uuid;
  v_rows integer;
  v_event_id bigint;
  v_nonce_user uuid;
  v_nonce_session text;
  v_nonce_recommendation text;
  v_nonce_action_hash text;
  v_nonce_used_at timestamptz;
  v_nonce_expires_at timestamptz;
BEGIN
  SELECT dr.user_stable_id
  INTO v_user_stable_id
  FROM decision_records dr
  WHERE dr.record_id = p_record_id
    AND dr.actionability = 'material_action'
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RECORD_INVALID';
  END IF;

  UPDATE consent_nonces cn
  SET used_at = now()
  WHERE cn.nonce = p_nonce
    AND cn.user_stable_id = v_user_stable_id
    AND cn.session_id = p_session_id
    AND cn.recommendation_id = p_recommendation_id
    AND cn.action_hash = p_action_hash
    AND cn.used_at IS NULL
    AND now() < cn.expires_at;

  GET DIAGNOSTICS v_rows = ROW_COUNT;

  IF v_rows = 0 THEN
    SELECT
      cn.user_stable_id,
      cn.session_id,
      cn.recommendation_id,
      cn.action_hash,
      cn.used_at,
      cn.expires_at
    INTO
      v_nonce_user,
      v_nonce_session,
      v_nonce_recommendation,
      v_nonce_action_hash,
      v_nonce_used_at,
      v_nonce_expires_at
    FROM consent_nonces cn
    WHERE cn.nonce = p_nonce;

    IF NOT FOUND THEN
      RAISE EXCEPTION 'NONCE_INVALID';
    ELSIF now() >= v_nonce_expires_at THEN
      RAISE EXCEPTION 'CONSENT_EXPIRED';
    ELSIF v_nonce_used_at IS NOT NULL THEN
      RAISE EXCEPTION 'NONCE_REPLAY';
    ELSIF v_nonce_user IS DISTINCT FROM v_user_stable_id
       OR v_nonce_session IS DISTINCT FROM p_session_id
       OR v_nonce_recommendation IS DISTINCT FROM p_recommendation_id
       OR v_nonce_action_hash IS DISTINCT FROM p_action_hash THEN
      RAISE EXCEPTION 'NONCE_BINDING_MISMATCH';
    ELSE
      RAISE EXCEPTION 'NONCE_BINDING_MISMATCH';
    END IF;
  END IF;

  UPDATE decision_records dr
  SET consent_nonce = COALESCE(dr.consent_nonce, p_nonce),
      material_action_confirmed = true
  WHERE dr.record_id = p_record_id;

  SELECT public.log_event(
    v_user_stable_id,
    'decision_confirmed',
    jsonb_build_object(
      'record_id', p_record_id,
      'recommendation_id', p_recommendation_id,
      'session_id', p_session_id,
      'action_hash', p_action_hash,
      'nonce_hash', encode(digest(p_nonce::bytea, 'sha256'), 'hex')
    ),
    encode(digest(p_nonce || p_record_id::text || now()::text, 'sha256'), 'hex')
  ) INTO v_event_id;

  RETURN QUERY
  SELECT 'confirmed', now(), v_event_id;
END;
$$;
-- -----------------------------------------------------------------------------
-- Onboarding state machine functions
-- -----------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.ensure_onboarding_status(
  p_user_stable_id uuid
)
RETURNS void
LANGUAGE plpgsql
AS $$
BEGIN
  INSERT INTO onboarding_status(user_stable_id, current_step, created_at, updated_at)
  VALUES (p_user_stable_id, 0, now(), now())
  ON CONFLICT (user_stable_id) DO NOTHING;
END;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_step_1_create_profile(
  p_user_stable_id uuid,
  p_declared_values jsonb,
  p_preferences jsonb,
  p_current_jurisdiction text,
  p_is_owner boolean
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_step integer;
  v_profile_id bigint;
  v_event_id bigint;
BEGIN
  IF NOT p_is_owner THEN
    RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
  END IF;

  INSERT INTO users(stable_id, current_jurisdiction)
  VALUES (p_user_stable_id, p_current_jurisdiction)
  ON CONFLICT (stable_id)
  DO UPDATE SET current_jurisdiction = EXCLUDED.current_jurisdiction, updated_at = now();

  PERFORM public.ensure_onboarding_status(p_user_stable_id);

  SELECT os.current_step
  INTO v_step
  FROM onboarding_status os
  WHERE os.user_stable_id = p_user_stable_id
  FOR UPDATE;

  IF v_step NOT IN (0, 1) THEN
    RAISE EXCEPTION 'STEP_OUT_OF_ORDER';
  END IF;

  IF v_step = 1 THEN
    SELECT up.profile_id
    INTO v_profile_id
    FROM user_profiles up
    WHERE up.user_stable_id = p_user_stable_id
    ORDER BY up.version DESC
    LIMIT 1;
  ELSE
    INSERT INTO user_profiles(
      user_stable_id, version, declared_values, preferences, last_const_check, created_at, updated_at
    )
    VALUES (
      p_user_stable_id, 1, COALESCE(p_declared_values, '[]'::jsonb), COALESCE(p_preferences, '{}'::jsonb), now(), now(), now()
    )
    RETURNING profile_id INTO v_profile_id;

    UPDATE onboarding_status
    SET current_step = 1, updated_at = now()
    WHERE user_stable_id = p_user_stable_id;
  END IF;

  SELECT public.log_event(
    p_user_stable_id,
    'profile_created',
    jsonb_build_object('profile_id', v_profile_id),
    NULL
  ) INTO v_event_id;

  RETURN jsonb_build_object(
    'step', 1,
    'status', 'ok',
    'user_stable_id', p_user_stable_id,
    'next_step', 2,
    'profile_id', v_profile_id,
    'audit', jsonb_build_object('event_id', v_event_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_step_2_add_boundaries(
  p_user_stable_id uuid,
  p_boundaries jsonb,
  p_caller_node_id uuid DEFAULT NULL,
  p_is_owner boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_step integer;
  v_primarch_node uuid;
  v_is_primarch boolean := false;
  v_added_count integer;
  v_event_id bigint;
BEGIN
  PERFORM public.ensure_onboarding_status(p_user_stable_id);

  SELECT os.current_step, os.primarch_node_id
  INTO v_step, v_primarch_node
  FROM onboarding_status os
  WHERE os.user_stable_id = p_user_stable_id
  FOR UPDATE;

  IF p_caller_node_id IS NOT NULL THEN
    v_is_primarch := public.is_active_primarch(p_user_stable_id, p_caller_node_id);
  END IF;

  IF v_step NOT IN (1, 2) THEN
    RAISE EXCEPTION 'STEP_OUT_OF_ORDER';
  END IF;

  IF v_primarch_node IS NULL THEN
    IF NOT p_is_owner AND NOT v_is_primarch THEN
      RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
    END IF;
  ELSE
    IF NOT v_is_primarch THEN
      RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
    END IF;
  END IF;

  WITH parsed AS (
    SELECT trim(x->>'text') AS boundary_text
    FROM jsonb_array_elements(COALESCE(p_boundaries, '[]'::jsonb)) x
  ),
  inserted AS (
    INSERT INTO hard_boundaries(boundary_id, user_stable_id, text, status, created_at)
    SELECT gen_random_uuid(), p_user_stable_id, p.boundary_text, 'active', now()
    FROM parsed p
    WHERE p.boundary_text <> ''
    ON CONFLICT DO NOTHING
    RETURNING boundary_id
  )
  SELECT COUNT(*) INTO v_added_count FROM inserted;

  UPDATE onboarding_status
  SET current_step = 2, updated_at = now()
  WHERE user_stable_id = p_user_stable_id;

  SELECT public.log_event(
    p_user_stable_id,
    'boundaries_added',
    jsonb_build_object('added_count', v_added_count),
    NULL
  ) INTO v_event_id;

  RETURN jsonb_build_object(
    'step', 2,
    'status', 'ok',
    'user_stable_id', p_user_stable_id,
    'next_step', 3,
    'added_count', v_added_count,
    'audit', jsonb_build_object('event_id', v_event_id)
  );
END;
$$;
CREATE OR REPLACE FUNCTION public.onboarding_step_3_create_policy(
  p_user_stable_id uuid,
  p_non_negotiables jsonb,
  p_escalation_rules jsonb,
  p_consent_requirements jsonb,
  p_caller_node_id uuid DEFAULT NULL,
  p_is_owner boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_step integer;
  v_primarch_node uuid;
  v_is_primarch boolean := false;
  v_policy_id uuid;
  v_event_id bigint;
BEGIN
  PERFORM public.ensure_onboarding_status(p_user_stable_id);

  SELECT os.current_step, os.primarch_node_id
  INTO v_step, v_primarch_node
  FROM onboarding_status os
  WHERE os.user_stable_id = p_user_stable_id
  FOR UPDATE;

  IF p_caller_node_id IS NOT NULL THEN
    v_is_primarch := public.is_active_primarch(p_user_stable_id, p_caller_node_id);
  END IF;

  IF v_step NOT IN (2, 3) THEN
    RAISE EXCEPTION 'STEP_OUT_OF_ORDER';
  END IF;

  IF v_primarch_node IS NULL THEN
    IF NOT p_is_owner AND NOT v_is_primarch THEN
      RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
    END IF;
  ELSE
    IF NOT v_is_primarch THEN
      RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
    END IF;
  END IF;

  IF v_step = 3 THEN
    SELECT po.policy_id
    INTO v_policy_id
    FROM policy_objects po
    WHERE po.user_stable_id = p_user_stable_id
    ORDER BY po.policy_version DESC
    LIMIT 1;
  ELSE
    INSERT INTO policy_objects(
      policy_id, user_stable_id, non_negotiables, escalation_rules, policy_version, last_updated
    )
    VALUES (
      gen_random_uuid(),
      p_user_stable_id,
      COALESCE(p_non_negotiables, '[]'::jsonb),
      COALESCE(p_escalation_rules, '[]'::jsonb),
      1,
      now()
    )
    RETURNING policy_id INTO v_policy_id;

    INSERT INTO policy_consent_rules(policy_id, domain, read_level, write_level, share_level, act_level)
    SELECT
      v_policy_id,
      r.domain,
      r.read_level,
      r.write_level,
      r.share_level,
      r.act_level
    FROM jsonb_to_recordset(COALESCE(p_consent_requirements, '[]'::jsonb)) AS r(
      domain text,
      read_level text,
      write_level text,
      share_level text,
      act_level text
    );

    UPDATE onboarding_status
    SET current_step = 3, updated_at = now()
    WHERE user_stable_id = p_user_stable_id;
  END IF;

  SELECT public.log_event(
    p_user_stable_id,
    'policy_created',
    jsonb_build_object('policy_id', v_policy_id),
    NULL
  ) INTO v_event_id;

  RETURN jsonb_build_object(
    'step', 3,
    'status', 'ok',
    'user_stable_id', p_user_stable_id,
    'next_step', 4,
    'policy_id', v_policy_id,
    'audit', jsonb_build_object('event_id', v_event_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_step_4_create_primarch(
  p_user_stable_id uuid,
  p_name_or_alias text,
  p_relationship_type text DEFAULT 'chosen',
  p_verification_level text DEFAULT 'primarch_verified',
  p_consent_scope jsonb DEFAULT '{"read":["*"],"write":["*"],"share":["*"],"act":["*"]}'::jsonb,
  p_caller_node_id uuid DEFAULT NULL,
  p_is_owner boolean DEFAULT false
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_step integer;
  v_existing_primarch uuid;
  v_is_primarch boolean := false;
  v_node_id uuid;
  v_event_id bigint;
BEGIN
  PERFORM public.ensure_onboarding_status(p_user_stable_id);

  SELECT os.current_step
  INTO v_step
  FROM onboarding_status os
  WHERE os.user_stable_id = p_user_stable_id
  FOR UPDATE;

  IF p_caller_node_id IS NOT NULL THEN
    v_is_primarch := public.is_active_primarch(p_user_stable_id, p_caller_node_id);
  END IF;

  IF v_step NOT IN (3, 4) THEN
    RAISE EXCEPTION 'STEP_OUT_OF_ORDER';
  END IF;

  IF v_step = 3 THEN
    IF NOT p_is_owner AND NOT v_is_primarch THEN
      RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
    END IF;
  ELSE
    -- Once onboarding is at step 4, primarch governance is mandatory.
    IF NOT v_is_primarch THEN
      RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
    END IF;
  END IF;

  SELECT ln.node_id
  INTO v_existing_primarch
  FROM lineage_nodes ln
  WHERE ln.user_stable_id = p_user_stable_id
    AND ln.governance_role = 'primarch'
    AND ln.status = 'active'
  LIMIT 1;

  IF v_existing_primarch IS NOT NULL THEN
    RAISE EXCEPTION 'PRIMARCH_ALREADY_EXISTS';
  ELSE
    INSERT INTO lineage_nodes(
      node_id, user_stable_id, name_or_alias, relationship_type,
      verification_level, governance_role, consent_scope, status, added_at
    )
    VALUES (
      gen_random_uuid(),
      p_user_stable_id,
      p_name_or_alias,
      p_relationship_type,
      p_verification_level,
      'primarch',
      COALESCE(p_consent_scope, '{"read":["*"],"write":["*"],"share":["*"],"act":["*"]}'::jsonb),
      'active',
      now()
    )
    RETURNING node_id INTO v_node_id;
  END IF;

  UPDATE onboarding_status
  SET current_step = 4,
      primarch_node_id = v_node_id,
      updated_at = now()
  WHERE user_stable_id = p_user_stable_id;

  SELECT public.log_event(
    p_user_stable_id,
    'primarch_created',
    jsonb_build_object('node_id', v_node_id),
    NULL
  ) INTO v_event_id;

  RETURN jsonb_build_object(
    'step', 4,
    'status', 'ok',
    'user_stable_id', p_user_stable_id,
    'next_step', 5,
    'node_id', v_node_id,
    'audit', jsonb_build_object('event_id', v_event_id)
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.onboarding_confirm(
  p_user_stable_id uuid,
  p_caller_node_id uuid,
  p_notes text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
AS $$
DECLARE
  v_step integer;
  v_event_id bigint;
  v_projection jsonb;
BEGIN
  SELECT os.current_step
  INTO v_step
  FROM onboarding_status os
  WHERE os.user_stable_id = p_user_stable_id
  FOR UPDATE;

  IF NOT FOUND OR v_step <> 4 THEN
    RAISE EXCEPTION 'STEP_OUT_OF_ORDER';
  END IF;

  IF NOT public.is_active_primarch(p_user_stable_id, p_caller_node_id) THEN
    RAISE EXCEPTION 'UNAUTHORIZED_GOVERNANCE';
  END IF;

  UPDATE onboarding_status
  SET current_step = 5,
      completed_at = now(),
      confirmed_at = now(),
      updated_at = now()
  WHERE user_stable_id = p_user_stable_id;

  SELECT public.log_event(
    p_user_stable_id,
    'onboarding_completed',
    jsonb_build_object(
      'notes', p_notes,
      'primarch_node_id', p_caller_node_id
    ),
    NULL
  ) INTO v_event_id;

  SELECT public.get_user_projection(p_user_stable_id, p_caller_node_id, 'primarch')
  INTO v_projection;

  RETURN jsonb_build_object(
    'status', 'confirmed',
    'user_stable_id', p_user_stable_id,
    'confirmed_at', now(),
    'projection_snapshot', v_projection,
    'audit', jsonb_build_object('event_id', v_event_id)
  );
END;
$$;

-- Error code mapping reference (API layer):
-- STEP_OUT_OF_ORDER
-- UNAUTHORIZED_GOVERNANCE
-- TICKET_REQUIRED
-- GOVERNANCE_TICKET_INVALID
-- INVALID_MEMORY_STATE_TRANSITION
-- CYCLE_DETECTED
-- RECORD_INVALID
-- NONCE_INVALID
-- CONSENT_EXPIRED
-- NONCE_REPLAY
-- NONCE_BINDING_MISMATCH
-- PRIMARCH_ALREADY_EXISTS
