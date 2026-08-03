-- =========================================================
-- MIGRACIÓN 089
-- Cupo de equipo validado desde el momento de la RESERVA (no
-- solo hasta la inscripción final pagada). Función compartida
-- que cuenta la ocupación real de un equipo sumando las tres
-- fuentes, sin contar a la misma persona dos veces.
--
-- Cuidado especial: cuando una pre-reserva SE CONVIERTE en
-- inscripción real (alguien paga), ese instante de transición
-- NO debe contarse dos veces — se usa una bandera de sesión
-- temporal para saltarse la validación únicamente durante esa
-- conversión controlada (la capacidad ya se validó cuando se
-- creó la pre-reserva originalmente).
-- =========================================================

create or replace function ocupacion_actual_equipo(p_team_id uuid)
returns integer
language sql
stable
as $$
  select
    (select count(*) from phone_reservations
      where tournament_team_id = p_team_id and activo = true)
    +
    (select count(*) from tournament_pre_reservations
      where tournament_team_id = p_team_id and activo = true and tournament_registration_id is null)
    +
    (select count(*) from tournament_registrations
      where tournament_team_id = p_team_id and activo = true);
$$;

comment on function ocupacion_actual_equipo is 'Cuenta cuántas personas ocupan un equipo AHORA: reservas telefónicas activas + pre-reservas sin convertir + inscripciones ya pagadas — sin doble conteo.';

create or replace function validar_cupo_equipo_reserva()
returns trigger as $$
declare
  v_jugadores_por_equipo integer;
  v_ocupacion_actual     integer;
begin
  if new.tournament_team_id is not null then
    select jugadores_por_equipo into v_jugadores_por_equipo
      from tournaments where id = new.tournament_id;

    v_ocupacion_actual := ocupacion_actual_equipo(new.tournament_team_id);

    if v_ocupacion_actual >= v_jugadores_por_equipo then
      raise exception 'Este equipo ya está completo (% de % lugares, contando reservas y pre-reservas).', v_ocupacion_actual, v_jugadores_por_equipo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_cupo_equipo_phone
before insert on phone_reservations
for each row execute function validar_cupo_equipo_reserva();

create trigger trg_validar_cupo_equipo_prereserva
before insert on tournament_pre_reservations
for each row execute function validar_cupo_equipo_reserva();

create or replace function validar_cupo_equipo()
returns trigger as $$
declare
  v_jugadores_por_equipo integer;
  v_ocupacion_actual     integer;
begin
  if current_setting('app.saltar_validacion_cupo_equipo', true) = 'true' then
    return new;
  end if;

  if new.tournament_team_id is not null then
    select jugadores_por_equipo into v_jugadores_por_equipo
      from tournaments where id = new.tournament_id;

    v_ocupacion_actual := ocupacion_actual_equipo(new.tournament_team_id);

    if v_ocupacion_actual >= v_jugadores_por_equipo then
      raise exception 'Este equipo ya está completo (% de % lugares, contando reservas y pre-reservas).', v_ocupacion_actual, v_jugadores_por_equipo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

comment on function validar_cupo_equipo is 'Valida cupo de equipo al insertar una inscripción real, salvo durante una conversión controlada de pre-reserva (bandera app.saltar_validacion_cupo_equipo).';

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

  perform set_config('app.saltar_validacion_cupo_equipo', 'true', true);

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

    perform set_config('app.saltar_validacion_cupo_equipo', 'true', true);

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
