-- =========================================================
-- MIGRACIÓN 077
-- Catálogo de secuencias de desempate CON NOMBRE — el organizador
-- elige una plantilla en vez de armar la cadena a mano cada vez.
-- Reutiliza tiebreak_methods y tournament_tiebreak_rules (031),
-- que ya soportaban cadenas — solo faltaba esta capa de
-- plantillas reconocidas.
-- =========================================================

insert into tiebreak_methods (code, name, description, display_order) values
  ('HOYO_POR_HOYO_HANDICAP', 'Hoyo por hoyo (por hándicap)', 'Compara hoyo por hoyo empezando en el de hándicap 1, avanzando al 2, 3... hasta romper el empate.', 8);

create table secuencias_desempate (
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

comment on table secuencias_desempate is 'Plantillas con nombre de secuencias de desempate reconocidas (R&A Oficial, Mexicano por Hándicap, etc.) — se aplican de un clic a un torneo en vez de armar la cadena a mano.';

create trigger trg_secuencias_desempate_updated_at
before update on secuencias_desempate
for each row execute function set_updated_at();

create trigger trg_track_estatus_secuencias_desempate
before update on secuencias_desempate
for each row execute function track_estatus_activo();

create table secuencia_desempate_pasos (
  id                 uuid        primary key default gen_random_uuid(),
  secuencia_id       uuid        not null references secuencias_desempate (id) on delete restrict,
  orden              integer     not null,
  tiebreak_method_id uuid        not null references tiebreak_methods (id) on delete restrict,

  constraint secuencia_desempate_pasos_unico unique (secuencia_id, orden)
);

comment on table secuencia_desempate_pasos is 'Pasos que componen cada plantilla de secuencia de desempate, en orden.';

insert into secuencias_desempate (code, name, description) values
  ('RA_OFICIAL', 'R&A Oficial (Countback)', 'Últimos 9 hoyos → últimos 6 → últimos 3 → último hoyo. Procedimiento recomendado por el R&A/USGA.'),
  ('MEXICO_HANDICAP', 'Mexicano por Hándicap de Hoyo', 'Countback estándar (9/6/3/último hoyo) y, si el empate persiste, hoyo por hoyo por hándicap — método común en México.');

insert into secuencia_desempate_pasos (secuencia_id, orden, tiebreak_method_id)
select s.id, v.orden, tm.id
  from secuencias_desempate s
  join (values
    (1, 'TARJETA_ULTIMOS_9'),
    (2, 'TARJETA_ULTIMOS_6'),
    (3, 'TARJETA_ULTIMOS_3'),
    (4, 'TARJETA_ULTIMO_HOYO')
  ) as v(orden, code) on true
  join tiebreak_methods tm on tm.code = v.code
 where s.code = 'RA_OFICIAL';

insert into secuencia_desempate_pasos (secuencia_id, orden, tiebreak_method_id)
select s.id, v.orden, tm.id
  from secuencias_desempate s
  join (values
    (1, 'TARJETA_ULTIMOS_9'),
    (2, 'TARJETA_ULTIMOS_6'),
    (3, 'TARJETA_ULTIMOS_3'),
    (4, 'TARJETA_ULTIMO_HOYO'),
    (5, 'HOYO_POR_HOYO_HANDICAP')
  ) as v(orden, code) on true
  join tiebreak_methods tm on tm.code = v.code
 where s.code = 'MEXICO_HANDICAP';

create or replace function aplicar_secuencia_desempate(
  p_tournament_id uuid,
  p_alcance       alcance_desempate,
  p_secuencia_id  uuid
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
     and activo = true;

  insert into tournament_tiebreak_rules (tournament_id, alcance, orden, tiebreak_method_id)
  select p_tournament_id, p_alcance, sp.orden, sp.tiebreak_method_id
    from secuencia_desempate_pasos sp
   where sp.secuencia_id = p_secuencia_id
   order by sp.orden;
end;
$$;

comment on function aplicar_secuencia_desempate is 'Aplica una plantilla de secuencia de desempate a un torneo/alcance de un clic — desactiva la secuencia previa (si había) y crea los pasos de la plantilla elegida.';

grant execute on function aplicar_secuencia_desempate(uuid, alcance_desempate, uuid) to authenticated;

alter table secuencias_desempate enable row level security;
alter table secuencia_desempate_pasos enable row level security;

create policy secuencias_desempate_select on secuencias_desempate
  for select to public using (activo = true or is_superadmin(auth.uid()));
create policy secuencias_desempate_write on secuencias_desempate
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

create policy secuencia_desempate_pasos_select on secuencia_desempate_pasos
  for select to public using (true);
create policy secuencia_desempate_pasos_write on secuencia_desempate_pasos
  for all to authenticated using (is_superadmin(auth.uid())) with check (is_superadmin(auth.uid()));

grant select on secuencias_desempate, secuencia_desempate_pasos to anon;
grant select, insert, update, delete on secuencias_desempate, secuencia_desempate_pasos to authenticated;
