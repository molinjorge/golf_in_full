-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- Migración 195 Fase 1
-- Publicación y contrato de reporte por categoría
--
-- OBJETIVO
--   Permitir publicar una categoría ya cerrada competitivamente, sin esperar
--   al cierre de las demás categorías de la ronda, y exponer un contrato
--   estable de "CIERRE POR CATEGORÍA" para UI/descarga.
--
-- PRINCIPIOS
--   - Sólo se publica una categoría que ya tenga cierre formal 194.
--   - La publicación es idempotente e irreversible en esta fase.
--   - No recalcula resultados: publica el snapshot inmutable del cierre.
--   - El reporte puede previsualizarse administrativamente antes de publicar.
--   - El resultado publicado sólo se expone cuando existe publicación.
--   - No genera PDF en base de datos; entrega JSON listo para que la UI genere
--     impresión/PDF/Excel posteriormente.
-- ============================================================================

-- ============================================================================
-- 1. TABLA DE PUBLICACIONES POR CATEGORÍA
-- ============================================================================

CREATE TABLE IF NOT EXISTS public.tournament_round_category_publications (
    id uuid PRIMARY KEY DEFAULT gen_random_uuid(),

    tournament_id uuid NOT NULL
        REFERENCES public.tournaments(id),

    tournament_round_id uuid NOT NULL
        REFERENCES public.tournament_rounds(id),

    tournament_category_id uuid NOT NULL
        REFERENCES public.tournament_categories(id),

    category_closure_id uuid NOT NULL
        REFERENCES public.tournament_round_category_competitive_closures(id),

    publication_status text NOT NULL
        CHECK (publication_status = 'PUBLISHED'),

    publication_snapshot jsonb NOT NULL,

    published_at timestamptz NOT NULL DEFAULT now(),

    published_by_admin_user_id uuid NOT NULL
        REFERENCES public.admin_users(id),

    notes text NULL,

    created_at timestamptz NOT NULL DEFAULT now(),

    CONSTRAINT uq_tournament_round_category_publication
        UNIQUE (tournament_round_id, tournament_category_id),

    CONSTRAINT uq_tournament_round_category_publication_closure
        UNIQUE (category_closure_id)
);

CREATE INDEX IF NOT EXISTS
    idx_tournament_round_category_publications_tournament
ON public.tournament_round_category_publications(
    tournament_id
);

CREATE INDEX IF NOT EXISTS
    idx_tournament_round_category_publications_round
ON public.tournament_round_category_publications(
    tournament_round_id
);

CREATE INDEX IF NOT EXISTS
    idx_tournament_round_category_publications_category
ON public.tournament_round_category_publications(
    tournament_category_id
);

ALTER TABLE
    public.tournament_round_category_publications
ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE
    public.tournament_round_category_publications
FROM PUBLIC;

REVOKE ALL ON TABLE
    public.tournament_round_category_publications
FROM anon;

REVOKE ALL ON TABLE
    public.tournament_round_category_publications
FROM authenticated;

GRANT ALL ON TABLE
    public.tournament_round_category_publications
TO service_role;

-- ============================================================================
-- 2. HELPER: ¿ESTÁ PUBLICADA LA CATEGORÍA?
-- ============================================================================

CREATE OR REPLACE FUNCTION
public._categoria_ronda_esta_publicada(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid
)
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
    SELECT EXISTS (
        SELECT 1
        FROM public.tournament_round_category_publications p
        WHERE p.tournament_round_id = p_tournament_round_id
          AND p.tournament_category_id = p_tournament_category_id
          AND p.publication_status = 'PUBLISHED'
    );
$function$;

REVOKE ALL ON FUNCTION
    public._categoria_ronda_esta_publicada(uuid,uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public._categoria_ronda_esta_publicada(uuid,uuid)
FROM anon;

REVOKE ALL ON FUNCTION
    public._categoria_ronda_esta_publicada(uuid,uuid)
FROM authenticated;

GRANT EXECUTE ON FUNCTION
    public._categoria_ronda_esta_publicada(uuid,uuid)
TO service_role;

-- ============================================================================
-- 3. CONSULTA ADMINISTRATIVA DEL REPORTE "CIERRE POR CATEGORÍA"
--
--    Puede consultarse desde el momento en que existe el cierre 194,
--    aun antes de publicación. Esto permite previsualizar/descargar el reporte
--    y decidir después si se publica.
-- ============================================================================

CREATE OR REPLACE FUNCTION
public.obtener_reporte_cierre_categoria_ronda(
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
    v_tournament_id uuid;
    v_closure public.tournament_round_category_competitive_closures%ROWTYPE;
    v_publication public.tournament_round_category_publications%ROWTYPE;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
    THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT tr.tournament_id
      INTO v_tournament_id
      FROM public.tournament_rounds tr
     WHERE tr.id=p_tournament_round_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION
            'La ronda indicada no existe.'
            USING ERRCODE='22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(
        v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No tienes permiso para consultar el reporte de cierre de esta categoría.'
            USING ERRCODE='42501';
    END IF;

    SELECT c.*
      INTO v_closure
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id
       AND c.tournament_category_id=p_tournament_category_id;

    IF v_closure.id IS NULL THEN
        RETURN jsonb_build_object(
            'schemaVersion', 1,
            'reportType', 'CATEGORY_CLOSURE',
            'available', false,
            'published', false,
            'tournamentRoundId', p_tournament_round_id,
            'tournamentCategoryId', p_tournament_category_id,
            'report', NULL
        );
    END IF;

    SELECT p.*
      INTO v_publication
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'reportType', 'CATEGORY_CLOSURE',
        'available', true,
        'published', v_publication.id IS NOT NULL,

        'tournamentRoundId',
            p_tournament_round_id,

        'tournamentCategoryId',
            p_tournament_category_id,

        'closure',
            jsonb_build_object(
                'id', v_closure.id,
                'competitiveStatus', v_closure.competitive_status,
                'closedAt', v_closure.closed_at,
                'closedByAdminUserId', v_closure.closed_by_admin_user_id,
                'notes', v_closure.notes
            ),

        'publication',
            CASE
                WHEN v_publication.id IS NULL
                    THEN NULL
                ELSE jsonb_build_object(
                    'id', v_publication.id,
                    'status', v_publication.publication_status,
                    'publishedAt', v_publication.published_at,
                    'publishedByAdminUserId',
                        v_publication.published_by_admin_user_id,
                    'notes', v_publication.notes
                )
            END,

        'report',
            jsonb_build_object(
                'title', 'CIERRE POR CATEGORÍA',
                'round',
                    v_closure.closure_snapshot->'round',
                'categoryState',
                    v_closure.closure_snapshot->'categoryState',
                'leaderboardCategory',
                    v_closure.closure_snapshot->'leaderboardCategory'
            )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_reporte_cierre_categoria_ronda(uuid,uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.obtener_reporte_cierre_categoria_ronda(uuid,uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.obtener_reporte_cierre_categoria_ronda(uuid,uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.obtener_reporte_cierre_categoria_ronda(uuid,uuid)
TO service_role;

-- ============================================================================
-- 4. PUBLICAR RESULTADOS DE UNA CATEGORÍA
-- ============================================================================

CREATE OR REPLACE FUNCTION
public.publicar_resultados_categoria_ronda(
    p_tournament_round_id uuid,
    p_tournament_category_id uuid,
    p_notas text DEFAULT NULL
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
    v_publication_id uuid;

    v_publication_snapshot jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
    THEN
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
       OR v_category_tournament_id <> v_tournament_id
    THEN
        RAISE EXCEPTION
            'La categoría indicada no pertenece al torneo de la ronda.'
            USING ERRCODE='22023';
    END IF;

    IF NOT (
        public.is_superadmin(auth.uid())
        OR public.is_tournament_organizer(
            auth.uid(),
            v_tournament_id
        )
    ) THEN
        RAISE EXCEPTION
            'Sólo el organizador asignado o el Superadmin pueden publicar resultados de la categoría.'
            USING ERRCODE='42501';
    END IF;

    PERFORM public._bloquear_salida_ronda(
        p_tournament_round_id
    );

    -- Idempotencia.
    SELECT p.id
      INTO v_publication_id
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id;

    IF v_publication_id IS NOT NULL THEN
        RETURN public.obtener_reporte_cierre_categoria_ronda(
            p_tournament_round_id,
            p_tournament_category_id
        );
    END IF;

    -- La publicación depende estrictamente del cierre formal 194.
    SELECT c.*
      INTO v_closure
      FROM public.tournament_round_category_competitive_closures c
     WHERE c.tournament_round_id=p_tournament_round_id
       AND c.tournament_category_id=p_tournament_category_id;

    IF v_closure.id IS NULL THEN
        RAISE EXCEPTION
            'La categoría debe cerrarse competitivamente antes de publicar sus resultados.'
            USING ERRCODE='23514',
                  HINT=
                      'Ejecuta primero el cierre formal por categoría cuando su estado sea READY_TO_CLOSE.';
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

    -- La publicación congela exactamente el cierre formal, sin recalcular.
    v_publication_snapshot :=
        jsonb_build_object(
            'schemaVersion', 1,
            'source', 'CATEGORY_COMPETITIVE_CLOSURE',
            'categoryClosureId', v_closure.id,
            'tournamentId', v_closure.tournament_id,
            'tournamentRoundId', v_closure.tournament_round_id,
            'tournamentCategoryId', v_closure.tournament_category_id,
            'roundNumber', v_closure.round_number,
            'roundDate', v_closure.round_date,
            'competitiveStatus', v_closure.competitive_status,
            'closedAt', v_closure.closed_at,
            'closureSnapshot', v_closure.closure_snapshot
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
        'PUBLISHED',
        v_publication_snapshot,
        v_admin_id,
        NULLIF(
            btrim(COALESCE(p_notas,'')),
            ''
        )
    )
    RETURNING id
    INTO v_publication_id;

    RETURN public.obtener_reporte_cierre_categoria_ronda(
        p_tournament_round_id,
        p_tournament_category_id
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.publicar_resultados_categoria_ronda(uuid,uuid,text)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.publicar_resultados_categoria_ronda(uuid,uuid,text)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.publicar_resultados_categoria_ronda(uuid,uuid,text)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.publicar_resultados_categoria_ronda(uuid,uuid,text)
TO service_role;

-- ============================================================================
-- 5. LECTURA DE RESULTADOS PUBLICADOS PARA USO DE JUGADORES/UI
--
--    No consulta motores ni tablas vivas. Sólo entrega el snapshot publicado.
--    Requiere usuario autenticado; no se abre a anon en esta fase.
-- ============================================================================

CREATE OR REPLACE FUNCTION
public.obtener_resultados_publicados_categoria_ronda(
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
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE='42501';
    END IF;

    IF p_tournament_round_id IS NULL
       OR p_tournament_category_id IS NULL
    THEN
        RAISE EXCEPTION
            'tournament_round_id y tournament_category_id son obligatorios.'
            USING ERRCODE='22023';
    END IF;

    SELECT p.*
      INTO v_publication
      FROM public.tournament_round_category_publications p
     WHERE p.tournament_round_id=p_tournament_round_id
       AND p.tournament_category_id=p_tournament_category_id
       AND p.publication_status='PUBLISHED';

    IF v_publication.id IS NULL THEN
        RETURN jsonb_build_object(
            'schemaVersion', 1,
            'published', false,
            'tournamentRoundId', p_tournament_round_id,
            'tournamentCategoryId', p_tournament_category_id,
            'publication', NULL,
            'results', NULL
        );
    END IF;

    v_closure_snapshot :=
        v_publication.publication_snapshot->'closureSnapshot';

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'published', true,

        'tournamentRoundId',
            p_tournament_round_id,

        'tournamentCategoryId',
            p_tournament_category_id,

        'publication',
            jsonb_build_object(
                'id', v_publication.id,
                'status', v_publication.publication_status,
                'publishedAt', v_publication.published_at
            ),

        'results',
            jsonb_build_object(
                'round',
                    v_closure_snapshot->'round',
                'categoryState',
                    v_closure_snapshot->'categoryState',
                'leaderboardCategory',
                    v_closure_snapshot->'leaderboardCategory'
            )
    );
END;
$function$;

REVOKE ALL ON FUNCTION
    public.obtener_resultados_publicados_categoria_ronda(uuid,uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION
    public.obtener_resultados_publicados_categoria_ronda(uuid,uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION
    public.obtener_resultados_publicados_categoria_ronda(uuid,uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION
    public.obtener_resultados_publicados_categoria_ronda(uuid,uuid)
TO service_role;

COMMENT ON TABLE
    public.tournament_round_category_publications
IS
'Publicación formal e idempotente de resultados cerrados por categoría y ronda.';

COMMENT ON FUNCTION
    public.publicar_resultados_categoria_ronda(uuid,uuid,text)
IS
'Publica resultados de una categoría únicamente después de su cierre formal 194. '
'No recalcula resultados; congela y publica el snapshot del cierre.';

COMMENT ON FUNCTION
    public.obtener_reporte_cierre_categoria_ronda(uuid,uuid)
IS
'Contrato administrativo de reporte CIERRA POR CATEGORÍA. Disponible desde el '
'cierre formal, incluso antes de publicar.';

COMMENT ON FUNCTION
    public.obtener_resultados_publicados_categoria_ronda(uuid,uuid)
IS
'Entrega a usuarios autenticados únicamente resultados que ya cuentan con '
'publicación formal por categoría.';
