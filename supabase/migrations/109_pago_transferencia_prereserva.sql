-- 109_pago_transferencia_prereserva.sql
--
-- Nuevo flujo: el organizador recibe la confirmación de una transferencia bancaria por
-- correo/WhatsApp (fuera de la plataforma), y necesita registrar ese pago adjuntando el
-- comprobante, vinculado a la pre-reserva y al jugador. No debe poder confirmarse el pago
-- sin haber adjuntado el comprobante primero.
--
-- Hallazgo importante antes de escribir esto: tournament_registrations_insert (RLS) hoy
-- solo permite is_superadmin(auth.uid()) — ni organizador ni club_admin pueden insertar
-- directo. En vez de abrir esa política general (más riesgo), se crean dos funciones
-- SECURITY DEFINER que validan el rol de quien las llama y hacen el trabajo por él,
-- igual que ya hicimos con sincronizar_email_auth_jugador (105).
--
-- Decisiones de diseño confirmadas:
--   1. Archivos aceptados: imágenes (jpg/png) y PDF.
--   2. Puede haber más de un comprobante por pre-reserva (reintentos si el primero
--      salió borroso o incorrecto) — por eso "subir comprobante" y "confirmar pago"
--      son dos pasos/funciones separados, no uno solo.
--   3. tarifa_esperada se calcula con tarifa_vigente_torneo() (065/088) — la tarifa
--      vigente AL MOMENTO DE CONFIRMAR EL PAGO, no al momento de la pre-reserva
--      (confirmado con el usuario: es el comportamiento ya implícito en el nombre y
--      diseño de esa función, consistente con que el servidor siempre calcula el monto
--      al momento del pago, nunca se fija desde antes).
--   4. Si el monto capturado no coincide con la tarifa esperada: NO bloquea, solo se
--      guarda la diferencia para que el frontend la muestre como alerta visual.
--   5. Roles permitidos: superadmin, organizador del torneo, club_admin del club dueño.

-- 1. Bucket de Storage para los comprobantes (privado).
insert into storage.buckets (id, name, public)
values ('comprobantes-transferencia', 'comprobantes-transferencia', false)
on conflict (id) do nothing;

-- 2. Tabla de comprobantes subidos.
create table comprobantes_transferencia (
  id uuid primary key default gen_random_uuid(),
  tournament_pre_reservation_id uuid not null references tournament_pre_reservations(id),
  storage_path text not null,
  monto_capturado numeric(10,2) not null,
  tarifa_esperada numeric(10,2) not null,
  diferencia numeric(10,2) not null,
  referencia_bancaria text,
  comentarios text,
  subido_por uuid not null,
  created_at timestamptz not null default now(),
  confirmado boolean not null default false,
  confirmado_por uuid,
  fecha_confirmacion timestamptz,
  tournament_registration_id uuid references tournament_registrations(id)
);

alter table comprobantes_transferencia enable row level security;

-- Lectura/escritura de la tabla: mismos roles administrativos, resuelto vía la
-- pre-reserva → torneo. El jugador no ve ni gestiona esto directamente.
create policy comprobantes_transferencia_select
  on comprobantes_transferencia
  for select
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1
        from tournament_pre_reservations pr
        join tournaments t on t.id = pr.tournament_id
       where pr.id = comprobantes_transferencia.tournament_pre_reservation_id
         and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );

-- No hay policy de INSERT/UPDATE directo a propósito: toda escritura pasa por las
-- funciones SECURITY DEFINER de abajo, que validan el rol explícitamente antes de
-- tocar la tabla. Así se evita que alguien inserte una fila "confirmado = true" a mano.

-- 3. Función: registrar un comprobante (paso 1 — no crea inscripción todavía).
create or replace function registrar_comprobante_transferencia(
  p_pre_reserva_id uuid,
  p_storage_path text,
  p_monto_capturado numeric,
  p_referencia_bancaria text default null,
  p_comentarios text default null
)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_tournament_id  uuid;
  v_player_id      uuid;
  v_club_id        uuid;
  v_tarifa_esperada numeric;
  v_comprobante_id uuid;
begin
  select pr.tournament_id, pr.player_id, t.club_id
    into v_tournament_id, v_player_id, v_club_id
    from tournament_pre_reservations pr
    join tournaments t on t.id = pr.tournament_id
   where pr.id = p_pre_reserva_id
     and pr.activo = true;

  if v_tournament_id is null then
    raise exception 'Pre-reserva no encontrada o inactiva.';
  end if;

  if not (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_tournament_id)
    or is_club_admin(auth.uid(), v_club_id)
  ) then
    raise exception 'No tienes permiso para registrar comprobantes de pago en este torneo.';
  end if;

  if p_storage_path is null or trim(p_storage_path) = '' then
    raise exception 'Debes adjuntar el comprobante de transferencia antes de registrarlo.';
  end if;

  v_tarifa_esperada := tarifa_vigente_torneo(v_tournament_id, v_player_id);

  insert into comprobantes_transferencia (
    tournament_pre_reservation_id, storage_path, monto_capturado,
    tarifa_esperada, diferencia, referencia_bancaria, comentarios, subido_por
  ) values (
    p_pre_reserva_id, p_storage_path, p_monto_capturado,
    v_tarifa_esperada, p_monto_capturado - v_tarifa_esperada,
    p_referencia_bancaria, p_comentarios, auth.uid()
  )
  returning id into v_comprobante_id;

  return v_comprobante_id;
end;
$$;

-- 4. Función: confirmar el pago (paso 2 — crea la inscripción real).
create or replace function confirmar_pago_transferencia_prereserva(p_comprobante_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_pre_reserva_id  uuid;
  v_tournament_id   uuid;
  v_player_id       uuid;
  v_category_id     uuid;
  v_team_id         uuid;
  v_club_id         uuid;
  v_monto_capturado numeric;
  v_ya_confirmado   boolean;
  v_registration_id uuid;
begin
  select c.tournament_pre_reservation_id, c.monto_capturado, c.confirmado
    into v_pre_reserva_id, v_monto_capturado, v_ya_confirmado
    from comprobantes_transferencia c
   where c.id = p_comprobante_id;

  if v_pre_reserva_id is null then
    raise exception 'Comprobante no encontrado.';
  end if;

  if v_ya_confirmado then
    raise exception 'Este comprobante ya fue usado para confirmar un pago.';
  end if;

  select pr.tournament_id, pr.player_id, pr.tournament_category_id, pr.tournament_team_id, t.club_id
    into v_tournament_id, v_player_id, v_category_id, v_team_id, v_club_id
    from tournament_pre_reservations pr
    join tournaments t on t.id = pr.tournament_id
   where pr.id = v_pre_reserva_id
     and pr.activo = true
     and pr.tournament_registration_id is null;

  if v_tournament_id is null then
    raise exception 'La pre-reserva no existe, está inactiva, o ya fue convertida a inscripción.';
  end if;

  if not (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), v_tournament_id)
    or is_club_admin(auth.uid(), v_club_id)
  ) then
    raise exception 'No tienes permiso para confirmar pagos en este torneo.';
  end if;

  -- Este insert dispara TODOS los triggers normales de tournament_registrations:
  -- resolver_categoria_y_marca, validar_cupo_categoria_cruzado, validar_cupo_total_torneo,
  -- validar_cupo_equipo, validar_perfil_completo, etc. — sin duplicar esa lógica aquí.
  -- Si cualquiera de esos triggers rechaza, toda la función revierte (nada queda a medias).
  insert into tournament_registrations (
    tournament_id, player_id, tournament_category_id, tournament_team_id,
    monto_pagado, medio_pago, referencia_pago
  ) values (
    v_tournament_id, v_player_id, v_category_id, v_team_id,
    v_monto_capturado, 'transferencia', 'Comprobante: ' || p_comprobante_id::text
  )
  returning id into v_registration_id;

  update tournament_pre_reservations
     set tournament_registration_id = v_registration_id
   where id = v_pre_reserva_id;

  update comprobantes_transferencia
     set confirmado = true,
         confirmado_por = auth.uid(),
         fecha_confirmacion = now(),
         tournament_registration_id = v_registration_id
   where id = p_comprobante_id;

  return v_registration_id;
end;
$$;

-- 5. Políticas de Storage para el bucket. Convención de path OBLIGATORIA para que estas
--    políticas funcionen: '{tournament_id}/{pre_reserva_id}/{nombre_archivo}' — el
--    frontend/Lovable debe subir los archivos respetando este formato de carpeta.
create policy comprobantes_transferencia_storage_select
  on storage.objects
  for select
  using (
    bucket_id = 'comprobantes-transferencia'
    and (
      is_superadmin(auth.uid())
      or is_tournament_organizer(auth.uid(), (split_part(name, '/', 1))::uuid)
      or is_club_admin(auth.uid(), (select club_id from tournaments where id = (split_part(name, '/', 1))::uuid))
    )
  );

create policy comprobantes_transferencia_storage_insert
  on storage.objects
  for insert
  with check (
    bucket_id = 'comprobantes-transferencia'
    and (
      is_superadmin(auth.uid())
      or is_tournament_organizer(auth.uid(), (split_part(name, '/', 1))::uuid)
      or is_club_admin(auth.uid(), (select club_id from tournaments where id = (split_part(name, '/', 1))::uuid))
    )
  );
