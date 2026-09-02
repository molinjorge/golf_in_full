-- TEE CENTRAL / GOLF IN FULL
-- Migración 220
-- Corrección: configurar_clasificacion_categoria_torneo debe guardar admin_users.id
-- en tournament_category_classifications.created_by, no auth.uid().
--
-- IMPORTANTE: ejecutar manualmente en Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION public.configurar_clasificacion_categoria_torneo(
    p_tournament_category_id uuid,
    p_classification_mode text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_user_id uuid;
    v_admin_user_id uuid;
    v_tournament_id uuid;
    v_club_id uuid;
    v_category_name text;
    v_mode text;
    v_allowed boolean := false;
BEGIN
    v_user_id := auth.uid();

    IF v_user_id IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
    END IF;

    v_mode := upper(trim(COALESCE(p_classification_mode, '')));

    IF v_mode NOT IN ('GROSS', 'NET', 'BOTH') THEN
        RAISE EXCEPTION
            'Clasificación inválida. Usa GROSS, NET o BOTH.'
            USING ERRCODE='22023';
    END IF;

    SELECT tc.tournament_id, t.club_id, c.nombre
      INTO v_tournament_id, v_club_id, v_category_name
      FROM public.tournament_categories tc
      JOIN public.tournaments t
        ON t.id = tc.tournament_id
      JOIN public.categories c
        ON c.id = tc.category_id
     WHERE tc.id = p_tournament_category_id;

    IF v_tournament_id IS NULL THEN
        RAISE EXCEPTION 'La categoría de torneo indicada no existe.'
            USING ERRCODE='P0002';
    END IF;

    v_allowed :=
           public.is_superadmin(v_user_id)
        OR public.is_tournament_organizer(v_user_id, v_tournament_id)
        OR public.is_club_admin(v_user_id, v_club_id);

    IF NOT v_allowed THEN
        RAISE EXCEPTION 'No tienes permisos para modificar esta configuración.'
            USING ERRCODE='42501';
    END IF;

    -- created_by referencia public.admin_users(id), no auth.users(id).
    SELECT au.id
      INTO v_admin_user_id
      FROM public.admin_users au
     WHERE au.auth_user_id = v_user_id
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_user_id IS NULL THEN
        RAISE EXCEPTION
            'No fue posible resolver el admin_user asociado al usuario autenticado.'
            USING ERRCODE='42501';
    END IF;

    -- Bloqueo explícito. Además se conserva el trigger existente de protección
    -- sobre tournament_category_classifications como defensa adicional.
    IF EXISTS (
        SELECT 1
          FROM public.tournament_condition_freezes f
         WHERE f.tournament_id = v_tournament_id
    ) THEN
        RAISE EXCEPTION
            'No se puede modificar la clasificación porque las condiciones del torneo ya fueron congeladas.'
            USING ERRCODE='55000';
    END IF;

    DELETE FROM public.tournament_category_classifications cc
     WHERE cc.tournament_id = v_tournament_id
       AND cc.tournament_category_id = p_tournament_category_id;

    IF v_mode IN ('GROSS', 'BOTH') THEN
        INSERT INTO public.tournament_category_classifications(
            tournament_id,
            tournament_category_id,
            tipo_resultado,
            created_by
        )
        VALUES (
            v_tournament_id,
            p_tournament_category_id,
            'gross'::public.tipo_resultado_desempate,
            v_admin_user_id
        );
    END IF;

    IF v_mode IN ('NET', 'BOTH') THEN
        INSERT INTO public.tournament_category_classifications(
            tournament_id,
            tournament_category_id,
            tipo_resultado,
            created_by
        )
        VALUES (
            v_tournament_id,
            p_tournament_category_id,
            'neto'::public.tipo_resultado_desempate,
            v_admin_user_id
        );
    END IF;

    RETURN jsonb_build_object(
        'schemaVersion', 1,
        'tournamentId', v_tournament_id,
        'tournamentCategoryId', p_tournament_category_id,
        'categoryName', v_category_name,
        'classificationMode', v_mode,
        'resultTypes',
            CASE v_mode
                WHEN 'GROSS' THEN jsonb_build_array('gross')
                WHEN 'NET' THEN jsonb_build_array('neto')
                ELSE jsonb_build_array('gross', 'neto')
            END,
        'configured', true
    );
END;
$function$;

COMMIT;
