-- TEE CENTRAL / GOLF IN FULL
-- Migración 250
-- Expone roundNumber y roundDate congelados en el reporte de cierre por categoría.
-- No recalcula resultados ni consulta leaderboard vivo.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_reporte_cierre_categoria_ronda(
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
                    COALESCE(
                        v_closure.closure_snapshot->'round',
                        '{}'::jsonb
                    ) || jsonb_build_object(
                        'roundNumber', v_closure.round_number,
                        'roundDate', v_closure.round_date
                    ),
                'categoryState',
                    v_closure.closure_snapshot->'categoryState',
                'leaderboardCategory',
                    v_closure.closure_snapshot->'leaderboardCategory'
            )
    );
END;
$function$;

-- Preservar el contrato de ejecución público existente: sin anon.
REVOKE ALL ON FUNCTION public.obtener_reporte_cierre_categoria_ronda(uuid,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.obtener_reporte_cierre_categoria_ronda(uuid,uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_reporte_cierre_categoria_ronda(uuid,uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.obtener_reporte_cierre_categoria_ronda(uuid,uuid) TO service_role;

COMMIT;
