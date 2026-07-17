-- =========================================================
-- MIGRACIÓN 024
-- Estructura de hoyos y marcas de salida por campo de golf.
-- Asume numeración simple de hoyos (1..numero_hoyos), sin
-- soporte todavía para "nueves combinables" en campos de 27+.
-- =========================================================

-- ---------------------------------------------------------
-- MARCAS_SALIDA (tee marks)
-- ---------------------------------------------------------

create table marcas_salida (
  id                 uuid        primary key default gen_random_uuid(),
  campo_golf_id      uuid        not null references campos_golf (id) on delete restrict,

  nombre             text        not null,        -- ej. 'Negras', 'Azules', 'Blancas'
  color_hex          text,                          -- opcional, para mostrar un swatch en UI
  rating             numeric(4,1),                 -- Course Rating (ej. 72.3)
  slope              integer,                        -- Slope Rating (55-155, estándar 113)

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint marcas_salida_nombre_unico unique (campo_golf_id, nombre),
  constraint marcas_salida_slope_valido check (slope is null or slope between 55 and 155)
);

comment on table marcas_salida is 'Marcas/colores de salida de un campo, con su Course Rating y Slope Rating oficiales.';

create trigger trg_marcas_salida_updated_at
before update on marcas_salida
for each row execute function set_updated_at();

create trigger trg_track_estatus_marcas_salida
before update on marcas_salida
for each row execute function track_estatus_activo();

create trigger trg_audit_marcas_salida
after insert or update or delete on marcas_salida
for each row execute function log_audit();

create index idx_marcas_salida_campo on marcas_salida (campo_golf_id);

-- ---------------------------------------------------------
-- HOYOS
-- ---------------------------------------------------------

create table hoyos (
  id                 uuid        primary key default gen_random_uuid(),
  campo_golf_id      uuid        not null references campos_golf (id) on delete restrict,

  numero_hoyo        integer     not null,
  par                integer     not null,
  handicap_hoyo      integer     not null,    -- stroke index, 1 a 18

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint hoyos_numero_unico unique (campo_golf_id, numero_hoyo),
  constraint hoyos_numero_valido check (numero_hoyo between 1 and 36),
  constraint hoyos_par_valido check (par between 3 and 6),
  constraint hoyos_handicap_valido check (handicap_hoyo between 1 and 18)
);

comment on table hoyos is 'Hoyos de un campo: par y hándicap de hoyo (stroke index). Numeración simple 1..N, sin soporte de nueves combinables todavía.';

create trigger trg_hoyos_updated_at
before update on hoyos
for each row execute function set_updated_at();

create trigger trg_audit_hoyos
after insert or update or delete on hoyos
for each row execute function log_audit();

create index idx_hoyos_campo on hoyos (campo_golf_id);

-- ---------------------------------------------------------
-- DISTANCIAS_HOYO (yardaje por hoyo, según marca de salida)
-- ---------------------------------------------------------

create table distancias_hoyo (
  id                 uuid        primary key default gen_random_uuid(),
  hoyo_id            uuid        not null references hoyos (id) on delete cascade,
  marca_salida_id    uuid        not null references marcas_salida (id) on delete cascade,
  distancia_yardas   integer     not null,

  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now(),

  constraint distancias_hoyo_unico unique (hoyo_id, marca_salida_id),
  constraint distancias_hoyo_positiva check (distancia_yardas > 0)
);

comment on table distancias_hoyo is 'Distancia de cada hoyo, específica por marca de salida.';

create trigger trg_distancias_hoyo_updated_at
before update on distancias_hoyo
for each row execute function set_updated_at();

create index idx_distancias_hoyo_hoyo on distancias_hoyo (hoyo_id);
create index idx_distancias_hoyo_marca on distancias_hoyo (marca_salida_id);

-- ---------------------------------------------------------
-- RLS — mismo criterio en las 3: público puede leer, solo
-- superadmin o el club_admin dueño del campo pueden escribir.
-- ---------------------------------------------------------

alter table marcas_salida enable row level security;
alter table hoyos enable row level security;
alter table distancias_hoyo enable row level security;

create policy marcas_salida_select on marcas_salida
  for select to public using (true);

create policy marcas_salida_write on marcas_salida
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (select 1 from campos_golf cg where cg.id = campo_golf_id and is_club_admin(auth.uid(), cg.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or exists (select 1 from campos_golf cg where cg.id = campo_golf_id and is_club_admin(auth.uid(), cg.club_id))
  );

create policy hoyos_select on hoyos
  for select to public using (true);

create policy hoyos_write on hoyos
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (select 1 from campos_golf cg where cg.id = campo_golf_id and is_club_admin(auth.uid(), cg.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or exists (select 1 from campos_golf cg where cg.id = campo_golf_id and is_club_admin(auth.uid(), cg.club_id))
  );

create policy distancias_hoyo_select on distancias_hoyo
  for select to public using (true);

create policy distancias_hoyo_write on distancias_hoyo
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from hoyos h
      join campos_golf cg on cg.id = h.campo_golf_id
      where h.id = hoyo_id and is_club_admin(auth.uid(), cg.club_id)
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from hoyos h
      join campos_golf cg on cg.id = h.campo_golf_id
      where h.id = hoyo_id and is_club_admin(auth.uid(), cg.club_id)
    )
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on marcas_salida, hoyos, distancias_hoyo to anon;
grant select, insert, update, delete on marcas_salida, hoyos, distancias_hoyo to authenticated;
