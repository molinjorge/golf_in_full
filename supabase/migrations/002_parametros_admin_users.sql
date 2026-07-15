-- =========================================================
-- MIGRACIÓN 002
-- 1) Tabla de parámetros del sistema (controlados por superadmin)
-- 2) Tabla de administradores/organizadores
-- 3) Ajustes a "players" para depender de los parámetros
-- =========================================================

-- ---------------------------------------------------------
-- 1) TABLA DE PARÁMETROS DEL SISTEMA
-- ---------------------------------------------------------
-- Diseñada como key-value (jsonb) en vez de columnas fijas,
-- para que el dashboard de superadmin pueda agregar nuevos
-- parámetros en el futuro sin requerir una migración de esquema.

create table system_parameters (
  key            text        primary key,          -- ej. 'handicap_range'
  value          jsonb       not null,              -- ej. {"min": -10, "max": 54}
  tipo_dato      text        not null,              -- 'numeric' | 'integer' | 'boolean' | 'text' | 'json'
  descripcion    text,                                -- explicación visible en el dashboard
  updated_by     uuid,                                -- se conecta a admin_users más abajo
  updated_at     timestamptz not null default now()
);

comment on table system_parameters is 'Parámetros globales configurables por el superadministrador desde su dashboard.';
comment on column system_parameters.value is 'Valor del parámetro en formato jsonb, para soportar distintos tipos de dato sin cambiar el esquema.';

-- Semilla inicial: rango de hándicap válido en toda la plataforma
insert into system_parameters (key, value, tipo_dato, descripcion)
values (
  'handicap_range',
  '{"min": -10, "max": 54}'::jsonb,
  'json',
  'Rango permitido para handicap_declarado y handicap_verificado en la tabla players.'
);

-- ---------------------------------------------------------
-- 2) TABLA DE ADMINISTRADORES / ORGANIZADORES
-- ---------------------------------------------------------

create type admin_rol as enum (
  'superadmin',            -- control total de la plataforma, incluidos parámetros
  'club_admin',             -- administra un club y sus torneos
  'tournament_organizer'    -- organiza torneos puntuales, sin control del club
);

create table admin_users (
  id                uuid        primary key default gen_random_uuid(),

  -- Vínculo con Supabase Auth (login real de la plataforma)
  auth_user_id      uuid        unique,     -- referencia a auth.users(id); ver nota abajo

  email             citext      not null,
  nombres           text        not null,
  apellidos         text        not null,
  rol               admin_rol   not null,

  -- club_id se añadirá con ALTER TABLE cuando exista la tabla "clubs"
  -- (un club_admin/tournament_organizer normalmente pertenece a un club)

  activo            boolean     not null default true,

  created_at        timestamptz not null default now(),
  updated_at        timestamptz not null default now(),

  constraint admin_users_email_unique unique (email)
);

-- Nota: en Supabase, auth.users ya existe de forma nativa.
-- Esta FK se agrega por separado porque auth.users vive en el
-- esquema "auth", no en "public", y algunas herramientas (como
-- Lovable) prefieren crearla desde su propio flujo de migraciones.
alter table admin_users
  add constraint admin_users_auth_user_fk
  foreign key (auth_user_id) references auth.users (id) on delete set null;

create trigger trg_admin_users_updated_at
before update on admin_users
for each row execute function set_updated_at();

comment on table admin_users is 'Administradores y organizadores de la plataforma (no confundir con players/jugadores).';
comment on column admin_users.rol is 'superadmin: control total. club_admin: gestiona un club. tournament_organizer: gestiona torneos puntuales.';

-- Ahora que admin_users existe, conectamos quién actualiza los parámetros
alter table system_parameters
  add constraint system_parameters_updated_by_fk
  foreign key (updated_by) references admin_users (id) on delete set null;

-- ---------------------------------------------------------
-- 3) AJUSTES A "players"
-- ---------------------------------------------------------

-- 3a) Vínculo con Supabase Auth para el login del jugador
alter table players
  add column auth_user_id uuid unique;

alter table players
  add constraint players_auth_user_fk
  foreign key (auth_user_id) references auth.users (id) on delete set null;

-- 3b) Ahora que admin_users existe, formalizamos quién verifica el hándicap
alter table players
  add constraint players_handicap_verificado_por_fk
  foreign key (handicap_verificado_por) references admin_users (id) on delete set null;

-- 3c) Quitamos los CHECK fijos de rango de hándicap...
alter table players drop constraint players_handicap_declarado_rango;
alter table players drop constraint players_handicap_verificado_rango;

-- ...y los sustituimos por un trigger que valida contra system_parameters,
-- para que el superadmin pueda cambiar el rango sin tocar el esquema.

create or replace function validate_handicap_range()
returns trigger as $$
declare
  v_min numeric;
  v_max numeric;
begin
  select (value->>'min')::numeric, (value->>'max')::numeric
    into v_min, v_max
    from system_parameters
   where key = 'handicap_range';

  if new.handicap_declarado is not null
     and (new.handicap_declarado < v_min or new.handicap_declarado > v_max) then
    raise exception 'handicap_declarado (%) fuera del rango permitido (% a %)',
      new.handicap_declarado, v_min, v_max;
  end if;

  if new.handicap_verificado is not null
     and (new.handicap_verificado < v_min or new.handicap_verificado > v_max) then
    raise exception 'handicap_verificado (%) fuera del rango permitido (% a %)',
      new.handicap_verificado, v_min, v_max;
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_players_validate_handicap
before insert or update on players
for each row execute function validate_handicap_range();

-- ---------------------------------------------------------
-- SEGURIDAD A NIVEL DE FILA (RLS) — control del superadmin
-- ---------------------------------------------------------
-- Regla de negocio: solo el superadmin puede modificar parámetros
-- y gestionar otros administradores. Todos los usuarios autenticados
-- pueden leer los parámetros (útil para que el frontend, ej. formularios
-- de registro, conozca el rango vigente de hándicap).

alter table system_parameters enable row level security;
alter table admin_users enable row level security;

-- Lectura de parámetros: cualquier usuario autenticado
create policy system_parameters_select on system_parameters
  for select
  to authenticated
  using (true);

-- Escritura de parámetros: solo superadmin
create policy system_parameters_write on system_parameters
  for all
  to authenticated
  using (
    exists (
      select 1 from admin_users
       where admin_users.auth_user_id = auth.uid()
         and admin_users.rol = 'superadmin'
         and admin_users.activo = true
    )
  )
  with check (
    exists (
      select 1 from admin_users
       where admin_users.auth_user_id = auth.uid()
         and admin_users.rol = 'superadmin'
         and admin_users.activo = true
    )
  );

-- admin_users: cada administrador ve su propio registro;
-- el superadmin ve y gestiona a todos.
create policy admin_users_select_self on admin_users
  for select
  to authenticated
  using (
    auth_user_id = auth.uid()
    or exists (
      select 1 from admin_users su
       where su.auth_user_id = auth.uid()
         and su.rol = 'superadmin'
         and su.activo = true
    )
  );

create policy admin_users_manage_superadmin on admin_users
  for insert
  to authenticated
  with check (
    exists (
      select 1 from admin_users su
       where su.auth_user_id = auth.uid()
         and su.rol = 'superadmin'
         and su.activo = true
    )
  );

create policy admin_users_update_superadmin on admin_users
  for update
  to authenticated
  using (
    exists (
      select 1 from admin_users su
       where su.auth_user_id = auth.uid()
         and su.rol = 'superadmin'
         and su.activo = true
    )
  );
