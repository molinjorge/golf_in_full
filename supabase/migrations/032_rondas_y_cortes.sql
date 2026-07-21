-- =========================================================
-- MIGRACIÓN 032
-- Rondas de torneo: cada torneo tiene 1 o más rondas, cada una
-- con su propia fecha, modalidad y campo. Reemplaza la idea de
-- "un torneo = una sola modalidad fija".
-- Reglas de corte: por posición o por score, siempre por
-- categoría, ligadas a después de qué ronda ocurren.
-- =========================================================

-- ---------------------------------------------------------
-- TOURNAMENT_ROUNDS
-- ---------------------------------------------------------

create table tournament_rounds (
  id                       uuid            primary key default gen_random_uuid(),
  tournament_id            uuid            not null references tournaments (id) on delete restrict,

  numero_ronda             integer         not null,
  fecha                    date            not null,
  -- Opcional a propósito: si es NULL, hereda tournament_formats
  -- de tournaments.tournament_format_id. Solo se sobreescribe en
  -- el caso excepcional de que esta ronda use una modalidad
  -- distinta al resto del torneo (ej. Nacional de Parejas).
  tournament_format_id     uuid            references tournament_formats (id) on delete restrict,
  campo_golf_id            uuid            not null references campos_golf (id) on delete restrict,

  handicap_allowance_pct   numeric(5,2),

  activo                   boolean         not null default true,
  fecha_baja               timestamptz,
  dado_de_baja_por         uuid            references admin_users (id) on delete restrict,
  motivo_baja              text,

  created_by               uuid            references admin_users (id) on delete restrict,
  created_at               timestamptz     not null default now(),
  updated_at               timestamptz     not null default now(),

  constraint tournament_rounds_numero_unico unique (tournament_id, numero_ronda),
  constraint tournament_rounds_numero_positivo check (numero_ronda > 0),
  constraint tournament_rounds_allowance_valido check (handicap_allowance_pct is null or handicap_allowance_pct between 0 and 100)
);

comment on table tournament_rounds is 'Cada ronda de un torneo, con su propia fecha/modalidad/campo. Un torneo simple de N días con la misma modalidad tiene N filas idénticas en modalidad; un torneo tipo Nacional de Parejas tiene una fila por día con modalidades distintas.';

create trigger trg_tournament_rounds_updated_at
before update on tournament_rounds
for each row execute function set_updated_at();

create trigger trg_track_estatus_tournament_rounds
before update on tournament_rounds
for each row execute function track_estatus_activo();

create trigger trg_audit_tournament_rounds
after insert or update or delete on tournament_rounds
for each row execute function log_audit();

create index idx_tournament_rounds_tournament on tournament_rounds (tournament_id);
create index idx_tournament_rounds_campo on tournament_rounds (campo_golf_id);

-- Vista de conveniencia: resuelve la modalidad EFECTIVA de cada
-- ronda (la propia si se sobreescribió, si no la del torneo) —
-- para que el motor/frontend no tenga que repetir el COALESCE
-- cada vez que necesite saber "¿con qué modalidad se juega esta ronda?".
create view tournament_rounds_efectivo
with (security_invoker = true) as
select
  tr.id,
  tr.tournament_id,
  tr.numero_ronda,
  tr.fecha,
  tr.campo_golf_id,
  coalesce(tr.tournament_format_id, t.tournament_format_id) as tournament_format_id_efectivo,
  (tr.tournament_format_id is not null) as modalidad_sobreescrita,
  coalesce(tr.handicap_allowance_pct, tf.handicap_allowance_default) as handicap_allowance_efectivo
from tournament_rounds tr
join tournaments t on t.id = tr.tournament_id
left join tournament_formats tf on tf.id = coalesce(tr.tournament_format_id, t.tournament_format_id);

comment on view tournament_rounds_efectivo is 'Resuelve la modalidad y % de hándicap efectivos de cada ronda, aplicando la herencia desde el torneo cuando la ronda no los sobreescribe.';

grant select on tournament_rounds_efectivo to anon, authenticated;

-- ---------------------------------------------------------
-- TOURNAMENT_CUT_RULES
-- ---------------------------------------------------------

create type tipo_corte as enum ('posicion', 'score');

create table tournament_cut_rules (
  id                     uuid        primary key default gen_random_uuid(),
  despues_de_ronda_id    uuid        not null references tournament_rounds (id) on delete restrict,
  tournament_category_id uuid        not null references tournament_categories (id) on delete restrict,

  tipo_corte             tipo_corte  not null,
  valor                  numeric     not null,

  created_by             uuid        references admin_users (id) on delete restrict,
  created_at             timestamptz not null default now(),

  constraint tournament_cut_rules_unico unique (despues_de_ronda_id, tournament_category_id),
  constraint tournament_cut_rules_valor_positivo check (valor > 0)
);

comment on table tournament_cut_rules is 'Regla de corte: después de qué ronda, para qué categoría del torneo, y bajo qué criterio (posición o score límite). El corte siempre se calcula por categoría, nunca de forma global.';

create or replace function validar_consistencia_cut_rule()
returns trigger as $$
declare
  v_tournament_ronda uuid;
  v_tournament_categoria uuid;
begin
  select tournament_id into v_tournament_ronda from tournament_rounds where id = new.despues_de_ronda_id;
  select tournament_id into v_tournament_categoria from tournament_categories where id = new.tournament_category_id;

  if v_tournament_ronda is distinct from v_tournament_categoria then
    raise exception 'La ronda y la categoría de esta regla de corte deben pertenecer al mismo torneo.';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_consistencia_cut_rule
before insert or update on tournament_cut_rules
for each row execute function validar_consistencia_cut_rule();

create index idx_tournament_cut_rules_ronda on tournament_cut_rules (despues_de_ronda_id);
create index idx_tournament_cut_rules_categoria on tournament_cut_rules (tournament_category_id);

-- ---------------------------------------------------------
-- RLS
-- ---------------------------------------------------------

alter table tournament_rounds enable row level security;
alter table tournament_cut_rules enable row level security;

create policy tournament_rounds_select on tournament_rounds
  for select to public using (activo = true or is_superadmin(auth.uid()));

create policy tournament_rounds_write on tournament_rounds
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

create policy tournament_cut_rules_select on tournament_cut_rules
  for select to public using (true);

create policy tournament_cut_rules_write on tournament_cut_rules
  for all to authenticated
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from tournament_rounds tr
      join tournaments t on t.id = tr.tournament_id
      where tr.id = despues_de_ronda_id
        and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from tournament_rounds tr
      join tournaments t on t.id = tr.tournament_id
      where tr.id = despues_de_ronda_id
        and (is_tournament_organizer(auth.uid(), t.id) or is_club_admin(auth.uid(), t.club_id))
    )
  );

-- ---------------------------------------------------------
-- GRANTS
-- ---------------------------------------------------------

grant select on tournament_rounds to anon;
grant select, insert, update, delete on tournament_rounds to authenticated;

grant select on tournament_cut_rules to anon;
grant select, insert, update, delete on tournament_cut_rules to authenticated;
