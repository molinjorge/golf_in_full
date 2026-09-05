-- ============================================================================
-- MIGRACIÓN 247
-- Enriquecer payload oficial TEAM con relación de marcadores
-- ============================================================================
-- Objetivo:
--   1) Mantener intacto el payload histórico PLAYER.
--   2) En A-Go-Go / equipo / team_stroke, agregar a cada tarjeta TEAM:
--        - marker: quién marca a este equipo.
--        - weMark: a quién marca este equipo y qué jugador propio fue designado.
--   3) Reutilizar tournament_scorecard_marker_assignments como única fuente de verdad.
--   4) No modificar asignaciones, captura, permisos, scoring ni datos históricos.
--
-- Nota UI relacionada (NO forma parte de esta migración):
--   La fila genérica YDS vacía debe omitirse sólo al renderizar tarjetas TEAM.
--   Las distancias reales por tee (distanciasPorTee / yardagesByTee) se conservan.
-- ============================================================================

BEGIN;

-- Preservar exactamente la implementación previa como motor base.
ALTER FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
RENAME TO _obtener_payload_tarjetas_score_oficiales_ronda_pre247;

-- El motor previo queda interno: sólo el owner podrá invocarlo directamente.
REVOKE ALL ON FUNCTION public._obtener_payload_tarjetas_score_oficiales_ronda_pre247(uuid)
FROM PUBLIC, anon, authenticated, service_role;

CREATE OR REPLACE FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(
    p_tournament_round_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_payload jsonb;
    v_cards jsonb;
BEGIN
    -- El motor anterior conserva autenticación, permisos, validaciones,
    -- rama PLAYER y todo el contrato ya existente.
    v_payload := public._obtener_payload_tarjetas_score_oficiales_ronda_pre247(
        p_tournament_round_id
    );

    -- Sólo enriquecer A-Go-Go TEAM.
    IF COALESCE(v_payload #>> '{format,participationType}', '') <> 'equipo'
       OR COALESCE(v_payload #>> '{format,scoringEngine}', '') <> 'team_stroke'
    THEN
        RETURN v_payload;
    END IF;

    SELECT COALESCE(
        jsonb_agg(
            c.card
            || jsonb_build_object(
                -- Quién marca ESTA tarjeta/equipo.
                'marker', marker_info.marker_json,

                -- Qué tarjeta(s) marca este equipo y qué jugador propio
                -- quedó designado. Se entrega como arreglo para soportar
                -- grupos futuros con más de dos equipos sin cambiar contrato.
                'weMark', COALESCE(we_mark_info.we_mark_json, '[]'::jsonb)
            )
            ORDER BY NULLIF(c.card->>'cardNumber','')::integer NULLS LAST,
                     c.card->>'cardFolio'
        ),
        '[]'::jsonb
    )
    INTO v_cards
    FROM jsonb_array_elements(COALESCE(v_payload->'cards','[]'::jsonb)) AS c(card)

    LEFT JOIN LATERAL (
        SELECT jsonb_build_object(
            'assignmentId', ma.id,
            'assignmentSource', ma.assignment_source,
            'validFromSequence', ma.valid_from_sequence,
            'playerId', ma.marker_player_id,
            'playerName', COALESCE(
                (
                    SELECT m->>'name'
                    FROM public.tournament_team_scorecard_snapshots marker_ss2
                    CROSS JOIN LATERAL jsonb_array_elements(marker_ss2.members_snapshot) m
                    WHERE marker_ss2.score_card_id = ma.marker_score_card_id
                      AND NULLIF(m->>'playerId','')::uuid = ma.marker_player_id
                    LIMIT 1
                ),
                'Marcador'
            ),
            'teamId', marker_sc.tournament_team_id,
            'teamName', marker_ss.team_name,
            'scoreCardId', ma.marker_score_card_id,
            'selfMarker', ma.marker_score_card_id = ma.score_card_id
        ) AS marker_json
        FROM public.tournament_scorecard_marker_assignments ma
        JOIN public.tournament_score_cards marker_sc
          ON marker_sc.id = ma.marker_score_card_id
         AND marker_sc.status = 'issued'
        LEFT JOIN public.tournament_team_scorecard_snapshots marker_ss
          ON marker_ss.score_card_id = ma.marker_score_card_id
        WHERE ma.score_card_id = NULLIF(c.card->>'scoreCardId','')::uuid
          AND ma.status = 'active'
        ORDER BY ma.assigned_at DESC, ma.id DESC
        LIMIT 1
    ) marker_info ON true

    LEFT JOIN LATERAL (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'assignmentId', ma.id,
                    'assignmentSource', ma.assignment_source,
                    'validFromSequence', ma.valid_from_sequence,
                    'playerId', ma.marker_player_id,
                    'playerName', COALESCE(
                        (
                            SELECT m->>'name'
                            FROM public.tournament_team_scorecard_snapshots own_ss2
                            CROSS JOIN LATERAL jsonb_array_elements(own_ss2.members_snapshot) m
                            WHERE own_ss2.score_card_id = ma.marker_score_card_id
                              AND NULLIF(m->>'playerId','')::uuid = ma.marker_player_id
                            LIMIT 1
                        ),
                        'Marcador'
                    ),
                    'targetScoreCardId', ma.score_card_id,
                    'targetTeamId', target_sc.tournament_team_id,
                    'targetTeamName', target_ss.team_name,
                    'selfMarker', ma.marker_score_card_id = ma.score_card_id
                )
                ORDER BY target_sc.card_number, ma.assigned_at, ma.id
            ),
            '[]'::jsonb
        ) AS we_mark_json
        FROM public.tournament_scorecard_marker_assignments ma
        JOIN public.tournament_score_cards target_sc
          ON target_sc.id = ma.score_card_id
         AND target_sc.status = 'issued'
        LEFT JOIN public.tournament_team_scorecard_snapshots target_ss
          ON target_ss.score_card_id = ma.score_card_id
        WHERE ma.marker_score_card_id = NULLIF(c.card->>'scoreCardId','')::uuid
          AND ma.status = 'active'
    ) we_mark_info ON true;

    -- Bump de versión sólo para el contrato TEAM enriquecido.
    RETURN jsonb_set(
        jsonb_set(v_payload, '{cards}', v_cards, true),
        '{schemaVersion}',
        to_jsonb(3),
        true
    );
END;
$function$;

-- Contrato de ejecución equivalente al RPC público previo.
REVOKE ALL ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
TO authenticated, service_role;

COMMENT ON FUNCTION public.obtener_payload_tarjetas_score_oficiales_ronda(uuid)
IS 'Payload oficial de tarjetas. PLAYER conserva contrato previo; TEAM schemaVersion 3 agrega marker y weMark desde asignaciones activas.';

COMMIT;
