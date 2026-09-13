-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 306
-- REPORTE PROVISIONAL EN LÍNEA de Premios Especiales
--
-- Alcance:
--   - Crea una RPC de lectura para superadmin/organizador.
--   - Devuelve premios configurados por ronda/hoyo.
--   - Separa registros VALIDOS e INVALIDOS.
--   - Ordena los VALIDOS según:
--       MENOR_ES_MEJOR  -> valor ascendente
--       MAYOR_ES_MEJOR -> valor descendente
--       SOLO_REGISTRO   -> fecha de captura
--   - Para MENOR/MAYOR calcula posición PROVISIONAL con RANK(), respetando
--     empates. SOLO_REGISTRO no genera posición competitiva.
--   - Incluye testigo, timestamps, motivo de invalidez e historial de cambios.
--
-- MUY IMPORTANTE:
--   - NO adjudica ganadores.
--   - NO crea resultados oficiales.
--   - NO modifica scoring, Stableford, A-Go-Go, desempates, cortes, tarjetas,
--     cierres, freezes ni leaderboards deportivos.
--   - La adjudicación oficial se implementará en una fase posterior.
--
-- IMPORTANTE:
--   Ejecutar manualmente por el usuario en Supabase.
-- ============================================================================

begin;

create or replace function public.obtener_reporte_provisional_premios_306(
    p_tournament_id uuid,
    p_tournament_round_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_auth_uid uuid;
    v_tournament_name text;
    v_round_exists boolean;
    v_result jsonb;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.'
            using errcode = '42501';
    end if;

    select t.nombre
      into v_tournament_name
      from public.tournaments t
     where t.id = p_tournament_id;

    if not found then
        raise exception 'El torneo indicado no existe.'
            using errcode = '23503';
    end if;

    if not (
        public.is_superadmin(v_auth_uid)
        or public.is_tournament_organizer(v_auth_uid, p_tournament_id)
    ) then
        raise exception
            'No tienes autorización para consultar los Premios Especiales de este torneo.'
            using errcode = '42501';
    end if;

    if p_tournament_round_id is not null then
        select exists (
            select 1
            from public.tournament_rounds tr
            where tr.id = p_tournament_round_id
              and tr.tournament_id = p_tournament_id
        )
        into v_round_exists;

        if not coalesce(v_round_exists, false) then
            raise exception
                'La ronda indicada no pertenece al torneo.'
                using errcode = '23514';
        end if;
    end if;

    with prize_base as (
        select
            sp.id as prize_id,
            sp.tournament_id,
            sp.tournament_round_id,
            tr.numero_ronda,
            tr.fecha as fecha_ronda,
            sp.hoyo_id,
            h.numero_hoyo,
            h.par,
            sp.station_id,
            s.etiqueta as station_label,
            s.responsable_nombre,
            sp.nombre_snapshot,
            sp.tipo_valor_snapshot,
            sp.criterio_comparacion_snapshot,
            sp.unidad_captura,
            sp.tipo_referencia,
            sp.requiere_fairway,
            sp.requiere_green,
            sp.numero_golpe_evaluado,
            sp.descripcion_operativa,
            sp.patrocinador,
            sp.premio_ofrecido,
            sp.activo
        from public.tournament_special_prizes sp
        join public.tournament_rounds tr
          on tr.id = sp.tournament_round_id
        join public.hoyos h
          on h.id = sp.hoyo_id
        left join public.tournament_special_prize_stations s
          on s.id = sp.station_id
        where sp.tournament_id = p_tournament_id
          and (
              p_tournament_round_id is null
              or sp.tournament_round_id = p_tournament_round_id
          )
    ),
    ranked_entries as (
        select
            e.*,
            p.nombres,
            p.apellidos,
            p.email,
            pb.criterio_comparacion_snapshot,
            case
                when e.estatus <> 'VALIDO' then null
                when pb.criterio_comparacion_snapshot = 'MENOR_ES_MEJOR'
                    then rank() over (
                        partition by e.tournament_special_prize_id
                        order by
                            case
                                when e.estatus = 'VALIDO'
                                then e.valor
                            end asc nulls last,
                            e.capturado_at asc,
                            e.id
                    )
                when pb.criterio_comparacion_snapshot = 'MAYOR_ES_MEJOR'
                    then rank() over (
                        partition by e.tournament_special_prize_id
                        order by
                            case
                                when e.estatus = 'VALIDO'
                                then e.valor
                            end desc nulls last,
                            e.capturado_at asc,
                            e.id
                    )
                else null
            end as provisional_position
        from public.tournament_special_prize_entries e
        join public.players p
          on p.id = e.player_id
        join prize_base pb
          on pb.prize_id = e.tournament_special_prize_id
    )
    select jsonb_build_object(
        'ok', true,
        'reportType', 'REPORTE_PROVISIONAL_EN_LINEA',
        'official', false,
        'tournament', jsonb_build_object(
            'id', p_tournament_id,
            'name', v_tournament_name
        ),
        'roundFilterId', p_tournament_round_id,
        'generatedAt', now(),
        'prizes',
        coalesce(
            jsonb_agg(
                jsonb_build_object(
                    'prizeId', pb.prize_id,
                    'active', pb.activo,
                    'name', pb.nombre_snapshot,
                    'valueType', pb.tipo_valor_snapshot,
                    'comparison', pb.criterio_comparacion_snapshot,
                    'unit', pb.unidad_captura,

                    'round', jsonb_build_object(
                        'id', pb.tournament_round_id,
                        'number', pb.numero_ronda,
                        'date', pb.fecha_ronda
                    ),

                    'hole', jsonb_build_object(
                        'id', pb.hoyo_id,
                        'number', pb.numero_hoyo,
                        'par', pb.par
                    ),

                    'station', jsonb_build_object(
                        'id', pb.station_id,
                        'label', pb.station_label,
                        'responsibleName', pb.responsable_nombre
                    ),

                    'rules', jsonb_build_object(
                        'referenceType', pb.tipo_referencia,
                        'requiresFairway', pb.requiere_fairway,
                        'requiresGreen', pb.requiere_green,
                        'evaluatedStroke', pb.numero_golpe_evaluado,
                        'operationalDescription', pb.descripcion_operativa
                    ),

                    'commercial', jsonb_build_object(
                        'sponsor', pb.patrocinador,
                        'prizeOffered', pb.premio_ofrecido
                    ),

                    'validCount', (
                        select count(*)
                        from ranked_entries re
                        where re.tournament_special_prize_id = pb.prize_id
                          and re.estatus = 'VALIDO'
                    ),

                    'invalidCount', (
                        select count(*)
                        from ranked_entries re
                        where re.tournament_special_prize_id = pb.prize_id
                          and re.estatus = 'INVALIDO'
                    ),

                    'validEntries',
                    coalesce(
                        (
                            select jsonb_agg(
                                jsonb_build_object(
                                    'entryId', re.id,
                                    'provisionalPosition',
                                        re.provisional_position,
                                    'player', jsonb_build_object(
                                        'id', re.player_id,
                                        'registrationId',
                                            re.tournament_registration_id,
                                        'firstNames', re.nombres,
                                        'lastNames', re.apellidos,
                                        'email', re.email
                                    ),
                                    'value', re.valor,
                                    'unit', re.unidad_snapshot,
                                    'witnessName', re.testigo_nombre,
                                    'witnessConfirmed',
                                        re.testigo_confirmado,
                                    'capturedVia', re.capturado_via,
                                    'capturedAt', re.capturado_at,
                                    'updatedAt', re.updated_at,
                                    'history',
                                    coalesce(
                                        (
                                            select jsonb_agg(
                                                jsonb_build_object(
                                                    'version',
                                                        eh.version_no,
                                                    'previousValue',
                                                        eh.valor_anterior,
                                                    'previousUnit',
                                                        eh.unidad_snapshot_anterior,
                                                    'previousWitnessName',
                                                        eh.testigo_nombre_anterior,
                                                    'previousStatus',
                                                        eh.estatus_anterior,
                                                    'previousInvalidReason',
                                                        eh.motivo_invalido_anterior,
                                                    'changeReason',
                                                        eh.motivo_cambio,
                                                    'changedVia',
                                                        eh.cambiado_via,
                                                    'changedAt',
                                                        eh.changed_at
                                                )
                                                order by eh.version_no
                                            )
                                            from public.tournament_special_prize_entry_history eh
                                            where eh.entry_id = re.id
                                        ),
                                        '[]'::jsonb
                                    )
                                )
                                order by
                                    case
                                        when pb.criterio_comparacion_snapshot = 'MENOR_ES_MEJOR'
                                        then re.valor
                                    end asc nulls last,
                                    case
                                        when pb.criterio_comparacion_snapshot = 'MAYOR_ES_MEJOR'
                                        then re.valor
                                    end desc nulls last,
                                    case
                                        when pb.criterio_comparacion_snapshot = 'SOLO_REGISTRO'
                                        then re.capturado_at
                                    end asc nulls last,
                                    re.capturado_at asc,
                                    re.id
                            )
                            from ranked_entries re
                            where re.tournament_special_prize_id = pb.prize_id
                              and re.estatus = 'VALIDO'
                        ),
                        '[]'::jsonb
                    ),

                    'invalidEntries',
                    coalesce(
                        (
                            select jsonb_agg(
                                jsonb_build_object(
                                    'entryId', re.id,
                                    'player', jsonb_build_object(
                                        'id', re.player_id,
                                        'registrationId',
                                            re.tournament_registration_id,
                                        'firstNames', re.nombres,
                                        'lastNames', re.apellidos,
                                        'email', re.email
                                    ),
                                    'value', re.valor,
                                    'unit', re.unidad_snapshot,
                                    'invalidReason',
                                        re.motivo_invalido,
                                    'witnessName',
                                        re.testigo_nombre,
                                    'capturedAt',
                                        re.capturado_at,
                                    'updatedAt',
                                        re.updated_at,
                                    'history',
                                    coalesce(
                                        (
                                            select jsonb_agg(
                                                jsonb_build_object(
                                                    'version',
                                                        eh.version_no,
                                                    'previousValue',
                                                        eh.valor_anterior,
                                                    'previousUnit',
                                                        eh.unidad_snapshot_anterior,
                                                    'previousWitnessName',
                                                        eh.testigo_nombre_anterior,
                                                    'previousStatus',
                                                        eh.estatus_anterior,
                                                    'previousInvalidReason',
                                                        eh.motivo_invalido_anterior,
                                                    'changeReason',
                                                        eh.motivo_cambio,
                                                    'changedVia',
                                                        eh.cambiado_via,
                                                    'changedAt',
                                                        eh.changed_at
                                                )
                                                order by eh.version_no
                                            )
                                            from public.tournament_special_prize_entry_history eh
                                            where eh.entry_id = re.id
                                        ),
                                        '[]'::jsonb
                                    )
                                )
                                order by re.updated_at desc, re.id
                            )
                            from ranked_entries re
                            where re.tournament_special_prize_id = pb.prize_id
                              and re.estatus = 'INVALIDO'
                        ),
                        '[]'::jsonb
                    )
                )
                order by
                    pb.numero_ronda,
                    pb.numero_hoyo,
                    pb.nombre_snapshot,
                    pb.prize_id
            ),
            '[]'::jsonb
        )
    )
    into v_result
    from prize_base pb;

    return v_result;
end;
$function$;

revoke all
on function public.obtener_reporte_provisional_premios_306(uuid, uuid)
from public, anon;

grant execute
on function public.obtener_reporte_provisional_premios_306(uuid, uuid)
to authenticated;

commit;
