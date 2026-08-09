-- 119_patrocinador_tipos_apoyo_real.sql
--
-- Hueco detectado antes de construir la Fase 4: categoria_patrocinador_tipos_apoyo (115)
-- es solo el "menú" descriptivo de lo que esa categoría típicamente ofrece — pero cada
-- patrocinador real da una combinación específica y propia (ej. dos patrocinadores
-- "Oro" pueden dar cosas distintas entre sí), y hace falta cuantificar cada tipo de
-- apoyo con su propio monto y descripción.
--
-- Ejemplo real que motivó esto: patrocinador "Sushiitto" — $100,000 en dinero +
-- comida en campo equivalente a $15,000, sin usar sus 4 jugadores cortesía.
--
-- El monto se captura en la moneda del torneo (tournaments.moneda, ya existente) — no
-- se duplica el campo de moneda aquí, se hereda implícitamente del torneo.

create table patrocinador_tipos_apoyo (
  id uuid primary key default gen_random_uuid(),
  patrocinador_id uuid not null references patrocinadores(id),
  tipo_apoyo_id uuid not null references tipos_apoyo_patrocinio(id),
  monto numeric(12,2),
  descripcion text,
  created_by uuid references admin_users(id),
  created_at timestamptz not null default now()
);

alter table patrocinador_tipos_apoyo enable row level security;

create policy patrocinador_tipos_apoyo_select on patrocinador_tipos_apoyo for select
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from patrocinadores p
       where p.id = patrocinador_tipos_apoyo.patrocinador_id
         and (is_tournament_organizer(auth.uid(), p.tournament_id)
              or exists (select 1 from tournaments t where t.id = p.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  );

create policy patrocinador_tipos_apoyo_write on patrocinador_tipos_apoyo for all
  using (
    is_superadmin(auth.uid())
    or exists (
      select 1 from patrocinadores p
       where p.id = patrocinador_tipos_apoyo.patrocinador_id
         and (is_tournament_organizer(auth.uid(), p.tournament_id)
              or exists (select 1 from tournaments t where t.id = p.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  )
  with check (
    is_superadmin(auth.uid())
    or exists (
      select 1 from patrocinadores p
       where p.id = patrocinador_tipos_apoyo.patrocinador_id
         and (is_tournament_organizer(auth.uid(), p.tournament_id)
              or exists (select 1 from tournaments t where t.id = p.tournament_id and is_club_admin(auth.uid(), t.club_id)))
    )
  );
