-- P0 DB checks for HG-MoE v2.2
-- Deterministic PASS/FAIL output for the 12 required checks.
-- Run after sanctum_v2_2_runtime.sql.

DROP TABLE IF EXISTS tmp_p0_results;
CREATE TEMP TABLE tmp_p0_results (
  check_id integer PRIMARY KEY,
  check_name text NOT NULL,
  status text NOT NULL CHECK (status IN ('PASS', 'FAIL')),
  reason text NOT NULL
);

DO $$
DECLARE
  v_user uuid := gen_random_uuid();
  v_user2 uuid := gen_random_uuid();
  v_user3 uuid := gen_random_uuid();

  v_primarch uuid;
  v_advisor uuid;

  v_step jsonb;
  v_proj jsonb;

  v_record_id uuid;
  v_record2 uuid;
  v_record3 uuid;
  v_record4 uuid;

  v_session text := 'p0-session-' || gen_random_uuid()::text;
  v_action_hash text := 'sha256:p0-action';
  v_nonce text;
  v_nonce2 text;
  v_nonce3 text;
  v_nonce_exp text;

  v_conf_status text;
  v_event_id bigint;
  v_dummy text;
  v_exists boolean;
  v_count integer;

  v_sqlstate text;
  v_message text;
BEGIN
  INSERT INTO users(stable_id, current_jurisdiction) VALUES (v_user, 'US-OR') ON CONFLICT DO NOTHING;
  INSERT INTO users(stable_id, current_jurisdiction) VALUES (v_user2, 'US-OR') ON CONFLICT DO NOTHING;
  INSERT INTO users(stable_id, current_jurisdiction) VALUES (v_user3, 'US-OR') ON CONFLICT DO NOTHING;

  -- 1) Happy path onboarding/eval scaffold
  BEGIN
    PERFORM public.onboarding_step_1_create_profile(
      v_user,
      '["family-first","truth-seeking"]'::jsonb,
      '{"tone":"direct","communication_style":"concise","goals_horizon":"long"}'::jsonb,
      'US-OR',
      true
    );

    PERFORM public.onboarding_step_2_add_boundaries(
      v_user,
      '[{"text":"never recommend high-leverage trading"}]'::jsonb,
      NULL,
      true
    );

    PERFORM public.onboarding_step_3_create_policy(
      v_user,
      '["truth over comfort"]'::jsonb,
      '[{"domain":"finance","condition":"amount > 10000","action":"primarch_approval"}]'::jsonb,
      '[{"domain":"finance","read_level":"implicit","write_level":"explicit","share_level":"never","act_level":"explicit"}]'::jsonb,
      NULL,
      true
    );

    SELECT (x->>'node_id')::uuid INTO v_primarch
    FROM public.onboarding_step_4_create_primarch(
      v_user,
      'Primarch (Self)',
      'chosen',
      'primarch_verified',
      '{"read":["*"],"write":["*"],"share":["*"],"act":["*"]}'::jsonb,
      NULL,
      true
    ) x;

    PERFORM public.onboarding_confirm(v_user, v_primarch, 'P0 DB check');

    INSERT INTO decision_records(
      record_id, user_stable_id, session_id, recommendation_id, domain, actionability,
      synthesized_output, constitution_passed
    ) VALUES (
      gen_random_uuid(), v_user, v_session, 'rec-advisory-1', 'finance', 'advisory',
      '{"final_position":"ALLOW","final_risks":[]}'::jsonb,
      true
    ) RETURNING record_id INTO v_record_id;

    SELECT public.get_user_projection(v_user, v_primarch, 'primarch') INTO v_proj;
    IF COALESCE(jsonb_array_length(COALESCE(v_proj->'recent_decisions_summary', '[]'::jsonb)), 0) < 1 THEN
      RAISE EXCEPTION 'projection missing recent decision summary';
    END IF;

    INSERT INTO tmp_p0_results VALUES (1, 'Happy path onboarding/eval', 'PASS', 'Onboarding + projection decision summary succeeded');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (1, 'Happy path onboarding/eval', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- Seed material-action record for nonce checks
  INSERT INTO decision_records(
    record_id, user_stable_id, session_id, recommendation_id, domain, actionability,
    synthesized_output, constitution_passed
  ) VALUES (
    gen_random_uuid(), v_user, v_session, 'rec-material-1', 'finance', 'material_action',
    '{"final_position":"ALLOW_WITH_CONDITIONS","final_risks":["high_financial_risk"]}'::jsonb,
    true
  ) RETURNING record_id INTO v_record2;

  -- 2) Material action nonce confirm
  BEGIN
    SELECT n.nonce INTO v_nonce
    FROM public.create_or_get_consent_nonce(v_user, v_session, v_record2, v_action_hash, 600) n;

    SELECT c.status INTO v_conf_status
    FROM public.confirm_material_action(v_record2, v_nonce, v_session, 'rec-material-1', v_action_hash) c;

    IF v_conf_status <> 'confirmed' THEN
      RAISE EXCEPTION 'material action confirm returned status=%', COALESCE(v_conf_status, '<null>');
    END IF;

    INSERT INTO tmp_p0_results VALUES (2, 'Material action nonce confirm', 'PASS', 'Nonce consumed and decision confirmed');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (2, 'Material action nonce confirm', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 3) Nonce replay rejection
  BEGIN
    BEGIN
      PERFORM * FROM public.confirm_material_action(v_record2, v_nonce, v_session, 'rec-material-1', v_action_hash);
      RAISE EXCEPTION 'expected NONCE_REPLAY';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('NONCE_REPLAY' IN v_message) = 0 THEN
        RAISE EXCEPTION 'unexpected error: %', v_message;
      END IF;
    END;

    INSERT INTO tmp_p0_results VALUES (3, 'Nonce replay rejection', 'PASS', 'Replay correctly rejected');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (3, 'Nonce replay rejection', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 4) Binding mismatch rejection
  BEGIN
    INSERT INTO decision_records(
      record_id, user_stable_id, session_id, recommendation_id, domain, actionability,
      synthesized_output, constitution_passed
    ) VALUES (
      gen_random_uuid(), v_user, v_session, 'rec-material-2', 'finance', 'material_action',
      '{"final_position":"ALLOW_WITH_CONDITIONS","final_risks":[]}'::jsonb,
      true
    ) RETURNING record_id INTO v_record3;

    SELECT n.nonce INTO v_nonce2
    FROM public.create_or_get_consent_nonce(v_user, v_session, v_record3, 'sha256:good', 600) n;

    BEGIN
      PERFORM * FROM public.confirm_material_action(v_record3, v_nonce2, v_session, 'rec-material-2', 'sha256:bad');
      RAISE EXCEPTION 'expected NONCE_BINDING_MISMATCH';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('NONCE_BINDING_MISMATCH' IN v_message) = 0 THEN
        RAISE EXCEPTION 'unexpected error: %', v_message;
      END IF;
    END;

    INSERT INTO tmp_p0_results VALUES (4, 'Nonce binding mismatch rejection', 'PASS', 'Binding mismatch correctly rejected');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (4, 'Nonce binding mismatch rejection', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 5) Expired nonce rejection
  BEGIN
    INSERT INTO decision_records(
      record_id, user_stable_id, session_id, recommendation_id, domain, actionability,
      synthesized_output, constitution_passed
    ) VALUES (
      gen_random_uuid(), v_user, v_session, 'rec-material-3', 'finance', 'material_action',
      '{"final_position":"ALLOW_WITH_CONDITIONS","final_risks":[]}'::jsonb,
      true
    ) RETURNING record_id INTO v_record4;

    SELECT n.nonce INTO v_nonce_exp
    FROM public.create_or_get_consent_nonce(v_user, v_session, v_record4, 'sha256:exp', 1) n;

    PERFORM pg_sleep(2);

    BEGIN
      PERFORM * FROM public.confirm_material_action(v_record4, v_nonce_exp, v_session, 'rec-material-3', 'sha256:exp');
      RAISE EXCEPTION 'expected CONSENT_EXPIRED';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('CONSENT_EXPIRED' IN v_message) = 0 THEN
        RAISE EXCEPTION 'unexpected error: %', v_message;
      END IF;
    END;

    INSERT INTO tmp_p0_results VALUES (5, 'Expired nonce rejection', 'PASS', 'Expired nonce correctly rejected');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (5, 'Expired nonce rejection', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 6) Step-order bypass rejection
  BEGIN
    PERFORM public.onboarding_step_1_create_profile(
      v_user2,
      '["test"]'::jsonb,
      '{"tone":"direct"}'::jsonb,
      'US-OR',
      true
    );

    BEGIN
      PERFORM public.onboarding_step_3_create_policy(
        v_user2,
        '["x"]'::jsonb,
        '[]'::jsonb,
        '[]'::jsonb,
        NULL,
        true
      );
      RAISE EXCEPTION 'expected STEP_OUT_OF_ORDER';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('STEP_OUT_OF_ORDER' IN v_message) = 0 THEN
        RAISE EXCEPTION 'unexpected error: %', v_message;
      END IF;
    END;

    INSERT INTO tmp_p0_results VALUES (6, 'Step-order bypass rejection', 'PASS', 'Out-of-order onboarding blocked');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (6, 'Step-order bypass rejection', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 7) Arbiter veto enforced representation
  BEGIN
    INSERT INTO decision_records(
      record_id, user_stable_id, session_id, recommendation_id, domain, actionability,
      synthesized_output, constitution_passed, risk_flags
    ) VALUES (
      gen_random_uuid(), v_user, v_session, 'rec-arbiter-block', 'finance', 'advisory',
      '{"role":"Noura","final_position":"BLOCK","final_risks":["values_boundary_violation"],"requires_approval":true}'::jsonb,
      false,
      ARRAY['values_boundary_violation']
    ) RETURNING record_id INTO v_record_id;

    SELECT (
      (dr.synthesized_output->>'final_position' = 'BLOCK')
      AND (dr.synthesized_output->>'requires_approval')::boolean = true
      AND EXISTS (
        SELECT 1
        FROM jsonb_array_elements_text(dr.synthesized_output->'final_risks') r(val)
        WHERE r.val = 'values_boundary_violation'
      )
    ) INTO v_exists
    FROM decision_records dr
    WHERE dr.record_id = v_record_id;

    IF NOT COALESCE(v_exists, false) THEN
      RAISE EXCEPTION 'arbiter-veto representation missing required fields';
    END IF;

    INSERT INTO tmp_p0_results VALUES (7, 'Arbiter veto enforced', 'PASS', 'BLOCK + risk + requires_approval persisted');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (7, 'Arbiter veto enforced', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 8) Primarch uniqueness
  BEGIN
    PERFORM public.onboarding_step_1_create_profile(v_user3, '["x"]'::jsonb, '{"tone":"direct"}'::jsonb, 'US-OR', true);
    PERFORM public.onboarding_step_2_add_boundaries(v_user3, '[{"text":"b1"}]'::jsonb, NULL, true);
    PERFORM public.onboarding_step_3_create_policy(v_user3, '["x"]'::jsonb, '[]'::jsonb, '[]'::jsonb, NULL, true);

    SELECT (x->>'node_id')::uuid INTO v_primarch
    FROM public.onboarding_step_4_create_primarch(
      v_user3, 'Primarch-A', 'chosen', 'primarch_verified',
      '{"read":["*"],"write":["*"],"share":["*"],"act":["*"]}'::jsonb,
      NULL, true
    ) x;

    BEGIN
      PERFORM public.onboarding_step_4_create_primarch(
        v_user3, 'Primarch-B', 'chosen', 'primarch_verified',
        '{"read":["*"],"write":["*"],"share":["*"],"act":["*"]}'::jsonb,
        v_primarch, false
      );
      RAISE EXCEPTION 'expected PRIMARCH_ALREADY_EXISTS';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('PRIMARCH_ALREADY_EXISTS' IN v_message) = 0 THEN
        RAISE EXCEPTION 'unexpected error: %', v_message;
      END IF;
    END;

    INSERT INTO tmp_p0_results VALUES (8, 'Primarch uniqueness enforced', 'PASS', 'Second active primarch rejected');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (8, 'Primarch uniqueness enforced', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 9) Projection redaction for non-primarch
  BEGIN
    INSERT INTO memory_items(
      user_stable_id, type, content, source, confidence, sensitivity, retention, provenance_hash, state
    ) VALUES
      (v_user, 'semantic', '{"text":"critical memory"}'::jsonb, 'user_input', 0.9, 'critical', 'forever', encode(digest('crit','sha256'),'hex'), 'active'),
      (v_user, 'semantic', '{"text":"high memory"}'::jsonb, 'user_input', 0.9, 'high', 'forever', encode(digest('high','sha256'),'hex'), 'active');

    INSERT INTO lineage_nodes(
      node_id, user_stable_id, name_or_alias, relationship_type, verification_level,
      governance_role, consent_scope, status
    ) VALUES (
      gen_random_uuid(), v_user, 'Advisor', 'advisor', 'self_declared', 'advisor',
      '{"read":["relationships"],"write":[],"share":[],"act":[]}'::jsonb,
      'active'
    ) RETURNING node_id INTO v_advisor;

    SELECT public.get_user_projection(v_user, v_advisor, 'advisor') INTO v_proj;

    SELECT COUNT(*) INTO v_count
    FROM jsonb_array_elements(COALESCE(v_proj->'active_memories', '[]'::jsonb)) m
    WHERE m->>'sensitivity' = 'critical';

    IF v_count <> 0 THEN
      RAISE EXCEPTION 'critical memory visible to non-primarch';
    END IF;

    INSERT INTO tmp_p0_results VALUES (9, 'Projection redaction non-primarch', 'PASS', 'Critical memories redacted for advisor view');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (9, 'Projection redaction non-primarch', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 10) Explainability-or-block persistence primitives
  BEGIN
    SELECT EXISTS (
      SELECT 1
      FROM information_schema.columns c
      WHERE c.table_schema = 'public'
        AND c.table_name = 'council_views'
        AND c.column_name IN ('assumptions', 'evidence_refs', 'risks', 'policy_checks')
      GROUP BY c.table_name
      HAVING COUNT(*) = 4
    ) INTO v_exists;

    IF NOT COALESCE(v_exists, false) THEN
      RAISE EXCEPTION 'required explainability columns not found';
    END IF;

    INSERT INTO tmp_p0_results VALUES (10, 'Explainability-or-block primitives', 'PASS', 'Council explainability columns present');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (10, 'Explainability-or-block primitives', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 11) Invalid role output resilience (DB contract check)
  BEGIN
    BEGIN
      INSERT INTO council_views(
        record_id, role, position, confidence, assumptions, evidence_refs, risks, recommended_action, policy_checks
      ) VALUES (
        v_record_id,
        'Economist',
        'INVALID_POSITION',
        0.5,
        '[]'::jsonb,
        '[]'::jsonb,
        '[]'::jsonb,
        NULL,
        '{"boundaries_respected":true,"non_negotiables_respected":true,"consent_ok":true}'::jsonb
      );
      RAISE EXCEPTION 'expected council_views position check violation';
    EXCEPTION WHEN check_violation THEN
      NULL;
    END;

    INSERT INTO tmp_p0_results VALUES (11, 'Invalid role output resilience', 'PASS', 'Invalid council position rejected by DB constraint');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (11, 'Invalid role output resilience', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;

  -- 12) Event log immutability
  BEGIN
    INSERT INTO event_log(user_stable_id, event_type, payload)
    VALUES (v_user, 'p0_immutability_seed', '{}'::jsonb)
    RETURNING event_id INTO v_event_id;

    BEGIN
      UPDATE event_log SET payload = '{"mutated":true}'::jsonb WHERE event_id = v_event_id;
      RAISE EXCEPTION 'expected append-only protection on UPDATE';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('append-only' IN lower(v_message)) = 0 THEN
        RAISE EXCEPTION 'unexpected update error: %', v_message;
      END IF;
    END;

    BEGIN
      DELETE FROM event_log WHERE event_id = v_event_id;
      RAISE EXCEPTION 'expected append-only protection on DELETE';
    EXCEPTION WHEN OTHERS THEN
      GET STACKED DIAGNOSTICS v_message = MESSAGE_TEXT;
      IF position('append-only' IN lower(v_message)) = 0 THEN
        RAISE EXCEPTION 'unexpected delete error: %', v_message;
      END IF;
    END;

    INSERT INTO tmp_p0_results VALUES (12, 'Event log immutability', 'PASS', 'UPDATE/DELETE both blocked');
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_sqlstate = RETURNED_SQLSTATE, v_message = MESSAGE_TEXT;
    INSERT INTO tmp_p0_results VALUES (12, 'Event log immutability', 'FAIL', '[' || v_sqlstate || '] ' || v_message);
  END;
END;
$$;

SELECT
  check_id,
  check_name,
  status,
  reason
FROM tmp_p0_results
ORDER BY check_id;

DO $$
DECLARE
  v_failures integer;
BEGIN
  SELECT COUNT(*) INTO v_failures
  FROM tmp_p0_results
  WHERE status = 'FAIL';

  IF v_failures > 0 THEN
    RAISE EXCEPTION 'P0_DB_CHECKS_FAILED: % failing checks', v_failures;
  END IF;
END;
$$;
