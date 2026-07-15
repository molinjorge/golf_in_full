-- =========================================================
-- TABLA MAESTRA: players (jugadores)
-- Plataforma multi-club / multi-torneo de golf
-- Motor: PostgreSQL (Supabase)
-- =========================================================

-- Tipos enumerados -----------------------------------------------------

create type sexo_jugador as enum ('M', 'F');

create type estatus_handicap as enum (
  'sin_verificar',   -- el jugador lo declarÃ³, nadie lo ha confirmado
  'verificado',       -- un comitÃ©/organizador lo validÃ³ contra GHIN
  'vencido'            -- fue verificado pero ya pasÃ³ su vigencia
);

-- Tabla principal --------------------------------------------------------

create table players (
  id                          uuid primary key default gen_random_uuid(),

  -- IdentificaciÃ³n / login
  email                       citext        not null,

  -- Nombre
  apellidos                   text          not null,
  nombres                     text          not null,

  -- TelÃ©fono (separado para validar y formatear por paÃ­s/lada)
  telefono_pais               varchar(5),      -- ej. '+52'
  telefono_lada                varchar(5),      -- ej. '442' (cÃ³digo de Ã¡rea)
  telefono_numero             varchar(15),     -- ej. '1234567'

  -- Datos personales
  sexo                        sexo_jugador  not null,
  fecha_nacimiento            date          not null,

  -- Identificador oficial de hÃ¡ndicap (USGA/GHIN vÃ­a FMG)
  numero_ghin                 varchar(10),     -- nulo si aÃºn no lo tiene

  -- HÃ¡ndicap declarado por el jugador
  handicap_declarado          numeric(4,1),    -- permite valores "plus" (ej. -2.3)
  handicap_declarado_fecha    date,

  -- HÃ¡ndicap confirmado por un comitÃ©/organizador contra fuente oficial
  handicap_verificado         numeric(4,1),
  handicap_verificado_fecha   date,
  handicap_verificado_por     uuid,            -- referenciarÃ¡ a admins/organizadores (tabla futura)
  handicap_estatus            estatus_handicap not null default 'sin_verificar',

  -- AuditorÃ­a
  created_at                  timestamptz   not null default now(),
  updated_at                  timestamptz   not null default now(),

  -- Restricciones de integridad
  constraint players_email_unique unique (email),
  constraint players_ghin_unique unique (numero_ghin),
  constraint players_fecha_nacimiento_pasado check (fecha_nacimiento < current_date),
  constraint players_handicap_declarado_rango check (handicap_declarado between -10 and 54),
  constraint players_handicap_verificado_rango check (handicap_verificado between -10 and 54)
);

-- Requiere la extensiÃ³n citext para correos case-insensitive
create extension if not exists citext;

-- Ãndices de bÃºsqueda --------------------------------------------------

create index idx_players_apellidos_nombres on players (apellidos, nombres);
create index idx_players_ghin on players (numero_ghin) where numero_ghin is not null;
create index idx_players_handicap_estatus on players (handicap_estatus);

-- Trigger para mantener updated_at automÃ¡ticamente ----------------------

create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

create trigger trg_players_updated_at
before update on players
for each row execute function set_updated_at();

-- Comentarios de documentaciÃ³n ------------------------------------------

comment on table players is 'Tabla maestra Ãºnica de jugadores, compartida entre todos los clubes y torneos de la plataforma.';
comment on column players.email is 'Identificador funcional del jugador en la plataforma (Ãºnico, no distingue mayÃºsculas/minÃºsculas).';
comment on column players.numero_ghin is 'NÃºmero GHIN oficial (USGA/FMG). Nulo si el jugador aÃºn no lo tramita.';
comment on column players.handicap_declarado is 'Ãndice de hÃ¡ndicap que el propio jugador reporta al registrarse o actualizar su perfil.';
comment on column players.handicap_verificado is 'Ãndice de hÃ¡ndicap confirmado por un organizador/comitÃ© contra la fuente oficial (GHIN/consulta FMG).';
comment on column players.handicap_estatus is 'Estado del proceso de verificaciÃ³n del hÃ¡ndicap declarado.';
