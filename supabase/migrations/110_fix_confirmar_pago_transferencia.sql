-- 110_fix_confirmar_pago_transferencia_reutiliza_funcion_existente.sql
--
-- Corrección de bug real y de diseño: confirmar_pago_transferencia_prereserva() (109)
-- duplicó la lógica de crear la inscripción en vez de reutilizar confirmar_pago_prereserva()
-- (050), que ya existía y hace esto correctamente. La duplicación causó un bug real:
-- mi versión nunca actualizaba tournament_pre_reservations.estatus a 'pagado' (solo
-- vinculaba tournament_registration_id), y la pantalla de "Reservas previas" que lee
-- ese campo seguía mostrando "Pendiente de pago" aunque el pago ya se había procesado
-- correctamente en tournament_registrations.
--
-- Fix: confirmar_pago_transferencia_prereserva() ahora llama a confirmar_pago_prereserva()
-- (050) para crear la inscripción — hereda automáticamente: actualización correcta de
-- estatus, resolución de admin_id vía admin_users, la bandera de sesión que evita el
-- conflicto de cupo de equipo ya conocido, y consistencia con el resto del sistema.
-- Ya no se duplica el INSERT en tournament_registrations dentro de esta función.
--
-- Además: tarifa_esperada (en registrar_comprobante_transferencia) cambia de recalcular
-- tarifa_vigente_torneo() al momento del pago, a usar tournament_pre_reservations.monto
-- — el precio que YA quedó fijado desde que se creó la pre-reserva (la fuente de verdad
-- real de "cuánto debía pagar esta persona"), evitando falsas alertas de "diferencia"
-- si la tarifa early bird del torneo cambió entre la pre-reserva y el pago.

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
  v_club_id        uuid;
  v_monto_esperado numeric;
  v_admin_id       uuid;
  v_comprobante_id uuid;
begin
  select pr.tournament_id, pr.monto, t.club_id
    into v_tournament_id, v_monto_esperado, v_club_id
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

  select id into v_admin_id from admin_users where auth_user_id = auth.uid();

  insert into comprobantes_transferencia (
    tournament_pre_reservation_id, storage_path, monto_capturado,
    tarifa_esperada, diferencia, referencia_bancaria, comentarios, subido_por
  ) values (
    p_pre_reserva_id, p_storage_path, p_monto_capturado,
    v_monto_esperado, p_monto_capturado - v_monto_esperado,
    p_referencia_bancaria, p_comentarios, v_admin_id
  )
  returning id into v_comprobante_id;

  return v_comprobante_id;
end;
$$;

create or replace function confirmar_pago_transferencia_prereserva(p_comprobante_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_pre_reserva_id  uuid;
  v_ya_confirmado   boolean;
  v_referencia      text;
  v_admin_id        uuid;
  v_registration    tournament_registrations;
begin
  select c.tournament_pre_reservation_id, c.confirmado, coalesce(c.referencia_bancaria, c.storage_path)
    into v_pre_reserva_id, v_ya_confirmado, v_referencia
    from comprobantes_transferencia c
   where c.id = p_comprobante_id;

  if v_pre_reserva_id is null then
    raise exception 'Comprobante no encontrado.';
  end if;

  if v_ya_confirmado then
    raise exception 'Este comprobante ya fue usado para confirmar un pago.';
  end if;

  select id into v_admin_id from admin_users where auth_user_id = auth.uid();

  -- Reutiliza la función existente (050): valida rol, estatus de la pre-reserva,
  -- resuelve admin_id, aplica la bandera de cupo de equipo, y actualiza correctamente
  -- tournament_pre_reservations.estatus a 'pagado' — nada de eso se duplica aquí.
  select * into v_registration
    from confirmar_pago_prereserva(v_pre_reserva_id, 'transferencia', v_referencia);

  update comprobantes_transferencia
     set confirmado = true,
         confirmado_por = v_admin_id,
         fecha_confirmacion = now(),
         tournament_registration_id = v_registration.id
   where id = p_comprobante_id;

  return v_registration.id;
end;
$$;
