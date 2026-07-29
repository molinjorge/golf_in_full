-- =========================================================
-- MIGRACIÓN 051
-- medio_pago_licencia (migración 017) es para pagos de licencias
-- de club (B2B) — un dominio distinto al pago de inscripción de
-- un jugador a un torneo. Se crea un catálogo propio para esto
-- último, y se corrige lo que quedó apuntando al equivocado.
-- =========================================================

create type medio_pago_torneo as enum (
  'tarjeta_credito',
  'tarjeta_debito',
  'transferencia',
  'efectivo'
);

comment on type medio_pago_torneo is 'Medios de pago para inscripciones de jugadores a torneos. Independiente de medio_pago_licencia (que es para pagos de licencia de módulos por parte de un club).';

-- Corregir tournament_registrations.medio_pago
alter table tournament_registrations
  alter column medio_pago type medio_pago_torneo
  using medio_pago::text::medio_pago_torneo;

-- Corregir el parámetro de la función de confirmación de pre-reserva
-- Importante: cambiar el tipo del parámetro no "reemplaza" la
-- función vieja (Postgres las distingue por firma completa,
-- incluyendo tipos) — hay que borrar la versión anterior explícitamente
-- para no dejar dos funciones con el mismo nombre y distinto tipo.
drop function if exists confirmar_pago_prereserva(uuid, medio_pago_licencia, text);

create or replace function confirmar_pago_prereserva(
  p_pre_reserva_id  uuid,
  p_medio_pago_real medio_pago_torneo,
  p_referencia_pago text
)
returns tournament_registrations
security definer
set search_path = public
as $$
declare
  v_pre        tournament_pre_reservations;
  v_admin_id   uuid;
  v_autorizado boolean;
  v_resultado  tournament_registrations;
begin
  select * into v_pre from tournament_pre_reservations where id = p_pre_reserva_id;

  if v_pre.id is null then
    raise exception 'No existe esa pre-reserva.';
  end if;

  if v_pre.estatus <> 'pendiente_pago' or v_pre.activo = false then
    raise exception 'Esta pre-reserva ya no está pendiente de pago (estatus actual: %).', v_pre.estatus;
  end if;

  if v_pre.tournament_registration_id is not null then
    raise exception 'Esta pre-reserva ya fue convertida a inscripción anteriormente.';
  end if;

  v_autorizado := is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_pre.tournament_id)
    or exists (
      select 1 from tournaments t
       where t.id = v_pre.tournament_id and is_club_admin(auth.uid(), t.club_id)
    );

  if not v_autorizado then
    raise exception 'No tienes permiso para confirmar pagos de este torneo.';
  end if;

  select id into v_admin_id from admin_users where auth_user_id = auth.uid();

  insert into tournament_registrations (
    tournament_id, player_id, tournament_category_id,
    monto_pagado, fecha_pago, medio_pago, referencia_pago, created_by
  ) values (
    v_pre.tournament_id, v_pre.player_id, v_pre.tournament_category_id,
    v_pre.monto, now(), p_medio_pago_real, p_referencia_pago, v_admin_id
  )
  returning * into v_resultado;

  update tournament_pre_reservations
     set estatus                 = 'pagado',
         fecha_pago               = now(),
         referencia_pago          = p_referencia_pago,
         confirmado_por           = v_admin_id,
         tournament_registration_id = v_resultado.id
   where id = p_pre_reserva_id;

  return v_resultado;
end;
$$ language plpgsql;

grant execute on function confirmar_pago_prereserva(uuid, medio_pago_torneo, text) to authenticated;
