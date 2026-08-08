-- 115_patrocinadores.sql
--
-- Nuevo módulo: patrocinadores para torneos de beneficencia (solo tournaments.es_beneficencia
-- = true, confirmado con el organizador). Diseñado en conjunto tras analizar el documento
-- "PATROCINADORES" y varias rondas de preguntas/confirmación.
--
-- Decisiones de diseño confirmadas:
--   1. Catálogo de "derechos" es GLOBAL y compartido entre organizadores/torneos — crece
--      con el tiempo según lo que cada organizador vaya necesitando, no es fijo por torneo.
--      La mayoría son sí/no (existe la fila = sí); algunos llevan "cantidad" (ej. jugadores
--      cortesía, comida de premiación). Es solo informativo/ayuda de memoria para el
--      organizador — no bloquea ni valida nada automáticamente.
--   2. Categorías de patrocinador SÍ son por torneo (no todos ofrecen lo mismo).
--   3. Un patrocinador puede tener varios tipos de apoyo a la vez (dinero Y premios).
--   4. Jugadores cortesía: el organizador los precarga en `players` (mismo mecanismo ya
--      existente, patrón Noriega) Y los vincula al patrocinador en el mismo paso.
--   5. NO se toca el enum medio_pago_torneo — agregar un valor tipo "cortesía" ahí
--      arriesgaba filtrarse al selector de pago que ve el jugador en la PWA. En vez de
--      eso: monto_pagado = 0, medio_pago = 'efectivo' (placeholder), y el campo nuevo
--      origen_inscripcion distingue de verdad el caso.
--   6. Jugadores cortesía SÍ cuentan hacia tournaments.cupo_maximo — se resuelve solo,
--      porque usan el mismo INSERT normal en tournament_registrations (mismo trigger 104).
--   7. Inscripción automática: en cuanto el perfil del jugador queda completo (mismo
--      criterio que ya usa validar_perfil_completo_para_inscripcion: fecha_nacimiento y
--      telefono_pais no nulos), si tiene un vínculo de cortesía sin convertir, se inscribe
--      automáticamente — sin pasar por pago, porque ya se sabe que no debe pagar.

-- 1. Catálogo de tipos de apoyo (dinero, comida en campo, premios, premios para rifa...).
create table tipos_apoyo_patrocinio (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  activo boolean not null default true,
  created_at timestamptz not null default now()
);

-- 2. Catálogo de derechos — GLOBAL, compartido, crece con el tiempo.
create table derechos_patrocinador (
  id uuid primary key default gen_random_uuid(),
  nombre text not null unique,
  descripcion text,
  activo boolean not null default true,
  created_by uuid references admin_users(id),
  created_at timestamptz not null default now()
);

-- 3. Categorías/niveles de patrocinador — por torneo.
create table categorias_patrocinador (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references tournaments(id),
  nombre text not null,
  descripcion text,
  valoracion_estimada numeric(12,2),
  activo boolean not null default true,
  fecha_baja timestamptz,
  dado_de_baja_por uuid,
  motivo_baja text,
  created_by uuid references admin_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_categorias_patrocinador_updated_at
  before update on categorias_patrocinador
  for each row
  execute function set_updated_at();

-- 4. Tipos de apoyo de cada categoría (M:N — puede tener dinero Y premios).
create table categoria_patrocinador_tipos_apoyo (
  categoria_patrocinador_id uuid not null references categorias_patrocinador(id),
  tipo_apoyo_id uuid not null references tipos_apoyo_patrocinio(id),
  primary key (categoria_patrocinador_id, tipo_apoyo_id)
);

-- 5. Derechos asignados a cada categoría (M:N, con cantidad opcional).
create table categoria_patrocinador_derechos (
  categoria_patrocinador_id uuid not null references categorias_patrocinador(id),
  derecho_id uuid not null references derechos_patrocinador(id),
  cantidad numeric,
  descripcion text,
  primary key (categoria_patrocinador_id, derecho_id)
);

-- 6. Patrocinadores reales.
create table patrocinadores (
  id uuid primary key default gen_random_uuid(),
  tournament_id uuid not null references tournaments(id),
  nombre text not null,
  nombre_contacto text,
  email text,
  telefono_pais text,
  telefono_lada text,
  telefono_numero text,
  logo_url text,
  categoria_patrocinador_id uuid references categorias_patrocinador(id),
  requiere_recibo_deducible boolean not null default false,
  constancia_fiscal_storage_path text,
  recibo_enviado boolean not null default false,
  activo boolean not null default true,
  fecha_baja timestamptz,
  dado_de_baja_por uuid,
  motivo_baja text,
  created_by uuid references admin_users(id),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create trigger trg_patrocinadores_updated_at
  before update on patrocinadores
  for each row
  execute function set_updated_at();

-- 7. Jugadores cortesía vinculados al patrocinador — precarga en players + vínculo,
--    en el mismo paso del organizador.
create table patrocinador_jugadores_cortesia (
  id uuid primary key default gen_random_uuid(),
  patrocinador_id uuid not null references patrocinadores(id),
  player_id uuid not null references players(id),
  tournament_team_id uuid references tournament_teams(id),
  tournament_category_id uuid references tournament_categories(id),
  tournament_registration_id uuid references tournament_registrations(id),
  created_by uuid references admin_users(id),
  created_at timestamptz not null default now()
);

-- 8. Nuevas columnas en tournament_registrations: origen y patrocinador (si aplica).
create type origen_inscripcion_torneo as enum ('normal', 'cortesia_patrocinador');

alter table tournament_registrations
  add column origen_inscripcion origen_inscripcion_torneo not null default 'normal',
  add column patrocinador_id uuid references patrocinadores(id);

-- 9. Función: inscribe a un jugador cortesía — mismo INSERT normal en
--    tournament_registrations, pasa por TODOS los triggers existentes (categoría, marca,
--    cupo) sin duplicar lógica, igual que ya hicimos con transferencias.
create or replace function inscribir_cortesia_patrocinador(p_cortesia_id uuid)
returns uuid
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_cortesia         patrocinador_jugadores_cortesia;
  v_tournament_id    uuid;
  v_registration_id  uuid;
begin
  select * into v_cortesia from patrocinador_jugadores_cortesia where id = p_cortesia_id;

  if v_cortesia.id is null then
    raise exception 'Vínculo de cortesía no encontrado.';
  end if;

  if v_cortesia.tournament_registration_id is not null then
    raise exception 'Este jugador cortesía ya fue inscrito anteriormente.';
  end if;

  select tournament_id into v_tournament_id
    from patrocinadores where id = v_cortesia.patrocinador_id;

  insert into tournament_registrations (
    tournament_id, player_id, tournament_category_id, tournament_team_id,
    monto_pagado, medio_pago, referencia_pago, origen_inscripcion, patrocinador_id
  ) values (
    v_tournament_id, v_cortesia.player_id, v_cortesia.tournament_category_id, v_cortesia.tournament_team_id,
    0, 'efectivo', 'Cortesía de patrocinador', 'cortesia_patrocinador', v_cortesia.patrocinador_id
  )
  returning id into v_registration_id;

  update patrocinador_jugadores_cortesia
     set tournament_registration_id = v_registration_id
   where id = p_cortesia_id;

  return v_registration_id;
end;
$$;

-- 10. Trigger: al completar el perfil (mismo criterio que
--     validar_perfil_completo_para_inscripcion), inscribe automáticamente cualquier
--     vínculo de cortesía pendiente de ese jugador.
create or replace function auto_inscribir_cortesia_al_completar_perfil()
returns trigger
language plpgsql
security definer
set search_path to 'public'
as $$
declare
  v_completo_antes boolean;
  v_completo_ahora boolean;
  v_cortesia       record;
begin
  v_completo_antes := old.fecha_nacimiento is not null and old.telefono_pais is not null;
  v_completo_ahora := new.fecha_nacimiento is not null and new.telefono_pais is not null;

  if v_completo_ahora and not v_completo_antes then
    for v_cortesia in
      select id from patrocinador_jugadores_cortesia
       where player_id = new.id and tournament_registration_id is null
    loop
      perform inscribir_cortesia_patrocinador(v_cortesia.id);
    end loop;
  end if;

  return new;
end;
$$;

create trigger trg_auto_inscribir_cortesia_al_completar_perfil
  after update on players
  for each row
  execute function auto_inscribir_cortesia_al_completar_perfil();

-- 11. RLS — sin esto, las tablas quedan inaccesibles o completamente abiertas (mismo
--     olvido que tuvimos con tournament_groups en la 107, corregido después en 108).

alter table tipos_apoyo_patrocinio enable row level security;
alter table derechos_patrocinador enable row level security;
alter table categorias_patrocinador enable row level security;
alter table categoria_patrocinador_tipos_apoyo enable row level security;
alter table categoria_patrocinador_derechos enable row level security;
alter table patrocinadores enable row level security;
alter table patrocinador_jugadores_cortesia enable row level security;

-- Catálogos GLOBALES (tipos de apoyo, derechos): lectura pública, escritura para
-- cualquier admin activo (crecen con el uso de cualquier organizador, según lo pedido).
create policy tipos_apoyo_patrocinio_select on tipos_apoyo_patrocinio for select using (true);
create policy tipos_apoyo_patrocinio_write on tipos_apoyo_patrocinio for all
  using (is_active_admin(auth.uid())) with check (is_active_admin(auth.uid()));

create policy derechos_patrocinador_select on derechos_patrocinador for select using (true);
create policy derechos_patrocinador_write on derechos_patrocinador for all
  using (is_active_admin(auth.uid())) with check (is_active_admin(auth.uid()));

-- Categorías de patrocinador: lectura pública (info del torneo), escritura restringida
-- al organizador/club_admin/superadmin de ESE torneo específico.
create policy categorias_patrocinador_select on categorias_patrocinador for select using (true);
create policy categorias_patrocinador_write on categorias_patrocinador for all
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = categorias_patrocinador.tournament_id and is_club_admin(auth.uid(), t.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = categorias_patrocinador.tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

-- Tablas de unión de categoría: mismo criterio, resuelto vía la categoría → torneo.
create policy categoria_patrocinador_tipos_apoyo_select on categoria_patrocinador_tipos_apoyo for select using (true);
create policy categoria_patrocinador_tipos_apoyo_write on categoria_patrocinador_tipos_apoyo for all
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from categorias_patrocinador cp
       where cp.id = categoria_patrocinador_tipos_apoyo.categoria_patrocinador_id
         and (is_tournament_organizer(auth.uid(), cp.tournament_id)
              or exists (select 1 from tournaments t where t.id = cp.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from categorias_patrocinador cp
       where cp.id = categoria_patrocinador_tipos_apoyo.categoria_patrocinador_id
         and (is_tournament_organizer(auth.uid(), cp.tournament_id)
              or exists (select 1 from tournaments t where t.id = cp.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  );

create policy categoria_patrocinador_derechos_select on categoria_patrocinador_derechos for select using (true);
create policy categoria_patrocinador_derechos_write on categoria_patrocinador_derechos for all
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from categorias_patrocinador cp
       where cp.id = categoria_patrocinador_derechos.categoria_patrocinador_id
         and (is_tournament_organizer(auth.uid(), cp.tournament_id)
              or exists (select 1 from tournaments t where t.id = cp.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from categorias_patrocinador cp
       where cp.id = categoria_patrocinador_derechos.categoria_patrocinador_id
         and (is_tournament_organizer(auth.uid(), cp.tournament_id)
              or exists (select 1 from tournaments t where t.id = cp.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  );

-- Patrocinadores: contiene datos de contacto y fiscales — NO es público, solo roles
-- administrativos del torneo correspondiente.
create policy patrocinadores_select on patrocinadores for select
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = patrocinadores.tournament_id and is_club_admin(auth.uid(), t.club_id))
  );
create policy patrocinadores_write on patrocinadores for all
  using (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = patrocinadores.tournament_id and is_club_admin(auth.uid(), t.club_id))
  )
  with check (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), tournament_id)
    or exists (select 1 from tournaments t where t.id = patrocinadores.tournament_id and is_club_admin(auth.uid(), t.club_id))
  );

-- Jugadores cortesía: mismo criterio administrativo, resuelto vía el patrocinador → torneo.
create policy patrocinador_jugadores_cortesia_select on patrocinador_jugadores_cortesia for select
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from patrocinadores p
       where p.id = patrocinador_jugadores_cortesia.patrocinador_id
         and (is_tournament_organizer(auth.uid(), p.tournament_id)
              or exists (select 1 from tournaments t where t.id = p.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  );
create policy patrocinador_jugadores_cortesia_write on patrocinador_jugadores_cortesia for all
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from patrocinadores p
       where p.id = patrocinador_jugadores_cortesia.patrocinador_id
         and (is_tournament_organizer(auth.uid(), p.tournament_id)
              or exists (select 1 from tournaments t where t.id = p.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from patrocinadores p
       where p.id = patrocinador_jugadores_cortesia.patrocinador_id
         and (is_tournament_organizer(auth.uid(), p.tournament_id)
              or exists (select 1 from tournaments t where t.id = p.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  );
