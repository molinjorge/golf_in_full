-- =========================================================
-- MIGRACIÓN 088
-- Tarifa de socios: aplica cuando el jugador pertenece al club
-- dueño del campo donde se juega el torneo, SIEMPRE Y CUANDO
-- tenga su número de membresía capturado (control anti-fraude —
-- sin número de membresía, no hay forma de distinguir un socio
-- real de alguien que solo dice serlo) y el torneo ofrezca esa
-- tarifa (tournament_marketing_info.precio_socios no vacío).
--
-- PENDIENTE, no resuelto aquí: si un torneo permite que la
-- tarifa de socios se extienda a TODO el equipo cuando un solo
-- integrante es socio — depende del mecanismo de "pago de equipo
-- completo" (Fase 4, todavía no construida).
-- =========================================================

drop function if exists tarifa_vigente_torneo(uuid);

create or replace function tarifa_vigente_torneo(p_tournament_id uuid, p_player_id uuid default null)
returns numeric
language sql
stable
as $$
  select case
    when v.aplica_tarifa_socios then v.precio_socios
    when t.tarifa_early_bird is not null and current_date <= t.fecha_limite_early_bird then t.tarifa_early_bird
    else t.tarifa_individual
  end
  from tournaments t
  left join campos_golf cg on cg.id = t.campo_golf_id
  left join tournament_marketing_info tmi on tmi.tournament_id = t.id
  left join players p on p.id = p_player_id
  cross join lateral (
    select
      (
        p.id is not null
        and p.club_id is not null
        and p.club_id = cg.club_id
        and p.numero_membresia is not null
        and trim(p.numero_membresia) <> ''
        and tmi.precio_socios is not null
      ) as aplica_tarifa_socios,
      tmi.precio_socios as precio_socios
  ) v
  where t.id = p_tournament_id;
$$;

comment on function tarifa_vigente_torneo is 'Tarifa aplicable para un jugador en un torneo: tarifa de socios (si pertenece al club dueño del campo, tiene número de membresía capturado, y el torneo la ofrece) > early bird vigente > tarifa individual. p_player_id es opcional — sin él, nunca aplica tarifa de socios (comportamiento anterior).';

grant execute on function tarifa_vigente_torneo(uuid, uuid) to authenticated, anon;

create or replace function calcular_monto_inscripcion_individual()
returns trigger as $$
begin
  if new.concepto = 'inscripcion_individual' then
    new.monto := tarifa_vigente_torneo(new.tournament_id, new.player_id);
  end if;

  return new;
end;
$$ language plpgsql;
