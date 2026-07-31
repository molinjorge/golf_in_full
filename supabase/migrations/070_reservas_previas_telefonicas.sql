-- =========================================================
-- MIGRACIÓN 070
-- Reserva previa telefónica: para alguien que llama pidiendo
-- apartar lugar, pero NO está en el catálogo. Se captura nombre
-- + teléfono + compromiso (categoría, modalidad, monto, fecha
-- límite) SIN player_id todavía. Cuando esa persona se
-- autoregistra por su cuenta (con su propio correo), el sistema
-- cruza por teléfono automáticamente: si hay una reserva previa
-- activa, la convierte en tournament_pre_reservations real y
-- cancela la reserva previa. Si no hay coincidencia, no pasa nada.
-- =========================================================

create table phone_reservations (
  id                       uuid                    primary key default gen_random_uuid(),
  tournament_id            uuid                    not null references tournaments (id) on delete restrict,
  tournament_category_id   uuid                    not null references tournament_categories (id) on delete restrict,

  nombre_completo          text                    not null,
  correo                   citext                  not null,   -- obligatorio: sin esto no se le puede mandar la invitación
  telefono_pais            text                    not null,
  telefono_lada            text                    not null,
  telefono_numero          text                    not null,

  modalidad                modalidad_pre_reserva   not null,
  monto                    numeric(10,2)           not null,
  fecha_limite_pago        timestamptz,

  correo_invitacion_enviado boolean                not null default false,
  convertida_a_pre_reserva_id uuid                 references tournament_pre_reservations (id) on delete set null,

  activo                   boolean                 not null default true,
  fecha_baja               timestamptz,
  dado_de_baja_por         uuid                    references admin_users (id) on delete restrict,
  motivo_baja              text,

  created_by               uuid                    references admin_users (id) on delete restrict,
  created_at               timestamptz             not null default now(),
  updated_at                timestamptz             not null default now(),

  constraint phone_reservations_monto_valido check (monto >= 0)
);

comment on table phone_reservations is 'Reserva previa capturada por llamada telefónica, para alguien que aún no está en el catálogo de jugadores. El correo es obligatorio — sin él no se puede mandar la invitación a registrarse. Se reconcilia automáticamente por teléfono cuando esa persona se autoregistra.';

create trigger trg_phone_reservations_updated_at
before update on phone_reservations
for each row execute function set_updated_at();

create trigger trg_track_estatus_phone_reservations
before update on phone_reservations
for each row execute function track_estatus_activo();

create trigger trg_audit_phone_reservations
after insert or update or delete on phone_reservations
for each row execute function log_audit();

create trigger trg_validar_categoria_pertenece_al_torneo_phone
before insert or update on phone_reservations
for each row execute function validar_categoria_pertenece_al_torneo();

create index idx_phone_reservations_tournament on phone_reservations (tournament_id);
create index idx_phone_reservations_telefono on phone_reservations (telefono_pais, telefono_lada, telefono_numero) where activo = true;

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
      tournament_id, player_id, tournament_category_id,
      modalidad, monto, fecha_limite_pago, created_by
    ) values (
      v_reserva.tournament_id, new.id, v_reserva.tournament_category_id,
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

comment on function reconciliar_reserva_previa_telefonica is 'Al autoregistrarse un jugador con teléfono, busca reservas previas telefónicas activas con ese mismo teléfono y las convierte automáticamente en pre-reservas formales (con player_id ya vinculado).';

create trigger trg_reconciliar_reserva_previa_telefonica
after insert on players
for each row execute function reconciliar_reserva_previa_telefonica();

alter table phone_reservations enable row level security;

create policy phone_reservations_select on phone_reservations
  for select to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy phone_reservations_insert on phone_reservations
  for insert to authenticated
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy phone_reservations_update on phone_reservations
  for update to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

grant select, insert, update on phone_reservations to authenticated;
