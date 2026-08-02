-- =========================================================
-- MIGRACIÓN 082
-- Bucket público de Storage para logos de torneo (a diferencia
-- de constancias-fiscales, este SÍ es público — un logo está
-- pensado para verse, no para ocultarse).
-- Convención de ruta: {tournament_id}/{archivo}
-- =========================================================

alter table tournaments
  add column logo_url text;

comment on column tournaments.logo_url is 'Ruta del logo del torneo en el bucket público logos-torneos. NULL = sin logo cargado.';

insert into storage.buckets (id, name, public)
values ('logos-torneos', 'logos-torneos', true)
on conflict (id) do nothing;

create policy "logos_torneos_insert"
on storage.objects
for insert to authenticated
with check (
  bucket_id = 'logos-torneos'
  and (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), ((storage.foldername(name))[1])::uuid)
    or exists (
      select 1 from tournaments t
       where t.id = ((storage.foldername(name))[1])::uuid
         and is_club_admin(auth.uid(), t.club_id)
    )
  )
);

create policy "logos_torneos_update"
on storage.objects
for update to authenticated
using (
  bucket_id = 'logos-torneos'
  and (
    is_superadmin(auth.uid())
    or is_tournament_organizer(auth.uid(), ((storage.foldername(name))[1])::uuid)
    or exists (
      select 1 from tournaments t
       where t.id = ((storage.foldername(name))[1])::uuid
         and is_club_admin(auth.uid(), t.club_id)
    )
  )
);

create policy "logos_torneos_select"
on storage.objects
for select to public
using (bucket_id = 'logos-torneos');

comment on policy "logos_torneos_insert" on storage.objects is 'Solo superadmin, organizador del torneo, o club_admin del club sede pueden subir el logo — dentro de la carpeta {tournament_id}/ correspondiente.';
