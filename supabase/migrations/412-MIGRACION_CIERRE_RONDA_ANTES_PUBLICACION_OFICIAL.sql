-- TEE CENTRAL
-- MIGRACIÓN 412 — CIERRE DE RONDA ANTES DE PUBLICACIÓN OFICIAL
--
-- SECUENCIA:
-- CERRAR CATEGORÍAS -> [PUBLICACIONES PARCIALES OPCIONALES] ->
-- CERRAR RONDA -> PUBLICAR RESULTADOS OFICIALES
--
-- IMPORTANTE:
-- - No modifica motores deportivos ni desempates.
-- - Las publicaciones parciales siguen siendo opcionales.
-- - La publicación oficial requiere cierre competitivo FINAL de la ronda.
-- - El cierre de ronda deja de exigir publicaciones oficiales.
-- - Corrige exclusivamente la publicación de prueba A de PRUEBA AUTOSERVICIO #3.

BEGIN;

-- 1) El cierre competitivo de ronda ya NO depende de publicaciones oficiales.
CREATE OR REPLACE FUNCTION public._cerrar_ronda_competitiva_pre314(
    p_tournament_round_id uuid,
    p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_round_number integer;
    v_round_date date;
    v_tournament_status public.estatus_torneo;
    v_admin_id uuid;
    v_state jsonb;
    v_competitive_status text;
    v_closure_id uuid;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    SELECT tr.tournament_id,tr.numero_ronda,tr.fecha,t.estatus
      INTO v_tournament_id,v_round_number,v_round_date,v_tournament_status
      FROM public.tournament_rounds tr
      JOIN public.tournaments t ON t.id=tr.tournament_id
     WHERE tr.id=p_tournament_round_id AND tr.activo=true
     FOR UPDATE OF tr,t;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
        USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),v_tournament_id)
    ) THEN
        RAISE EXCEPTION
        'Sólo el organizador asignado o el Superadmin pueden cerrar competitivamente la ronda.'
        USING ERRCODE='42501';
    END IF;

    SELECT c.id INTO v_closure_id
      FROM public.tournament_round_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id;

    IF v_closure_id IS NOT NULL THEN
        RETURN public.obtener_cierre_formal_ronda(p_tournament_round_id);
    END IF;

    IF v_tournament_status <> 'en_curso'::public.estatus_torneo THEN
        RAISE EXCEPTION
        'La ronda sólo puede cerrarse formalmente cuando el torneo está EN CURSO. Estado actual: %.',
        v_tournament_status USING ERRCODE='23514';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    v_state := public.obtener_estado_cierre_competitivo_ronda(p_tournament_round_id);
    v_competitive_status := v_state#>>'{status,competitiveStatus}';

    IF v_competitive_status='CATEGORIES_PENDING' THEN
        RAISE EXCEPTION
        'La ronda todavía no puede cerrarse: faltan cierres formales de categoría.'
        USING ERRCODE='23514',
        DETAIL=COALESCE((v_state->'formalization')::text,v_state::text),
        HINT='Cierra formalmente todas las categorías antes de cerrar la ronda.';
    END IF;

    -- 412:
    -- PUBLICATIONS_PENDING ya NO bloquea el cierre de ronda.
    -- Las publicaciones oficiales ocurren DESPUÉS del cierre.
    IF v_competitive_status NOT IN ('FINAL','PUBLICATIONS_PENDING') THEN
        RAISE EXCEPTION
        'La ronda todavía no puede cerrarse competitivamente.'
        USING ERRCODE='23514',
        DETAIL=v_state::text,
        HINT='Todas las tarjetas, categorías y desempates deben estar resueltos antes de formalizar el cierre.';
    END IF;

    SELECT au.id INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid() AND au.activo=true
     ORDER BY au.id LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró el usuario administrativo autenticado.'
        USING ERRCODE='42501';
    END IF;

    INSERT INTO public.tournament_round_competitive_closures(
        tournament_id,tournament_round_id,round_number,round_date,
        competitive_status,closure_snapshot,closed_by_admin_user_id,notes
    )
    VALUES(
        v_tournament_id,p_tournament_round_id,v_round_number,v_round_date,
        'FINAL',v_state,v_admin_id,NULLIF(btrim(COALESCE(p_notas,'')),'')
    )
    RETURNING id INTO v_closure_id;

    RETURN public.obtener_cierre_formal_ronda(p_tournament_round_id);
END;
$function$;

-- 2) Publicación oficial: requiere cierre competitivo FINAL de la ronda.
CREATE OR REPLACE FUNCTION public.publicar_resultados_categoria_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_category_tournament_id uuid;
    v_admin_id uuid;
    v_closure public.tournament_round_category_competitive_closures%ROWTYPE;
    v_publication public.tournament_round_category_publications%ROWTYPE;
    v_publication_snapshot jsonb;
    v_round_closed boolean;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL OR p_tournament_category_id IS NULL THEN
        RAISE EXCEPTION 'tournament_round_id y tournament_category_id son obligatorios.'
        USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id AND tr.activo=true
     FOR UPDATE;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La ronda indicada no existe o no está activa.'
        USING ERRCODE='22023';
    END IF;

    SELECT EXISTS(
        SELECT 1
          FROM public.tournament_round_competitive_closures rc
         WHERE rc.tournament_round_id=p_tournament_round_id
           AND rc.competitive_status='FINAL'
    ) INTO v_round_closed;

    IF NOT v_round_closed THEN
        RAISE EXCEPTION
        'Los resultados oficiales sólo pueden publicarse después del cierre competitivo de la ronda.'
        USING ERRCODE='23514',
        HINT='Cierra primero la ronda. Mientras permanezca abierta sólo pueden publicarse resultados parciales.';
    END IF;

    SELECT tc.tournament_id INTO v_category_tournament_id
      FROM public.tournament_categories tc
     WHERE tc.id=p_tournament_category_id;

    IF v_category_tournament_id IS NULL OR v_category_tournament_id<>v_tournament_id THEN
        RAISE EXCEPTION 'La categoría indicada no pertenece al torneo de la ronda.'
        USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(auth.uid(),v_tournament_id)
    ) THEN
        RAISE EXCEPTION
        'Sólo el organizador asignado o el Superadmin pueden publicar resultados de la categoría.'
        USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(p_tournament_round_id);

    SELECT c.* INTO v_closure
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id
       AND c.tournament_category_id=p_tournament_category_id;

    IF v_closure.id IS NULL OR v_closure.competitive_status IS DISTINCT FROM 'FINAL' THEN
        RAISE EXCEPTION
        'La categoría debe tener cierre competitivo FINAL antes de publicar resultados oficiales.'
        USING ERRCODE='23514';
    END IF;

    SELECT au.id INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid() AND au.activo=true
     ORDER BY au.id LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION 'No se encontró el usuario administrativo autenticado.'
        USING ERRCODE='42501';
    END IF;

    SELECT p.* INTO v_publication
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id
     FOR UPDATE;

    IF v_publication.id IS NOT NULL AND v_publication.publication_status='PUBLISHED' THEN
        RETURN public.obtener_reporte_cierre_categoria_ronda(
            p_tournament_round_id,p_tournament_category_id
        );
    END IF;

    v_publication_snapshot := jsonb_build_object(
        'schemaVersion',1,
        'source','CATEGORY_COMPETITIVE_CLOSURE',
        'publicationType','OFFICIAL',
        'categoryClosureId',v_closure.id,
        'tournamentId',v_closure.tournament_id,
        'tournamentRoundId',v_closure.tournament_round_id,
        'tournamentCategoryId',v_closure.tournament_category_id,
        'roundNumber',v_closure.round_number,
        'roundDate',v_closure.round_date,
        'competitiveStatus',v_closure.competitive_status,
        'closedAt',v_closure.closed_at,
        'closureSnapshot',v_closure.closure_snapshot
    );

    IF v_publication.id IS NOT NULL THEN
        UPDATE public.tournament_round_category_publications
           SET publication_status='PUBLISHED',
               publication_snapshot=v_publication_snapshot,
               published_at=now(),
               published_by_admin_user_id=v_admin_id,
               notes=COALESCE(NULLIF(btrim(COALESCE(p_notas,'')),''),notes)
         WHERE id=v_publication.id;
    ELSE
        INSERT INTO public.tournament_round_category_publications(
            tournament_id,tournament_round_id,tournament_category_id,
            category_closure_id,publication_status,publication_snapshot,
            published_by_admin_user_id,notes
        )
        VALUES(
            v_tournament_id,p_tournament_round_id,p_tournament_category_id,
            v_closure.id,'PUBLISHED',v_publication_snapshot,
            v_admin_id,NULLIF(btrim(COALESCE(p_notas,'')),'')
        );
    END IF;

    RETURN public.obtener_reporte_cierre_categoria_ronda(
        p_tournament_round_id,p_tournament_category_id
    );
END;
$function$;

-- 3) Reparación controlada de la publicación de prueba de categoría A.
--    Sólo actúa sobre PRUEBA AUTOSERVICIO #3 / Ronda 1 y sólo si:
--    - la ronda todavía NO está cerrada;
--    - la publicación está PUBLISHED;
--    - el snapshot fue marcado OFFICIAL.
UPDATE public.tournament_round_category_publications p
   SET publication_status='PARTIAL',
       publication_snapshot=jsonb_set(
           p.publication_snapshot,
           '{publicationType}',
           '"PARTIAL"'::jsonb,
           true
       )
 WHERE p.tournament_round_id='c019d12c-e8c9-46a2-b99d-444b1be4d433'::uuid
   AND p.publication_status='PUBLISHED'
   AND p.publication_snapshot->>'publicationType'='OFFICIAL'
   AND EXISTS (
       SELECT 1
       FROM public.tournament_categories tc
       JOIN public.categories c ON c.id=tc.category_id
       WHERE tc.id=p.tournament_category_id
         AND c.codigo='A'
   )
   AND NOT EXISTS (
       SELECT 1
       FROM public.tournament_round_competitive_closures rc
       WHERE rc.tournament_round_id=p.tournament_round_id
         AND rc.competitive_status='FINAL'
   );

-- 4) Reordenar únicamente la guía maestra:
--    210 Cerrar categorías -> 220 Cerrar ronda -> 230 Publicar resultados.
--    El Asistente sigue siendo guía; la aplicación conserva la autoridad.
-- La restricción UNIQUE(template_id, sequence_no) obliga a intercambiar
-- las secuencias en tres movimientos usando un valor temporal libre.
UPDATE public.workflow_master_nodes n
   SET sequence_no=999,
       display_order=999,
       updated_at=now()
  FROM public.workflow_master_templates t
 WHERE t.id=n.template_id
   AND t.template_code='TEE_CENTRAL_STANDARD'
   AND t.active=true
   AND n.code='ROUND_RESULTS_PUBLICATION'
   AND n.sequence_no=220;

UPDATE public.workflow_master_nodes n
   SET sequence_no=220,
       display_order=220,
       updated_at=now()
  FROM public.workflow_master_templates t
 WHERE t.id=n.template_id
   AND t.template_code='TEE_CENTRAL_STANDARD'
   AND t.active=true
   AND n.code='ROUND_COMPETITIVE_CLOSE'
   AND n.sequence_no=230;

UPDATE public.workflow_master_nodes n
   SET sequence_no=230,
       display_order=230,
       updated_at=now()
  FROM public.workflow_master_templates t
 WHERE t.id=n.template_id
   AND t.template_code='TEE_CENTRAL_STANDARD'
   AND t.active=true
   AND n.code='ROUND_RESULTS_PUBLICATION'
   AND n.sequence_no=999;

COMMIT;
