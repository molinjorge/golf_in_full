-- =========================================================
-- MIGRACIÓN 030
-- 1) Limpia torneos de PRUEBA (y lo que depende de ellos),
--    confirmado explícitamente por el usuario — no hay datos
--    reales todavía.
-- 2) Siembra tournament_formats con las modalidades que ya
--    existían como enums fijos.
-- 3) Migra tournaments para referenciar tournament_formats en
--    vez de los enums formato_juego/modalidad_individual/
--    modalidad_equipo.
-- =========================================================

-- ---------------------------------------------------------
-- 1) LIMPIEZA DE DATOS DE PRUEBA
-- ---------------------------------------------------------

delete from tournament_categories;

update club_module_licenses set tournament_id = null where tournament_id is not null;

-- Elimina asignaciones de tournament_organizer que apuntaban a
-- torneos de prueba (ej. Pedro Pérez) — el torneo al que
-- apuntaban va a dejar de existir.
delete from admin_role_assignments where tournament_id is not null;

delete from tournaments;

-- ---------------------------------------------------------
-- 2) SEMBRAR tournament_formats con las modalidades que ya
--    existían como opciones fijas (mismo alcance, ahora en
--    catálogo editable). Ajusta scoring_engine de 'A Gogo' si
--    no corresponde exactamente al motor que planeas usar.
-- ---------------------------------------------------------

insert into tournament_formats (code, name, tipo_participacion, scoring_engine, display_order) values
  ('STROKE_PLAY',       'Stroke Play',              'individual', 'stroke',     1),
  ('STABLEFORD_IND',    'Stableford',               'individual', 'stableford', 2),
  ('A_GOGO',            'A Gogo',                   'equipo',     'team_stroke',3),
  ('STABLEFORD_EQUIPO', 'Stableford por Equipo',    'equipo',     'stableford', 4),
  ('BEST_BALL',         'Best Ball',                'equipo',     'best_ball',  5);

-- ---------------------------------------------------------
-- 3) MIGRAR tournaments
-- ---------------------------------------------------------

alter table tournaments
  add column tournament_format_id uuid references tournament_formats (id) on delete restrict;

-- Como ya no quedan torneos (se limpiaron en el paso 1), es
-- seguro volverla NOT NULL directamente.
alter table tournaments
  alter column tournament_format_id set not null;

-- Quitar el trigger y función viejos de consistencia
-- formato/modalidad — ya no aplican con el nuevo diseño.
drop trigger if exists trg_validar_formato_modalidad_torneo on tournaments;
drop function if exists validar_formato_modalidad_torneo();

alter table tournaments drop column formato_juego;
alter table tournaments drop column modalidad_individual;
alter table tournaments drop column modalidad_equipo;

-- jugadores_por_equipo SE QUEDA — es una elección propia de
-- cada torneo (mismo formato "A Gogo" puede jugarse en equipos
-- de 2 o de 4 según el torneo), no del catálogo de modalidades.
-- Se reemplaza la validación para que consulte la categoría
-- del formato vía tournament_format_id, en vez del enum viejo.

create or replace function validar_jugadores_por_equipo()
returns trigger as $$
declare
  v_categoria formato_juego_torneo;
begin
  select tipo_participacion into v_categoria from tournament_formats where id = new.tournament_format_id;

  if v_categoria = 'individual' and new.jugadores_por_equipo is not null then
    raise exception 'jugadores_por_equipo debe quedar vacío cuando la modalidad es individual.';
  elsif v_categoria = 'equipo' and new.jugadores_por_equipo is null then
    raise exception 'Debes especificar jugadores_por_equipo cuando la modalidad es de equipo.';
  end if;

  return new;
end;
$$ language plpgsql;

create trigger trg_validar_jugadores_por_equipo
before insert or update on tournaments
for each row execute function validar_jugadores_por_equipo();

comment on column tournaments.tournament_format_id is 'Referencia al catálogo tournament_formats. Reemplaza a los antiguos enums formato_juego/modalidad_individual/modalidad_equipo.';
