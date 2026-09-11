-- ============================================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 296
-- Autorregistro backend de organizador con correo previamente verificado
--
-- Objetivo:
--   Permitir que una persona cree su perfil administrativo de organizador
--   SIN intervención del Superadmin, después de verificar su correo mediante
--   Supabase Auth (OTP/código).
--
-- Flujo previsto:
--   1. Frontend solicita OTP/código al correo mediante Supabase Auth.
--   2. Usuario captura/verifica el código.
--   3. Ya autenticado, frontend llama esta RPC con nombres/apellidos/teléfono.
--   4. La RPC verifica auth.users.email_confirmed_at.
--   5. Crea o vincula public.admin_users.
--
-- Importante:
--   - NO crea asignaciones en admin_role_assignments.
--   - NO asigna tournament_organizer global.
--   - La autorización sobre un torneo se crea posteriormente, cuando una
--     contratación pagada genera el torneo (Migración 292).
-- ============================================================================

begin;

create or replace function public.completar_autoregistro_organizador_296(
    p_nombres text,
    p_apellidos text,
    p_telefono text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public, auth, pg_temp
as $function$
declare
    v_auth_uid uuid;
    v_auth_email text;
    v_confirmed_at timestamptz;

    v_admin_id uuid;
    v_existing_auth_user_id uuid;
    v_activo boolean;

    v_nombres text;
    v_apellidos text;
    v_telefono text;
begin
    v_auth_uid := auth.uid();

    if v_auth_uid is null then
        raise exception 'No autenticado.'
            using errcode = '42501';
    end if;

    select
        lower(btrim(u.email)),
        u.email_confirmed_at
      into
        v_auth_email,
        v_confirmed_at
      from auth.users u
     where u.id = v_auth_uid;

    if v_auth_email is null then
        raise exception
            'No se pudo determinar el correo del usuario autenticado.'
            using errcode = '42501';
    end if;

    if v_confirmed_at is null then
        raise exception
            'Debes verificar tu correo electrónico antes de crear tu cuenta de organizador.'
            using errcode = '42501';
    end if;

    v_nombres := nullif(btrim(coalesce(p_nombres, '')), '');
    v_apellidos := nullif(btrim(coalesce(p_apellidos, '')), '');
    v_telefono := nullif(btrim(coalesce(p_telefono, '')), '');

    if v_nombres is null then
        raise exception 'Debes indicar tu nombre.'
            using errcode = '22023';
    end if;

    if v_apellidos is null then
        raise exception 'Debes indicar tus apellidos.'
            using errcode = '22023';
    end if;

    -- Serializa posibles altas concurrentes del mismo correo.
    perform pg_advisory_xact_lock(
        hashtextextended('organizer-email:' || v_auth_email, 296)
    );

    -- Primero buscar por auth_user_id.
    select
        au.id,
        au.auth_user_id,
        au.activo
      into
        v_admin_id,
        v_existing_auth_user_id,
        v_activo
      from public.admin_users au
     where au.auth_user_id = v_auth_uid
     limit 1
     for update;

    -- Si aún no está vinculado por auth, buscar por correo.
    if v_admin_id is null then
        select
            au.id,
            au.auth_user_id,
            au.activo
          into
            v_admin_id,
            v_existing_auth_user_id,
            v_activo
          from public.admin_users au
         where lower(btrim(au.email::text)) = v_auth_email
         limit 1
         for update;
    end if;

    if v_admin_id is null then

        insert into public.admin_users (
            auth_user_id,
            email,
            nombres,
            apellidos,
            telefono,
            activo
        )
        values (
            v_auth_uid,
            v_auth_email,
            v_nombres,
            v_apellidos,
            v_telefono,
            true
        )
        returning id into v_admin_id;

    else

        if coalesce(v_activo, false) = false then
            raise exception
                'Existe una cuenta administrativa inactiva asociada a este correo.'
                using errcode = '55000';
        end if;

        if v_existing_auth_user_id is not null
           and v_existing_auth_user_id is distinct from v_auth_uid
        then
            raise exception
                'Este correo ya está vinculado a otra identidad de acceso.'
                using errcode = '23505';
        end if;

        update public.admin_users
           set auth_user_id = v_auth_uid,
               email = v_auth_email,
               nombres = v_nombres,
               apellidos = v_apellidos,
               telefono = coalesce(v_telefono, telefono)
         where id = v_admin_id;
    end if;

    return jsonb_build_object(
        'ok', true,
        'adminUserId', v_admin_id,
        'authUserId', v_auth_uid,
        'email', v_auth_email,
        'emailVerified', true,
        'nombres', v_nombres,
        'apellidos', v_apellidos,
        'telefono',
            (
                select au.telefono
                  from public.admin_users au
                 where au.id = v_admin_id
            ),
        'active', true,
        'tournamentAssignmentCreated', false,
        'readyToContract', true
    );
end;
$function$;

revoke all on function public.completar_autoregistro_organizador_296(
    text, text, text
) from public, anon;

grant execute on function public.completar_autoregistro_organizador_296(
    text, text, text
) to authenticated, service_role;

commit;
