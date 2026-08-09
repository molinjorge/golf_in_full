-- 116_bucket_constancias_fiscales_patrocinadores.sql
--
-- Bucket faltante para patrocinadores.constancia_fiscal_storage_path (115) — mismo
-- olvido que tuvimos con comprobantes-transferencia antes de la 109, corregido ahora
-- desde el inicio. Bucket nuevo y separado del de jugadores (constancias-fiscales, 061),
-- porque el criterio de acceso es distinto: aquí solo roles administrativos del torneo,
-- no el propio dueño del documento (el patrocinador no tiene cuenta en la plataforma).
--
-- Convención de ruta obligatoria (de la que dependen las políticas):
--   '{tournament_id}/{patrocinador_id}/{nombre_archivo}'

insert into storage.buckets (id, name, public)
values ('constancias-fiscales-patrocinadores', 'constancias-fiscales-patrocinadores', false)
on conflict (id) do nothing;

create policy constancias_fiscales_patrocinadores_select
  on storage.objects
  for select
  using (
    bucket_id = 'constancias-fiscales-patrocinadores'
    and (
      is_superadmin(auth.uid())
      or is_tournament_organizer(auth.uid(), (split_part(name, '/', 1))::uuid)
      or is_club_admin(auth.uid(), (select club_id from tournaments where id = (split_part(name, '/', 1))::uuid))
    )
  );

create policy constancias_fiscales_patrocinadores_insert
  on storage.objects
  for insert
  with check (
    bucket_id = 'constancias-fiscales-patrocinadores'
    and (
      is_superadmin(auth.uid())
      or is_tournament_organizer(auth.uid(), (split_part(name, '/', 1))::uuid)
      or is_club_admin(auth.uid(), (select club_id from tournaments where id = (split_part(name, '/', 1))::uuid))
    )
  );
