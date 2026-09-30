-- TEE CENTRAL
-- MIGRACIÓN 411 — RESULTADOS PARCIALES Y OFICIALES POR CATEGORÍA
--
-- OBJETIVO
-- Permitir publicar una categoría formalmente cerrada como RESULTADO PARCIAL
-- mientras otras categorías continúan su proceso, y posteriormente convertir
-- esa misma publicación en RESULTADO OFICIAL sin duplicar resultados.
--
-- PRINCIPIOS
-- 1. No recalcula resultados: siempre usa el snapshot del cierre formal.
-- 2. PARTIAL = visible al jugador, pero NO completa la publicación formal de ronda.
-- 3. PUBLISHED = publicación OFICIAL y conserva la semántica histórica existente.
-- 4. Una publicación parcial se promueve a oficial sobre la misma fila.
-- 5. No toca motores, desempates, cierres competitivos ni guards deportivos.

BEGIN;

-- ---------------------------------------------------------------------------
-- 1. Ampliar el estado de publicación.
--    PUBLISHED conserva el significado histórico de publicación oficial.
-- ---------------------------------------------------------------------------

ALTER TABLE public.tournament_round_category_publications
    DROP CONSTRAINT IF EXISTS tournament_round_category_publications_publication_status_check;

ALTER TABLE public.tournament_round_category_publications
    ADD CONSTRAINT tournament_round_category_publications_publication_status_check
    CHECK (publication_status IN ('PARTIAL','PUBLISHED'));

COMMENT ON COLUMN public.tournament_round_category_publications.publication_status IS
'PARTIAL = resultado parcial visible al jugador; PUBLISHED = resultado oficial de la categoría/ronda.';

-- ---------------------------------------------------------------------------
-- 2. Publicación PARCIAL por categoría.
--    Sólo puede existir después del cierre formal FINAL de la categoría.
--    Es idempotente: si ya existe PARTIAL o PUBLISHED, no duplica la fila.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publicar_resultados_parciales_categoria_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_category_tournament_id uuid;
    v_admin_id uuid;
    v_closure public.tournament_round_category_competitive_closures%ROWTYPE;
    v_publication public.tournament_round_category_publications%ROWTYPE;
    v_publication_snapshot jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL OR p_tournament_category_id IS NULL THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true
     FOR UPDATE;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT tc.tournament_id
      INTO v_category_tournament_id
      FROM public.tournament_categories tc
     WHERE tc.id=p_tournament_category_id;

    IF v_category_tournament_id IS NULL
       OR v_category_tournament_id <> v_tournament_id THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo de la ronda.'
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

    SELECT p.*
      INTO v_publication
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id;

    -- Si ya existe publicación parcial u oficial, no duplicar ni degradar.
    IF v_publication.id IS NOT NULL THEN
        RETURN public.obtener_reporte_cierre_categoria_ronda(
            p_tournament_round_id,
            p_tournament_category_id
        );
    END IF;

    SELECT c.*
      INTO v_closure
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id
       AND c.tournament_category_id=p_tournament_category_id;

    IF v_closure.id IS NULL THEN
        RAISE EXCEPTION
            'La categoría debe cerrarse competitivamente antes de publicar resultados parciales.'
            USING ERRCODE='23514';
    END IF;

    IF v_closure.competitive_status IS DISTINCT FROM 'FINAL' THEN
        RAISE EXCEPTION
            'El cierre formal de la categoría no está en estado FINAL.'
            USING ERRCODE='23514';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo=true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    v_publication_snapshot :=
        jsonb_build_object(
            'schemaVersion',1,
            'source','CATEGORY_COMPETITIVE_CLOSURE',
            'publicationType','PARTIAL',
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

    INSERT INTO public.tournament_round_category_publications(
        tournament_id,
        tournament_round_id,
        tournament_category_id,
        category_closure_id,
        publication_status,
        publication_snapshot,
        published_by_admin_user_id,
        notes
    )
    VALUES(
        v_tournament_id,
        p_tournament_round_id,
        p_tournament_category_id,
        v_closure.id,
        'PARTIAL',
        v_publication_snapshot,
        v_admin_id,
        NULLIF(btrim(COALESCE(p_notas,'')),'')
    );

    RETURN public.obtener_reporte_cierre_categoria_ronda(
        p_tournament_round_id,
        p_tournament_category_id
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.publicar_resultados_parciales_categoria_ronda(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publicar_resultados_parciales_categoria_ronda(uuid,uuid,text)
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 3. Publicación OFICIAL existente.
--    Si encuentra PARTIAL, la PROMUEVE a PUBLISHED sobre la misma fila.
--    Si ya está PUBLISHED, permanece idempotente.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.publicar_resultados_categoria_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_notas text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_category_tournament_id uuid;
    v_admin_id uuid;
    v_closure public.tournament_round_category_competitive_closures%ROWTYPE;
    v_publication public.tournament_round_category_publications%ROWTYPE;
    v_publication_snapshot jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL OR p_tournament_category_id IS NULL THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true
     FOR UPDATE;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT tc.tournament_id
      INTO v_category_tournament_id
      FROM public.tournament_categories tc
     WHERE tc.id=p_tournament_category_id;

    IF v_category_tournament_id IS NULL
       OR v_category_tournament_id <> v_tournament_id THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo de la ronda.'
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

    SELECT c.*
      INTO v_closure
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id
       AND c.tournament_category_id=p_tournament_category_id;

    IF v_closure.id IS NULL THEN
        RAISE EXCEPTION
            'La categoría debe cerrarse competitivamente antes de publicar sus resultados.'
            USING ERRCODE='23514';
    END IF;

    IF v_closure.competitive_status IS DISTINCT FROM 'FINAL' THEN
        RAISE EXCEPTION
            'El cierre formal de la categoría no está en estado FINAL.'
            USING ERRCODE='23514';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id=auth.uid()
       AND au.activo=true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'No se encontró el usuario administrativo autenticado.'
            USING ERRCODE='42501';
    END IF;

    SELECT p.*
      INTO v_publication
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id
     FOR UPDATE;

    IF v_publication.id IS NOT NULL
       AND v_publication.publication_status='PUBLISHED' THEN
        RETURN public.obtener_reporte_cierre_categoria_ronda(
            p_tournament_round_id,
            p_tournament_category_id
        );
    END IF;

    v_publication_snapshot :=
        jsonb_build_object(
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
        -- Promoción PARTIAL -> PUBLISHED. La fila y la evidencia deportiva
        -- permanecen asociadas al mismo cierre formal.
        UPDATE public.tournament_round_category_publications
           SET publication_status='PUBLISHED',
               publication_snapshot=v_publication_snapshot,
               published_at=now(),
               published_by_admin_user_id=v_admin_id,
               notes=COALESCE(
                   NULLIF(btrim(COALESCE(p_notas,'')),''),
                   notes
               )
         WHERE id=v_publication.id;
    ELSE
        INSERT INTO public.tournament_round_category_publications(
            tournament_id,
            tournament_round_id,
            tournament_category_id,
            category_closure_id,
            publication_status,
            publication_snapshot,
            published_by_admin_user_id,
            notes
        )
        VALUES(
            v_tournament_id,
            p_tournament_round_id,
            p_tournament_category_id,
            v_closure.id,
            'PUBLISHED',
            v_publication_snapshot,
            v_admin_id,
            NULLIF(btrim(COALESCE(p_notas,'')),'')
        );
    END IF;

    RETURN public.obtener_reporte_cierre_categoria_ronda(
        p_tournament_round_id,
        p_tournament_category_id
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.publicar_resultados_categoria_ronda(uuid,uuid,text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.publicar_resultados_categoria_ronda(uuid,uuid,text)
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 4. Lectura para jugador: devuelve PARTIAL u OFFICIAL.
--    Los resultados visibles siguen saliendo del snapshot congelado del cierre.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_resultados_publicados_categoria_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_publication public.tournament_round_category_publications%ROWTYPE;
    v_closure_snapshot jsonb;
    v_publication_type text;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL OR p_tournament_category_id IS NULL THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT p.*
      INTO v_publication
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id
       AND p.publication_status IN ('PARTIAL','PUBLISHED');

    IF v_publication.id IS NULL THEN
        RETURN jsonb_build_object(
            'schemaVersion',2,
            'published',false,
            'publicationType',NULL,
            'tournamentRoundId',p_tournament_round_id,
            'tournamentCategoryId',p_tournament_category_id,
            'publication',NULL,
            'results',NULL
        );
    END IF;

    v_publication_type :=
        CASE
            WHEN v_publication.publication_status='PUBLISHED'
                THEN 'OFFICIAL'
            ELSE 'PARTIAL'
        END;

    v_closure_snapshot :=
        v_publication.publication_snapshot->'closureSnapshot';

    RETURN jsonb_build_object(
        'schemaVersion',2,
        'published',true,
        'publicationType',v_publication_type,
        'tournamentRoundId',p_tournament_round_id,
        'tournamentCategoryId',p_tournament_category_id,
        'publication',
            jsonb_build_object(
                'id',v_publication.id,
                'status',v_publication.publication_status,
                'type',v_publication_type,
                'publishedAt',v_publication.published_at
            ),
        'results',
            jsonb_build_object(
                'round',v_closure_snapshot->'round',
                'categoryState',v_closure_snapshot->'categoryState',
                'leaderboardCategory',v_closure_snapshot->'leaderboardCategory'
            )
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_resultados_publicados_categoria_ronda(uuid,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_resultados_publicados_categoria_ronda(uuid,uuid)
    TO authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 5. Selector de categorías publicadas para la aplicación del jugador.
--    Devuelve únicamente categorías con resultado visible, sean parciales
--    u oficiales. El jugador no queda limitado a su propia categoría.
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.obtener_categorias_resultados_publicados_ronda_411(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament_id uuid;
    v_categories jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL THEN
        RAISE EXCEPTION
            'tournament_round_id es obligatorio.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id
       AND tr.activo=true;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe o no está activa.'
            USING ERRCODE='22023';
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            jsonb_build_object(
                'tournamentCategoryId',tc.id,
                'categoryId',c.id,
                'categoryCode',c.codigo,
                'categoryName',c.nombre,
                'displayOrder',c.display_order,
                'publicationType',
                    CASE
                        WHEN p.publication_status='PUBLISHED'
                            THEN 'OFFICIAL'
                        ELSE 'PARTIAL'
                    END,
                'publicationStatus',p.publication_status,
                'publishedAt',p.published_at
            )
            ORDER BY c.display_order NULLS LAST, c.nombre, c.codigo
        ),
        '[]'::jsonb
    )
    INTO v_categories
    FROM public.tournament_round_category_publications p
    JOIN public.tournament_categories tc
      ON tc.id=p.tournament_category_id
    JOIN public.categories c
      ON c.id=tc.category_id
    WHERE p.tournament_round_id=p_tournament_round_id
      AND p.tournament_id=v_tournament_id
      AND p.publication_status IN ('PARTIAL','PUBLISHED');

    RETURN jsonb_build_object(
        'schemaVersion',1,
        'tournamentRoundId',p_tournament_round_id,
        'tournamentId',v_tournament_id,
        'categories',v_categories
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_categorias_resultados_publicados_ronda_411(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_categorias_resultados_publicados_ronda_411(uuid)
    TO authenticated, service_role;

COMMIT;
