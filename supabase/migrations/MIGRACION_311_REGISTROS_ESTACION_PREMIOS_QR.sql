-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 311
-- Consulta segura de registros de Premios Especiales por QR de estación
--
-- Objetivo:
--   - Permitir que el responsable vea desde cualquier dispositivo TODOS los
--     registros de su estación, no sólo los capturados localmente.
--   - Mantener el acceso estrictamente limitado por el token QR activo.
--   - Incluir historial de correcciones/invalidationes para trazabilidad.
--   - Exponer entryId sólo como identificador operativo necesario para las
--     RPC de corrección e invalidación existentes.
--   - No abrir acceso directo a las tablas operativas.
-- ============================================================================

begin;

create or replace function public.obtener_registros_estacion_premios_por_qr_311(
    p_qr_token text
)
returns jsonb
language plpgsql
security definer
set search_path = public, pg_temp
as $function$
declare
    v_token text;
    v_station_id uuid;
    v_result jsonb;
begin
    v_token := lower(btrim(coalesce(p_qr_token, '')));

    if v_token !~ '^[0-9a-f]{64}$' then
        raise exception 'Código QR inválido.'
            using errcode = '22023';
    end if;

    -- Resolver exclusivamente una estación operativa mediante el QR vigente.
    select s.id
      into v_station_id
      from public.tournament_special_prize_station_access a
      join public.tournament_special_prize_stations s
        on s.id = a.station_id
      join public.tournaments t
        on t.id = s.tournament_id
      join public.tournament_rounds tr
        on tr.id = s.tournament_round_id
     where a.qr_token = v_token
       and a.activo = true
       and s.activo = true
       and t.activo = true
       and tr.activo = true
     limit 1;

    if v_station_id is null then
        raise exception
            'El acceso QR no existe, está desactivado o ya no es válido.'
            using errcode = '42501';
    end if;

    select jsonb_build_object(
        'ok', true,
        'stationId', v_station_id,
        'entries', coalesce(
            jsonb_agg(
                jsonb_build_object(
                    -- ID operativo necesario para corregir/invalidar por RPC.
                    'entryId', e.id,
                    'player', jsonb_build_object(
                        'name', concat_ws(' ', pl.nombres, pl.apellidos)
                    ),
                    'prize', jsonb_build_object(
                        'id', p.id,
                        'name', p.nombre_snapshot,
                        'valueType', p.tipo_valor_snapshot,
                        'comparison', p.criterio_comparacion_snapshot
                    ),
                    'value', e.valor,
                    'unit', e.unidad_snapshot,
                    'witnessName', e.testigo_nombre,
                    'witnessConfirmed', e.testigo_confirmado,
                    'status', e.estatus,
                    'invalidReason', e.motivo_invalido,
                    'lastCorrectionReason', e.motivo_ultima_correccion,
                    'capturedVia', e.capturado_via,
                    'capturedAt', e.capturado_at,
                    'updatedAt', e.updated_at,
                    'history', coalesce(
                        (
                            select jsonb_agg(
                                jsonb_build_object(
                                    'version', h.version_no,
                                    'previousValue', h.valor_anterior,
                                    'previousUnit', h.unidad_snapshot_anterior,
                                    'previousWitnessName', h.testigo_nombre_anterior,
                                    'previousWitnessConfirmed', h.testigo_confirmado_anterior,
                                    'previousStatus', h.estatus_anterior,
                                    'previousInvalidReason', h.motivo_invalido_anterior,
                                    'changeReason', h.motivo_cambio,
                                    'changedVia', h.cambiado_via,
                                    'changedAt', h.changed_at
                                )
                                order by h.version_no desc
                            )
                            from public.tournament_special_prize_entry_history h
                            where h.entry_id = e.id
                        ),
                        '[]'::jsonb
                    )
                )
                order by e.capturado_at desc, e.id desc
            ) filter (where e.id is not null),
            '[]'::jsonb
        )
    )
      into v_result
      from public.tournament_special_prize_stations s
      left join public.tournament_special_prize_entries e
        on e.station_id = s.id
      left join public.tournament_special_prizes p
        on p.id = e.tournament_special_prize_id
       and p.station_id = s.id
      left join public.players pl
        on pl.id = e.player_id
     where s.id = v_station_id
     group by s.id;

    return coalesce(
        v_result,
        jsonb_build_object(
            'ok', true,
            'stationId', v_station_id,
            'entries', '[]'::jsonb
        )
    );
end;
$function$;

revoke all on function public.obtener_registros_estacion_premios_por_qr_311(text)
from public;

grant execute on function public.obtener_registros_estacion_premios_por_qr_311(text)
to anon, authenticated, service_role;

commit;
