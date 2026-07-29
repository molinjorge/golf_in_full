-- =========================================================
-- MIGRACIÓN 054
-- Supabase instala pgcrypto en el esquema "extensions", no en
-- "public". Nuestras funciones SECURITY DEFINER fijan
-- search_path=public a propósito (por seguridad), así que no
-- encuentran gen_random_bytes() aunque la extensión ya esté
-- habilitada. Corrección: calificar explícitamente el esquema
-- en cada uso, en vez de ampliar el search_path.
-- =========================================================

alter table tournament_registrations
  alter column qr_token set default encode(extensions.gen_random_bytes(16), 'hex');

alter table tournament_pre_reservations
  alter column qr_token set default encode(extensions.gen_random_bytes(16), 'hex');

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
  else
    raise exception 'El concepto de pago "%" todavía no está implementado.', v_attempt.concepto;
  end if;
end;
$$ language plpgsql;
