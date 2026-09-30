-- ============================================================================
-- TEE CENTRAL
-- MIGRACIÓN 414 — FINALIZACIÓN EXIGE PUBLICACIÓN OFICIAL
-- ============================================================================
-- Objetivo:
--   Impedir que un torneo pueda finalizarse mientras exista alguna ronda activa
--   con categorías participantes que todavía no estén publicadas oficialmente.
--
-- Principios:
--   * Cerrar una ronda NO equivale a publicar sus resultados.
--   * PARTIAL NO cuenta como publicación oficial.
--   * Sólo PUBLISHED satisface la publicación oficial.
--   * Las categorías sin participantes no generan pendientes.
--   * No se modifica finalizar_torneo(): ya vuelve a consultar
--     previsualizar_finalizacion_torneo() antes de escribir.
--   * No se modifican motores deportivos, desempates, cierres ni publicaciones.
-- ============================================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.previsualizar_finalizacion_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_base jsonb;
    v_pending_lifecycle integer := 0;

    v_round record;
    v_formalization jsonb;

    v_rounds_with_participants integer := 0;
    v_rounds_fully_published integer := 0;
    v_rounds_pending_publication integer := 0;

    v_total_participating_categories integer := 0;
    v_officially_published_categories integer := 0;
    v_pending_official_categories integer := 0;

    v_publication_rounds jsonb := '[]'::jsonb;
    v_all_officially_published boolean := false;
BEGIN
    -- Conserva toda la previsualización histórica y sus guards.
    v_base :=
        public._previsualizar_finalizacion_torneo_pre314(
            p_tournament_id
        );

    -- ------------------------------------------------------------------------
    -- Gate existente: ciclo/lifecycle de todas las rondas activas completado.
    -- ------------------------------------------------------------------------
    SELECT count(*)::integer
      INTO v_pending_lifecycle
      FROM public.tournament_rounds tr
      LEFT JOIN public.tournament_round_lifecycle l
        ON l.tournament_round_id = tr.id
     WHERE tr.tournament_id = p_tournament_id
       AND tr.activo = true
       AND l.completed_at IS NULL;

    v_base := jsonb_set(
        v_base,
        '{roundLifecycle}',
        jsonb_build_object(
            'required',true,
            'pendingRounds',v_pending_lifecycle,
            'allRoundsFinalized',v_pending_lifecycle=0
        ),
        true
    );

    IF v_pending_lifecycle > 0 THEN
        v_base := jsonb_set(
            v_base,
            '{readyToFinalize}',
            'false'::jsonb,
            true
        );
    END IF;

    -- ------------------------------------------------------------------------
    -- 414: publicación oficial obligatoria antes de finalizar el torneo.
    --
    -- Se reutiliza la evidencia formal de resultados de cada ronda.
    -- Esa evidencia sólo considera published=true cuando existe
    -- tournament_round_category_publications.publication_status='PUBLISHED'.
    -- PARTIAL no satisface el gate.
    --
    -- Las categorías sin participantes no forman parte del leaderboard
    -- operativo/formalización y por tanto no generan pendientes artificiales.
    -- ------------------------------------------------------------------------
    FOR v_round IN
        SELECT tr.id, tr.numero_ronda, tr.fecha
          FROM public.tournament_rounds tr
         WHERE tr.tournament_id = p_tournament_id
           AND tr.activo = true
         ORDER BY tr.numero_ronda, tr.fecha, tr.id
    LOOP
        v_formalization :=
            public._estado_formalizacion_resultados_ronda_265(
                v_round.id
            );

        -- Si la modalidad no está soportada por la formalización, no inventamos
        -- publicación. Se considera pendiente y la finalización queda bloqueada.
        IF NOT COALESCE((v_formalization->>'applicable')::boolean,false)
           OR NOT COALESCE((v_formalization->>'supported')::boolean,false)
        THEN
            v_rounds_pending_publication :=
                v_rounds_pending_publication + 1;

            v_publication_rounds :=
                v_publication_rounds ||
                jsonb_build_array(
                    jsonb_build_object(
                        'tournamentRoundId',v_round.id,
                        'roundNumber',v_round.numero_ronda,
                        'roundDate',v_round.fecha,
                        'supported',false,
                        'participatingCategories',0,
                        'officiallyPublishedCategories',0,
                        'pendingOfficialCategories',0,
                        'allOfficiallyPublished',false
                    )
                );

            CONTINUE;
        END IF;

        -- totalCategories en esta evidencia representa las categorías
        -- participantes de la ronda.
        IF COALESCE(
            NULLIF(v_formalization->>'totalCategories','')::integer,
            0
        ) > 0
        THEN
            v_rounds_with_participants :=
                v_rounds_with_participants + 1;
        END IF;

        v_total_participating_categories :=
            v_total_participating_categories +
            COALESCE(
                NULLIF(v_formalization->>'totalCategories','')::integer,
                0
            );

        v_officially_published_categories :=
            v_officially_published_categories +
            COALESCE(
                NULLIF(v_formalization->>'publishedCategories','')::integer,
                0
            );

        v_pending_official_categories :=
            v_pending_official_categories +
            GREATEST(
                COALESCE(
                    NULLIF(v_formalization->>'totalCategories','')::integer,
                    0
                )
                -
                COALESCE(
                    NULLIF(v_formalization->>'publishedCategories','')::integer,
                    0
                ),
                0
            );

        IF COALESCE(
            (v_formalization->>'allCategoriesPublished')::boolean,
            false
        )
        THEN
            v_rounds_fully_published :=
                v_rounds_fully_published + 1;
        ELSE
            v_rounds_pending_publication :=
                v_rounds_pending_publication + 1;
        END IF;

        v_publication_rounds :=
            v_publication_rounds ||
            jsonb_build_array(
                jsonb_build_object(
                    'tournamentRoundId',v_round.id,
                    'roundNumber',v_round.numero_ronda,
                    'roundDate',v_round.fecha,
                    'supported',true,
                    'participatingCategories',
                        COALESCE(
                            NULLIF(v_formalization->>'totalCategories','')::integer,
                            0
                        ),
                    'officiallyPublishedCategories',
                        COALESCE(
                            NULLIF(v_formalization->>'publishedCategories','')::integer,
                            0
                        ),
                    'pendingOfficialCategories',
                        GREATEST(
                            COALESCE(
                                NULLIF(v_formalization->>'totalCategories','')::integer,
                                0
                            )
                            -
                            COALESCE(
                                NULLIF(v_formalization->>'publishedCategories','')::integer,
                                0
                            ),
                            0
                        ),
                    'allOfficiallyPublished',
                        COALESCE(
                            (v_formalization->>'allCategoriesPublished')::boolean,
                            false
                        )
                )
            );
    END LOOP;

    v_all_officially_published :=
        v_rounds_pending_publication = 0
        AND v_total_participating_categories > 0
        AND v_officially_published_categories =
            v_total_participating_categories;

    v_base := jsonb_set(
        v_base,
        '{officialPublications}',
        jsonb_build_object(
            'required',true,
            'roundsWithParticipants',v_rounds_with_participants,
            'roundsFullyPublished',v_rounds_fully_published,
            'roundsPendingPublication',v_rounds_pending_publication,
            'participatingCategories',v_total_participating_categories,
            'officiallyPublishedCategories',v_officially_published_categories,
            'pendingOfficialCategories',v_pending_official_categories,
            'allOfficiallyPublished',v_all_officially_published,
            'rounds',v_publication_rounds
        ),
        true
    );

    IF NOT v_all_officially_published THEN
        v_base := jsonb_set(
            v_base,
            '{readyToFinalize}',
            'false'::jsonb,
            true
        );
    END IF;

    RETURN v_base;
END;
$function$;

COMMIT;
