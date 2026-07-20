-- =========================================================
-- MIGRACIÓN 026A
-- Complemento a la 026 (ya corrida): ayudantes para que el
-- frontend nunca tenga que construir tipos PostGIS a mano
-- (evita el riesgo de invertir latitud/longitud).
-- =========================================================

-- Vista de lectura: expone lat/long como números normales.
-- security_invoker=true es importante: sin esto, la vista
-- correría con los privilegios del dueño y se saltaría RLS.
create view green_coordenadas_detalle
with (security_invoker = true) as
select
  gc.id,
  gc.hoyo_id,
  h.campo_golf_id,
  h.numero_hoyo,
  st_y(gc.green_frente::geometry) as frente_lat,
  st_x(gc.green_frente::geometry) as frente_lng,
  st_y(gc.green_centro::geometry) as centro_lat,
  st_x(gc.green_centro::geometry) as centro_lng,
  st_y(gc.green_atras::geometry)  as atras_lat,
  st_x(gc.green_atras::geometry)  as atras_lng
from green_coordenadas gc
join hoyos h on h.id = gc.hoyo_id;

grant select on green_coordenadas_detalle to anon, authenticated;

-- Función de escritura: recibe lat/long normales, arma el punto
-- PostGIS correctamente (longitud primero, luego latitud —
-- el orden que PostGIS exige internamente), y hace upsert.
-- No es SECURITY DEFINER a propósito: debe seguir respetando
-- la política green_coordenadas_write normal del usuario real.
create or replace function upsert_green_coordenadas(
  p_hoyo_id    uuid,
  p_frente_lat numeric default null, p_frente_lng numeric default null,
  p_centro_lat numeric default null, p_centro_lng numeric default null,
  p_atras_lat  numeric default null, p_atras_lng  numeric default null
)
returns green_coordenadas
language plpgsql
as $$
declare
  v_result green_coordenadas;
begin
  insert into green_coordenadas (hoyo_id, green_frente, green_centro, green_atras)
  values (
    p_hoyo_id,
    case when p_frente_lat is not null and p_frente_lng is not null
         then ST_MakePoint(p_frente_lng, p_frente_lat)::geography end,
    case when p_centro_lat is not null and p_centro_lng is not null
         then ST_MakePoint(p_centro_lng, p_centro_lat)::geography end,
    case when p_atras_lat is not null and p_atras_lng is not null
         then ST_MakePoint(p_atras_lng, p_atras_lat)::geography end
  )
  on conflict (hoyo_id) do update set
    green_frente = excluded.green_frente,
    green_centro = excluded.green_centro,
    green_atras  = excluded.green_atras,
    updated_at   = now()
  returning * into v_result;

  return v_result;
end;
$$;

comment on function upsert_green_coordenadas is 'Recibe lat/long como números normales (no PostGIS). Arma los puntos geography correctamente. Respeta RLS normal (no es SECURITY DEFINER).';

grant execute on function upsert_green_coordenadas(uuid, numeric, numeric, numeric, numeric, numeric, numeric) to authenticated;
