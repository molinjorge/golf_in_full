-- =========================================================
-- MIGRACIÓN 031
-- 1) Catálogo de métodos de desempate + secuencia encadenable
--    por torneo, con alcance distinto según el lugar a desempatar.
-- 2) % de asignación de hándicap: default por modalidad,
--    con posibilidad de excepción por torneo.
-- 3) Override de rating/slope de marca de salida por torneo
--    (ej. categorías femeniles sin certificación oficial).
-- Es estructura general (no exclusiva de Stroke Play): tie-break
-- y % de hándicap aplican a cualquier modalidad.
-- =========================================================

-- ---------------------------------------------------------
-- 1) CATÁLOGO DE MÉTODOS DE DESEMPATE
-- ---------------------------------------------------------

create table tiebreak_methods (
  id                 uuid        primary key default gen_random_uuid(),
  code               text        not null unique,
  name               text        not null,
  description        text,

  activo             boolean     not null default true,
  fecha_baja         timestamptz,
  dado_de_baja_por   uuid        references admin_users (id) on delete restrict,
  motivo_baja        text,

  created_by         uuid        references admin_users (id) on delete restrict,
  created_at         timestamptz not null default now(),
  updated_at         timestamptz not null default now()
);

comment on table tiebreak_methods is 'Catálogo de métodos de desempate disponibles (muerte súbita, comparación de tarjeta por tramos, sorteo).';

create trigger trg_tiebreak_methods_updated_at
before update on tiebreak_methods
for each row execute function set_updated_at();

create trigger trg_track_estatus_tiebreak_methods
before update on tiebreak_methods
for each row execute function track_estatus_activo();

create trigger trg_audit_tiebreak_methods
after insert or update or delete on tiebreak_methods
for each row execute function log_audit();

insert into tiebreak_methods (code, name, description) values
  ('MUERTE_SUBITA',        'Muerte súbita',                'Playoff hoyo por hoyo hasta que un jugador/equipo saque ventaja.'),
  ('TARJETA_18',           'Tarjeta completa (18 hoyos)',  'Compara el score neto de la vuelta completa.'),
  ('TARJETA_ULTIMOS_9',    'Últimos 9 hoyos',              'Compara el score de los hoyos 10 al 18.'),
  ('TARJETA_ULTIMOS_6',    'Últimos 6 hoyos',              'Compara el score de los hoyos 13 al 18.'),
  ('TARJETA_ULTIMOS_3',    'Últimos 3 hoyos',              'Compara el score de los hoyos 16 al 18.'),
  ('TARJETA_ULTIMO_HOYO',  'Último hoyo',                  'Compara únicamente el hoyo 18.'),
  ('SORTEO',               'Sorteo',                       'Última instancia si el empate persiste tras todos los métodos anteriores.');

-- ---------------------------------------------------------
-- SECUENCIA DE DESEMPATE POR TORNEO (encadenable, con alcance)
-- ---------------------------------------------------------

create type alcance_desempate as enum ('primer_lugar', 'otros_lugares', 'todos');

create table tournament_tiebreak_rules (
  id                 uuid                primary key default gen_random_uuid(),
  tournament_id      uuid                not null references tournaments (id) on delete restrict,
  alcance            alcance_desempate   not null,
  orden              integer             not null,
  tiebreak_method_id uuid                not null references tiebreak_methods (id) on delete restrict,

  created_by         uuid                references admin_users (id) on delete restrict,
  created_at         timestamptz         not null default now(),

  constraint tournament_tiebreak_rules_unico unique (tournament_id, alcance, orden)
);

comment on table tournament_tiebreak_rules is 'Secuencia de métodos de desempate de un torneo. Un mismo torneo puede tener una secuencia distinta para el primer lugar que para el resto.';

create index idx_tournament_tiebreak_rules_tournament on tournament_tiebreak_rules (tournament_id);

-- ---------------------------------------------------------
-- 2) % DE ASIGNACIÓN DE HÁNDICAP: default por modalidad,
--    override opcional por torneo
-- ---------------------------------------------------------

alter table tournament_formats
  add column handicap_allowance_default numeric(5,2);

comment on column tournament_formats.handicap_allowance_default is 'Porcentaje sugerido de asignación de hándicap para esta modalidad (ej. 95.00 para Stroke Play individual). Puede sobreescribirse por torneo.';

alter table tournament_formats
  add constraint tournament_formats_allowance_valido
  check (handicap_allowance_default is null or handicap_allowance_default between 0 and 100);

update tournament_formats set handicap_allowance_default = 95.00 where code = 'STROKE_PLAY';
update tournament_formats set handicap_allowance_default = 95.00 where code = 'STABLEFORD_IND';
update tournament_formats set handicap_allowance_default = 85.00 where code = 'BEST_BALL';

-- Nota: el override de % de hándicap se movió a nivel de RONDA
-- (tournament_rounds.handicap_allowance_pct, migración 032),
-- ya que la modalidad ahora puede variar día a día dentro de un
-- mismo torneo — un solo override a nivel torneo ya no tiene un
-- lugar inequívoco donde aplicar.

-- ---------------------------------------------------------
-- 3) OVERRIDE DE RATING/SLOPE DE MARCA DE SALIDA POR TORNEO
-- ---------------------------------------------------------

create table tournament_tee_overrides (
  id                 uuid            primary key default gen_random_uuid(),
  tournament_id      uuid            not null references tournaments (id) on delete restrict,
  marca_salida_id    uuid            not null references marcas_salida (id) on delete restrict,

  rating_caballeros  numeric(4,1),
  slope_caballeros   integer,
  rating_damas       numeric(4,1),
  slope_damas        integer,

  motivo             text,

  created_by         uuid            references admin_users (id) on delete restrict,
  created_at         timestamptz     not null default now(),
  updated_at         timestamptz     not null default now(),

  constraint tournament_tee_overrides_unico unique (tournament_id, marca_salida_id),
  constraint tournament_tee_overrides_slope_cab_valido check (slope_caballeros is null or slope_caballeros between 55 and 155),
  constraint tournament_tee_overrides_slope_damas_valido check (slope_damas is null or slope_damas between 55 and 155)
);

comment on table tournament_tee_overrides is 'Excepción opcional de rating/slope para una marca de salida, específica de un torneo. Todos los campos son opcionales — el motor debe usar el valor de marcas_salida cuando no haya override.';

create trigger trg_tournament_tee_overrides_updated_at
before update on tournament_tee_overrides
for each row execute function set_updated_at();

create index idx_tournament_tee_overrides_tournament on tournament_tee_overrides (tournament_id);

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table tiebreak_methods enable row level security;
alter table tournament_tiebreak_rules enable row level security;
alter table tournament_tee_overrides enable row level security;

create policy tiebreak_methods_select on tiebreak_methods
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy tiebreak_methods_write on tiebreak_methods
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy tournament_tiebreak_rules_select on tournament_tiebreak_rules
  for select to public using (true);
create policy tournament_tiebreak_rules_write on tournament_tiebreak_rules
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

create policy tournament_tee_overrides_select on tournament_tee_overrides
  for select to public using (true);
create policy tournament_tee_overrides_write on tournament_tee_overrides
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on tiebreak_methods to anon;
grant select, insert, update, delete on tiebreak_methods to authenticated;

grant select on tournament_tiebreak_rules to anon;
grant select, insert, update, delete on tournament_tiebreak_rules to authenticated;

grant select on tournament_tee_overrides to anon;
grant select, insert, update, delete on tournament_tee_overrides to authenticated;
