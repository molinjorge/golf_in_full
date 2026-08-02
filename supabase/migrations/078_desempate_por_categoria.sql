-- =========================================================
-- MIGRACIÓN 078
-- Amplía tournament_tiebreak_rules con dos dimensiones nuevas:
-- 1) tournament_category_id (opcional) — permite un método
--    distinto por categoría (ej. Playoff para Campeonato,
--    Countback neto para categorías de hándicap). NULL = aplica
--    como default para categorías sin configuración propia.
-- 2) tipo_resultado (gross/neto) — qué tipo de score se compara
--    en el countback.
-- =========================================================

create type tipo_resultado_desempate as enum ('gross', 'neto');

alter table tournament_tiebreak_rules
  add column tournament_category_id uuid references tournament_categories (id) on delete restrict,
  add column tipo_resultado tipo_resultado_desempate not null default 'neto';

comment on column tournament_tiebreak_rules.tournament_category_id is 'Categoría específica a la que aplica esta secuencia. NULL = aplica como default para cualquier categoría del torneo sin configuración propia.';
comment on column tournament_tiebreak_rules.tipo_resultado is 'Si el countback compara resultados gross o netos. Típicamente gross para categorías scratch/campeonato, neto para categorías de hándicap.';

drop index if exists tournament_tiebreak_rules_unico_activo;

create unique index tournament_tiebreak_rules_unico_activo
  on tournament_tiebreak_rules (tournament_id, coalesce(tournament_category_id, '00000000-0000-0000-0000-000000000000'::uuid), alcance, orden)
  where activo = true;

create trigger trg_validar_categoria_pertenece_al_torneo_tiebreak
before insert or update on tournament_tiebreak_rules
for each row
when (new.tournament_category_id is not null)
execute function validar_categoria_pertenece_al_torneo();

-- Importante: cambiar los parámetros no "reemplaza" la función
-- vieja (Postgres las distingue por firma completa) — hay que
-- borrar la versión anterior explícitamente.
drop function if exists aplicar_secuencia_desempate(uuid, alcance_desempate, uuid);

create or replace function aplicar_secuencia_desempate(
  p_tournament_id          uuid,
  p_alcance                alcance_desempate,
  p_secuencia_id           uuid,
  p_tournament_category_id uuid default null,
  p_tipo_resultado         tipo_resultado_desempate default 'neto'
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  update tournament_tiebreak_rules
     set activo = false, fecha_baja = now(), motivo_baja = 'Reemplazada al aplicar una nueva plantilla de secuencia'
   where tournament_id = p_tournament_id
     and alcance = p_alcance
     and coalesce(tournament_category_id, '00000000-0000-0000-0000-000000000000'::uuid)
         = coalesce(p_tournament_category_id, '00000000-0000-0000-0000-000000000000'::uuid)
     and activo = true;

  insert into tournament_tiebreak_rules (tournament_id, alcance, orden, tiebreak_method_id, tournament_category_id, tipo_resultado)
  select p_tournament_id, p_alcance, sp.orden, sp.tiebreak_method_id, p_tournament_category_id, p_tipo_resultado
    from secuencia_desempate_pasos sp
   where sp.secuencia_id = p_secuencia_id
   order by sp.orden;
end;
$$;

comment on function aplicar_secuencia_desempate is 'Aplica una plantilla de secuencia de desempate a un torneo, opcionalmente acotada a una categoría específica y con el tipo de resultado (gross/neto) indicado. tournament_category_id=NULL aplica como default general.';
