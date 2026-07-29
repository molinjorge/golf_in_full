-- =========================================================
-- MIGRACIÓN 046
-- Información "para convencer al jugador" de un torneo — separada
-- por completo de la configuración operativa (rondas/turnos/
-- cortes/desempates). Relación 1 a 1 con tournaments.
-- =========================================================

create table tournament_marketing_info (
  id                     uuid            primary key default gen_random_uuid(),
  tournament_id          uuid            not null unique references tournaments (id) on delete restrict,

  que_incluye_inscripcion text[],
  premios                 text[],
  kit_bienvenida          text[],

  incluye_alimentos       boolean         not null default false,
  detalle_alimentos       text,
  incluye_bebidas         boolean         not null default false,
  detalle_bebidas         text,
  incluye_carrito         boolean         not null default false,
  detalle_carrito         text,
  incluye_caddie          boolean         not null default false,
  detalle_caddie          text,

  beneficiario_nombre       text,
  beneficiario_descripcion  text,
  precio_socios             numeric(10,2),

  contacto_nombre      text,
  contacto_telefono    varchar(20),
  contacto_correo      citext,

  created_by           uuid            references admin_users (id) on delete restrict,
  created_at            timestamptz     not null default now(),
  updated_at            timestamptz     not null default now(),

  constraint tournament_marketing_precio_socios_valido check (precio_socios is null or precio_socios >= 0)
);

comment on table tournament_marketing_info is 'Contenido de venta/beneficios de un torneo (qué incluye, premios, kit, contacto). Separado de la configuración operativa. Un torneo tiene a lo más una fila.';

create trigger trg_tournament_marketing_info_updated_at
before update on tournament_marketing_info
for each row execute function set_updated_at();

create trigger trg_audit_tournament_marketing_info
after insert or update or delete on tournament_marketing_info
for each row execute function log_audit();

alter table tournament_marketing_info enable row level security;

create policy tournament_marketing_info_select on tournament_marketing_info
  for select to public using (true);

create policy tournament_marketing_info_write on tournament_marketing_info
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
  );

grant select on tournament_marketing_info to anon;
grant select, insert, update, delete on tournament_marketing_info to authenticated;
