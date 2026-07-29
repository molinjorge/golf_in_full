-- =========================================================
-- MIGRACIÓN 052 (v2 — generalizada)
-- Reemplaza tournament_registration_attempts por payment_attempts,
-- un intento de pago GENÉRICO — reutilizable para inscripción
-- individual, inscripción de equipo, renta de carritos, pago el
-- día del evento, etc. El campo "concepto" define para qué es, y
-- el RPC que procesa el resultado decide qué crear según eso.
--
-- ADVERTENCIA — BORRAR ANTES DE CONECTAR UNA PASARELA REAL:
-- simular_resultado_pago() permite que cualquier usuario declare
-- su propio pago como "aprobado" sin banco real de por medio.
-- Es intencional, solo para pruebas.
-- =========================================================

drop table if exists tournament_registration_attempts cascade;

create type concepto_pago as enum (
  'inscripcion_individual',
  'inscripcion_equipo',
  'renta_carrito',
  'pago_dia_evento',
  'otro'
);

create table payment_attempts (
  id                        uuid            primary key default gen_random_uuid(),
  player_id                 uuid            not null references players (id) on delete restrict,
  tournament_id             uuid            references tournaments (id) on delete restrict,

  concepto                  concepto_pago   not null,
  monto                     numeric(10,2)   not null,
  medio_pago                medio_pago_torneo,

  -- Referencia flexible a "la cosa específica" que se está pagando
  -- (ej. tournament_category_id para inscripción individual). El
  -- detalle jsonb permite guardar información adicional sin tener
  -- que agregar una columna nueva por cada concepto futuro.
  referencia_id             uuid,
  detalle                   jsonb,

  resultado                 boolean,         -- null=pendiente, true=aprobado, false=rechazado
  referencia_pago           text,
  procesado_at              timestamptz,

  tournament_registration_id uuid           references tournament_registrations (id) on delete set null,

  correo_abandono_enviado   boolean         not null default false,
  fecha_hora_intento        timestamptz     not null default now(),
  created_at                timestamptz     not null default now(),

  constraint payment_attempts_monto_valido check (monto >= 0)
);

comment on table payment_attempts is 'Intento de pago genérico, reutilizable para cualquier concepto (inscripción individual/equipo, renta de carrito, pago el día del evento, etc.). "concepto" + "referencia_id"/"detalle" definen qué se está pagando; el RPC de resultado decide qué crear según el concepto.';
comment on column payment_attempts.referencia_id is 'Referencia flexible al objeto específico de este pago (ej. tournament_category_id si concepto=inscripcion_individual).';
comment on column payment_attempts.detalle is 'Datos adicionales específicos del concepto, en formato libre, para no tener que agregar columnas nuevas cada vez que se agregue un concepto de pago futuro.';

create index idx_payment_attempts_tournament on payment_attempts (tournament_id);
create index idx_payment_attempts_player on payment_attempts (player_id);
create index idx_payment_attempts_concepto on payment_attempts (concepto);
create index idx_payment_attempts_sin_completar
  on payment_attempts (fecha_hora_intento)
  where resultado is null and correo_abandono_enviado = false;

-- ---------------------------------------------------------
-- RPC genérico de resultado de pago
-- ---------------------------------------------------------

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

  -- A partir de aquí, cada concepto sabe qué debe crear.
  -- Hoy solo está implementado "inscripcion_individual"; los
  -- demás conceptos (equipo, carrito, pago en sitio) se agregan
  -- conforme se construyan esas tablas.
  if v_attempt.concepto = 'inscripcion_individual' then
    insert into tournament_registrations (
      tournament_id, player_id, tournament_category_id,
      monto_pagado, fecha_pago, medio_pago, referencia_pago
    ) values (
      v_attempt.tournament_id, v_attempt.player_id, v_attempt.referencia_id,
      v_attempt.monto, now(), v_attempt.medio_pago,
      coalesce(p_referencia_pago, 'SIMULADO-' || encode(gen_random_bytes(6), 'hex'))
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

comment on function procesar_resultado_pago is 'RPC genérico: procesa el resultado de CUALQUIER intento de pago, y crea lo correspondiente según "concepto". Hoy solo implementa inscripcion_individual.';

grant execute on function procesar_resultado_pago(uuid, boolean, text) to authenticated;

-- Alias temporal, mismo nombre que usamos en la conversación —
-- llama al RPC genérico de arriba. Se puede quitar si prefieres
-- usar directamente procesar_resultado_pago() en el frontend.
create or replace function simular_resultado_pago(
  p_attempt_id          uuid,
  p_aprobado            boolean,
  p_referencia_simulada text default null
)
returns tournament_registrations
security definer
set search_path = public
as $$
  select procesar_resultado_pago(p_attempt_id, p_aprobado, p_referencia_simulada);
$$ language sql;

comment on function simular_resultado_pago is 'TEMPORAL — eliminar antes de conectar una pasarela real. Alias de procesar_resultado_pago(), pensado para pruebas manuales.';

grant execute on function simular_resultado_pago(uuid, boolean, text) to authenticated;

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table payment_attempts enable row level security;

create policy payment_attempts_select on payment_attempts
  for select to authenticated
  using (
    player_id in (select id from players where auth_user_id = auth.uid())
    or is_superadmin(auth.uid())
    or (tournament_id is not null and is_tournament_organizer(auth.uid(), tournament_id))
    or (tournament_id is not null and exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id)))
  );

create policy payment_attempts_insert on payment_attempts
  for insert to authenticated
  with check (player_id in (select id from players where auth_user_id = auth.uid()));

grant select, insert on payment_attempts to authenticated;
