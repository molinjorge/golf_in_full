-- =========================================================
-- MIGRACIÓN 075
-- Permite que el propio jugador confirme/pague en línea una
-- pre-reserva pendiente (hoy solo un administrador podía
-- hacerlo, vía confirmar_pago_prereserva). Reutiliza el mismo
-- mecanismo genérico de pago (payment_attempts +
-- procesar_resultado_pago), agregando el concepto
-- 'confirmar_pre_reserva'.
-- =========================================================

alter type concepto_pago add value if not exists 'confirmar_pre_reserva';

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
      tournament_id, player_id, tournament_category_id,
      monto_pagado, fecha_pago, medio_pago, referencia_pago
    ) values (
      v_pre.tournament_id, v_pre.player_id, v_pre.tournament_category_id,
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

comment on function procesar_resultado_pago is 'RPC genérico: procesa el resultado de cualquier intento de pago. Implementa inscripcion_individual (crea inscripción desde cero) y confirmar_pre_reserva (confirma una pre-reserva existente, con las mismas validaciones que confirmar_pago_prereserva pero iniciado por el propio jugador).';
