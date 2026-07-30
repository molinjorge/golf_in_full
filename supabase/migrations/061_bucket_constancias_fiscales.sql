-- =========================================================
-- MIGRACIÓN 061
-- Bucket privado de Supabase Storage para las Constancias de
-- Situación Fiscal — la "carpeta" donde viven los PDFs.
-- Convención de ruta esperada: {player_id}/{archivo}.pdf
--
-- Requiere que la migración 060 (payment_fiscal_receipts) ya
-- haya corrido — la política de lectura del organizador de
-- torneo consulta esa tabla para saber si el archivo pertenece
-- a uno de SUS torneos.
-- =========================================================

insert into storage.buckets (id, name, public)
values ('constancias-fiscales', 'constancias-fiscales', false)
on conflict (id) do nothing;

create policy "constancias_fiscales_insert_propio"
on storage.objects
for insert to authenticated
with check (
  bucket_id = 'constancias-fiscales'
  and (storage.foldername(name))[1] in (
    select id::text from players where auth_user_id = auth.uid()
  )
);

create policy "constancias_fiscales_select"
on storage.objects
for select to authenticated
using (
  bucket_id = 'constancias-fiscales'
  and (
    (storage.foldername(name))[1] in (
      select id::text from players where auth_user_id = auth.uid()
    )
    or is_superadmin(auth.uid())
    or is_any_club_admin(auth.uid())
    or exists (
      select 1 from payment_fiscal_receipts pfr
      join payment_attempts pa on pa.id = pfr.payment_attempt_id
      where pfr.constancia_situacion_fiscal_url = name
        and pa.tournament_id is not null
        and is_tournament_organizer(auth.uid(), pa.tournament_id)
    )
  )
);

comment on policy "constancias_fiscales_insert_propio" on storage.objects is 'Un jugador solo puede subir su constancia fiscal dentro de su propia carpeta (player_id).';
