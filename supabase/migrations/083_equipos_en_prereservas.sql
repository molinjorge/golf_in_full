-- =========================================================
-- MIGRACIÓN 083
-- Corrección: el soporte de equipos (migración 079) solo se
-- agregó a tournament_registrations — todo el camino de reservas
-- previas (phone_reservations, tournament_pre_reservations) se
-- quedó sin poder capturar ni propagar el equipo. Se corrige de
-- extremo a extremo: captura, reconciliación automática, y
-- confirmación de pago, todas ahora propagan tournament_team_id.
-- =========================================================

alter table phone_reservations
  add column tournament_team_id uuid references tournament_teams (id) on delete restrict;

alter table tournament_pre_reservations
  add column tournament_team_id uuid references tournament_teams (id) on delete restrict;

alter table phone_reservations
  alter column tournament_category_id drop not null;

alter table tournament_pre_reservations
  alter column tournament_category_id drop not null;

comment on column phone_reservations.tournament_team_id is 'Equipo al que se apunta esta reserva telefónica. NULL en torneos individuales o si la persona se inscribirá sin equipo.';
comment on column tournament_pre_reservations.tournament_team_id is 'Equipo al que se apunta esta pre-reserva. NULL en torneos individuales o si el jugador se inscribirá sin equipo.';

create or replace function reconciliar_reserva_previa_telefonica()
returns trigger as $$
declare
  v_reserva phone_reservations;
  v_nueva_pre_reserva tournament_pre_reservations;
begin
  if new.telefono_pais is null then
    return new;
  end if;

  for v_reserva in
    select * from phone_reservations
     where telefono_pais = new.telefono_pais
       and telefono_lada = new.telefono_lada
       and telefono_numero = new.telefono_numero
       and activo = true
  loop
    insert into tournament_pre_reservations (
      tournament_id, player_id, tournament_category_id, tournament_team_id,
      modalidad, monto, fecha_limite_pago, created_by
    ) values (
      v_reserva.tournament_id, new.id, v_reserva.tournament_category_id, v_reserva.tournament_team_id,
      v_reserva.modalidad, v_reserva.monto, v_reserva.fecha_limite_pago, v_reserva.created_by
    )
    returning * into v_nueva_pre_reserva;

    update phone_reservations
       set activo = false,
           fecha_baja = now(),
           motivo_baja = 'Convertida automáticamente a pre-reserva formal tras autoregistro',
           convertida_a_pre_reserva_id = v_nueva_pre_reserva.id
     where id = v_reserva.id;
  end loop;

  return new;
end;
$$ language plpgsql security definer set search_path = public;

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
    tournament_id, player_id, tournament_category_id, tournament_team_id,
    monto_pagado, fecha_pago, medio_pago, referencia_pago, created_by
  ) values (
    v_pre.tournament_id, v_pre.player_id, v_pre.tournament_category_id, v_pre.tournament_team_id,
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

create or replace function procesar_resultado_pago(
  p_attempt_id     uuid,
  p_aprobado       boolean,
  p_referencia_pago text default null
)
returns tournament_registrations
security definer
set search_path = public
as $$
declare
  v_attempt   payment_attempts;
  v_pre       tournament_pre_reservations;
  v_resultado tournament_registrations;
begin
  select * into v_attempt from payment_attempts where id = p_attempt_id;

  if v_attempt.id is null then
    raise exception 'No existe ese intento de pago.';
  end if;

  if v_attempt.player_id not in (select id from players where auth_user_id = auth.uid())
     and not is_superadmin(auth.uid()) then
    raise exception 'No puedes procesar el resultado del intento de otro jugador.';
  end if;

  if v_attempt.resultado is not null then
    raise exception 'Este intento ya fue procesado anteriormente.';
  end if;

  update payment_attempts
     set resultado        = p_aprobado,
         referencia_pago  = p_referencia_pago,
         procesado_at     = now()
   where id = p_attempt_id;

  if not p_aprobado then
    return null;
  end if;

  if v_attempt.concepto = 'inscripcion_individual' then
    insert into tournament_registrations (
      tournament_id, player_id, tournament_category_id,
      monto_pagado, fecha_pago, medio_pago, referencia_pago
    ) values (
      v_attempt.tournament_id, v_attempt.player_id, v_attempt.referencia_id,
      v_attempt.monto, now(), v_attempt.medio_pago,
      coalesce(p_referencia_pago, 'SIMULADO-' || encode(extensions.gen_random_bytes(6), 'hex'))
    )
    returning * into v_resultado;

    update payment_attempts
       set tournament_registration_id = v_resultado.id
     where id = p_attempt_id;

    return v_resultado;

  elsif v_attempt.concepto = 'confirmar_pre_reserva' then
    select * into v_pre from tournament_pre_reservations where id = v_attempt.referencia_id;

    if v_pre.id is null then
      raise exception 'No existe la pre-reserva referenciada.';
    end if;

    if v_pre.player_id <> v_attempt.player_id then
      raise exception 'Esta pre-reserva no pertenece a este jugador.';
    end if;

    if v_pre.estatus <> 'pendiente_pago' or v_pre.activo = false then
      raise exception 'Esta pre-reserva ya no está pendiente de pago (estatus actual: %).', v_pre.estatus;
    end if;

    if v_pre.tournament_registration_id is not null then
      raise exception 'Esta pre-reserva ya fue confirmada anteriormente.';
    end if;

    insert into tournament_registrations (
      tournament_id, player_id, tournament_category_id, tournament_team_id,
      monto_pagado, fecha_pago, medio_pago, referencia_pago
    ) values (
      v_pre.tournament_id, v_pre.player_id, v_pre.tournament_category_id, v_pre.tournament_team_id,
      v_pre.monto, now(), v_attempt.medio_pago,
      coalesce(p_referencia_pago, 'SIMULADO-' || encode(extensions.gen_random_bytes(6), 'hex'))
    )
    returning * into v_resultado;

    update tournament_pre_reservations
       set estatus = 'pagado',
           fecha_pago = now(),
           referencia_pago = p_referencia_pago,
           tournament_registration_id = v_resultado.id
     where id = v_pre.id;

    update payment_attempts
       set tournament_registration_id = v_resultado.id
     where id = p_attempt_id;

    return v_resultado;

  else
    raise exception 'El concepto de pago "%" todavía no está implementado.', v_attempt.concepto;
  end if;
end;
$$ language plpgsql;
