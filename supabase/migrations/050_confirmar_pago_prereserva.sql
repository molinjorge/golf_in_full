-- =========================================================
-- MIGRACIÓN 050
-- Confirmar pago de una pre-reserva -> crea la inscripción real
-- en tournament_registrations, enlazada a la pre-reserva original
-- (que se conserva como historial, marcada como pagada).
-- =========================================================

alter type medio_pago_licencia add value if not exists 'efectivo';

alter table tournament_pre_reservations
  add column tournament_registration_id uuid references tournament_registrations (id) on delete restrict;

alter table tournament_pre_reservations
  add constraint tournament_pre_reservations_registro_unico unique (tournament_registration_id);

comment on column tournament_pre_reservations.tournament_registration_id is 'Se llena cuando la pre-reserva se confirma y se crea la inscripción real correspondiente. La pre-reserva se conserva como historial, no se borra.';

create or replace function validar_cupo_categoria_cruzado()
returns trigger as $$
declare
  v_cupo_maximo integer;
  v_total       integer;
begin
  select cupo_maximo into v_cupo_maximo
    from tournament_categories where id = new.tournament_category_id;

  if v_cupo_maximo is not null then
    select
      (select count(*) from tournament_registrations
        where tournament_category_id = new.tournament_category_id and activo = true)
      +
      (select count(*) from tournament_pre_reservations
        where tournament_category_id = new.tournament_category_id
          and activo = true
          and tournament_registration_id is null)
    into v_total;

    if v_total >= v_cupo_maximo then
      raise exception 'Esta categoría ya alcanzó su cupo máximo de % lugares (contando inscripciones en línea y pre-reservas).', v_cupo_maximo;
    end if;
  end if;

  return new;
end;
$$ language plpgsql;

create or replace function confirmar_pago_prereserva(
  p_pre_reserva_id  uuid,
  p_medio_pago_real medio_pago_licencia,
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

comment on function confirmar_pago_prereserva is 'Confirma el pago de una pre-reserva: crea la inscripción real en tournament_registrations y enlaza ambas filas. La pre-reserva se conserva como historial. Verifica autorización manualmente (superadmin, club_admin del club, o tournament_organizer de ese torneo).';

grant execute on function confirmar_pago_prereserva(uuid, medio_pago_licencia, text) to authenticated;
