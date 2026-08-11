-- ============================================================
-- 133_optimizar_rls_shotgun_holes.sql
-- GOLF IN FULL
--
-- OBJETIVO
-- Optimizar las políticas RLS de:
--   public.tournament_shotgun_category_holes
--
-- PROBLEMA CONFIRMADO
-- Un UPDATE simple de salida_doble:
--   - sin simular authenticated/RLS: ~5 ms
--   - simulando authenticated/RLS: ~2.6 s
--   - desde PostgREST/frontend: puede alcanzar statement timeout
--
-- SOLUCIÓN
-- Crear helpers SECURITY DEFINER para evitar expansión de RLS
-- a través de tablas intermedias protegidas.
--
-- ALCANCE
-- SOLO modifica RLS de tournament_shotgun_category_holes.
-- NO modifica datos, triggers, auditoría ni policies de otras tablas.
-- ============================================================

begin;

create or replace function public.can_view_tournament_shotgun_config(
    p_auth_uid uuid,
    p_config_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
    select
        (
            p_auth_uid is not null
            and exists (
                select 1
                from public.admin_users au
                join public.admin_role_assignments ara
                  on ara.admin_user_id = au.id
                join public.roles r
                  on r.id = ara.role_id
                where au.auth_user_id = p_auth_uid
                  and au.activo = true
                  and ara.activo = true
                  and r.codigo = 'superadmin'
            )
        )
        or
        exists (
            select 1
            from public.tournament_shotgun_category_configs cfg
            join public.tournament_round_shift_categories sc
              on sc.id = cfg.tournament_round_shift_category_id
            join public.tournament_round_shifts trs
              on trs.id = sc.tournament_round_shift_id
            join public.tournament_rounds tr
              on tr.id = trs.tournament_round_id
            where cfg.id = p_config_id
              and cfg.activo = true
              and sc.activo = true
              and trs.activo = true
              and tr.activo = true
        );
$function$;

comment on function public.can_view_tournament_shotgun_config(uuid, uuid) is
'Helper SECURITY DEFINER para RLS de tournament_shotgun_category_holes. Permite lectura a superadmin o cuando la cadena Shotgun config/categoria-turno/turno/ronda está activa, evitando expansión recursiva de RLS.';

create or replace function public.can_manage_tournament_shotgun_config(
    p_auth_uid uuid,
    p_config_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $function$
    select
        case
            when p_auth_uid is null then false
            when exists (
                select 1
                from public.admin_users au
                join public.admin_role_assignments ara
                  on ara.admin_user_id = au.id
                join public.roles r
                  on r.id = ara.role_id
                where au.auth_user_id = p_auth_uid
                  and au.activo = true
                  and ara.activo = true
                  and r.codigo = 'superadmin'
            )
            then true
            else exists (
                select 1
                from public.tournament_shotgun_category_configs cfg
                join public.tournament_round_shift_categories sc
                  on sc.id = cfg.tournament_round_shift_category_id
                join public.tournament_round_shifts trs
                  on trs.id = sc.tournament_round_shift_id
                join public.tournament_rounds tr
                  on tr.id = trs.tournament_round_id
                join public.tournaments t
                  on t.id = tr.tournament_id
                where cfg.id = p_config_id
                  and (
                        exists (
                            select 1
                            from public.admin_users au
                            join public.admin_role_assignments ara
                              on ara.admin_user_id = au.id
                            join public.roles r
                              on r.id = ara.role_id
                            where au.auth_user_id = p_auth_uid
                              and au.activo = true
                              and ara.activo = true
                              and r.codigo = 'tournament_organizer'
                              and ara.tournament_id = t.id
                        )
                        or
                        exists (
                            select 1
                            from public.admin_users au
                            join public.admin_role_assignments ara
                              on ara.admin_user_id = au.id
                            join public.roles r
                              on r.id = ara.role_id
                            where au.auth_user_id = p_auth_uid
                              and au.activo = true
                              and ara.activo = true
                              and r.codigo = 'club_admin'
                              and ara.club_id = t.club_id
                        )
                  )
            );
$function$;

comment on function public.can_manage_tournament_shotgun_config(uuid, uuid) is
'Helper SECURITY DEFINER para RLS de escritura de tournament_shotgun_category_holes. Autoriza superadmin, tournament_organizer del torneo o club_admin del club sin expandir RLS de tablas intermedias.';

revoke all on function public.can_view_tournament_shotgun_config(uuid, uuid) from public;
grant execute on function public.can_view_tournament_shotgun_config(uuid, uuid) to anon, authenticated;

revoke all on function public.can_manage_tournament_shotgun_config(uuid, uuid) from public;
grant execute on function public.can_manage_tournament_shotgun_config(uuid, uuid) to authenticated;

drop policy if exists tournament_shotgun_category_holes_select
on public.tournament_shotgun_category_holes;

create policy tournament_shotgun_category_holes_select
on public.tournament_shotgun_category_holes
for select
to public
using (
    public.can_view_tournament_shotgun_config(
        auth.uid(),
        tournament_shotgun_category_config_id
    )
);

drop policy if exists tournament_shotgun_category_holes_write
on public.tournament_shotgun_category_holes;

create policy tournament_shotgun_category_holes_write
on public.tournament_shotgun_category_holes
for all
to authenticated
using (
    public.can_manage_tournament_shotgun_config(
        auth.uid(),
        tournament_shotgun_category_config_id
    )
)
with check (
    public.can_manage_tournament_shotgun_config(
        auth.uid(),
        tournament_shotgun_category_config_id
    )
);

commit;
