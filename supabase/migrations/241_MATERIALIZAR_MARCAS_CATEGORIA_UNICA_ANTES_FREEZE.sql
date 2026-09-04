-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACIÓN 241
-- Materializar marcas de salida faltantes en categoría única
-- antes del congelamiento.
--
-- Objetivo:
--   - Reutilizar las reglas ya existentes de categoría única:
--       1) Damas -> rojo
--       2) Caballeros senior -> dorado
--       3) Resto -> franja de hándicap
--   - Completar SOLO inscripciones activas con marca_salida_id NULL.
--   - No sobrescribir marcas ya asignadas manualmente.
--   - No operar después del freeze.
--   - No relajar ninguna validación del congelamiento.
-- ============================================================

BEGIN;

CREATE OR REPLACE FUNCTION public.materializar_marcas_salida_categoria_unica_torneo(
    p_tournament_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_temp'
AS $function$
DECLARE
    v_tournament public.tournaments%ROWTYPE;
    v_category_count integer;
    v_band_count integer;
    v_admin_id uuid;
    v_senior_age integer;
    v_reg record;
    v_handicap numeric;
    v_age integer;
    v_standard public.categoria_marca_salida;
    v_tee_id uuid;
    v_tee_name text;
    v_updated integer := 0;
    v_already_assigned integer := 0;
    v_total_active integer := 0;
    v_detail jsonb := '[]'::jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT *
      INTO v_tournament
      FROM public.tournaments
     WHERE id = p_tournament_id
       AND activo = true
     FOR UPDATE;

    IF v_tournament.id IS NULL THEN
        RAISE EXCEPTION 'El torneo no existe o está inactivo.'
            USING ERRCODE = '22023';
    END IF;

    IF NOT public.puede_administrar_congelamiento_torneo(p_tournament_id) THEN
        RAISE EXCEPTION 'No tienes permiso para preparar las marcas de salida de este torneo.'
            USING ERRCODE = '42501';
    END IF;

    IF EXISTS (
        SELECT 1
          FROM public.tournament_condition_freezes f
         WHERE f.tournament_id = p_tournament_id
    ) THEN
        RAISE EXCEPTION
            'El torneo ya está congelado; las marcas de salida no pueden materializarse después del freeze.'
            USING ERRCODE = '55000';
    END IF;

    SELECT count(*)
      INTO v_category_count
      FROM public.tournament_categories tc
     WHERE tc.tournament_id = p_tournament_id;

    IF v_category_count <> 1 THEN
        RAISE EXCEPTION
            'Esta operación sólo aplica a torneos de categoría única. Categorías configuradas: %.',
            v_category_count
            USING ERRCODE = '22023';
    END IF;

    SELECT count(*)
      INTO v_band_count
      FROM public.tournament_franjas_handicap fh
     WHERE fh.tournament_id = p_tournament_id;

    IF v_band_count = 0 THEN
        RAISE EXCEPTION
            'El torneo de categoría única no tiene franjas de hándicap configuradas.'
            USING ERRCODE = '22023';
    END IF;

    SELECT au.id
      INTO v_admin_id
      FROM public.admin_users au
     WHERE au.auth_user_id = auth.uid()
       AND au.activo = true
     ORDER BY au.id
     LIMIT 1;

    IF v_admin_id IS NULL THEN
        RAISE EXCEPTION
            'El usuario autenticado no tiene un administrador activo asociado.'
            USING ERRCODE = '42501';
    END IF;

    SELECT COALESCE(
        v_tournament.edad_senior_categoria_unica,
        (
            SELECT min(c.edad_minima)::integer
              FROM public.categories c
             WHERE c.codigo LIKE 'SENIOR%'
        )
    )
    INTO v_senior_age;

    SELECT count(*)
      INTO v_total_active
      FROM public.tournament_registrations reg
     WHERE reg.tournament_id = p_tournament_id
       AND reg.activo = true;

    SELECT count(*)
      INTO v_already_assigned
      FROM public.tournament_registrations reg
     WHERE reg.tournament_id = p_tournament_id
       AND reg.activo = true
       AND reg.marca_salida_id IS NOT NULL;

    FOR v_reg IN
        SELECT
            reg.id AS registration_id,
            reg.player_id,
            trim(concat_ws(' ', p.nombres, p.apellidos)) AS player_name,
            p.sexo::text AS player_sex,
            p.fecha_nacimiento,
            COALESCE(p.handicap_verificado, p.handicap_declarado) AS handicap_index
        FROM public.tournament_registrations reg
        JOIN public.players p
          ON p.id = reg.player_id
        WHERE reg.tournament_id = p_tournament_id
          AND reg.activo = true
          AND reg.marca_salida_id IS NULL
        ORDER BY reg.created_at, reg.id
        FOR UPDATE OF reg
    LOOP
        v_handicap := v_reg.handicap_index;
        v_standard := NULL;
        v_tee_id := NULL;
        v_tee_name := NULL;

        IF v_reg.player_sex = 'F' THEN
            v_standard := 'rojo'::public.categoria_marca_salida;
        ELSE
            IF v_reg.fecha_nacimiento IS NOT NULL THEN
                v_age := date_part(
                    'year',
                    age(v_tournament.fecha_inicio, v_reg.fecha_nacimiento)
                )::integer;
            ELSE
                v_age := NULL;
            END IF;

            IF v_senior_age IS NOT NULL
               AND v_age IS NOT NULL
               AND v_age >= v_senior_age
            THEN
                v_standard := 'dorado'::public.categoria_marca_salida;
            ELSE
                IF v_handicap IS NULL THEN
                    RAISE EXCEPTION
                        'No se puede resolver la marca de salida de %: no tiene hándicap verificado ni declarado.',
                        v_reg.player_name
                        USING ERRCODE = '22023';
                END IF;

                SELECT fh.categoria_estandar
                  INTO v_standard
                  FROM public.tournament_franjas_handicap fh
                 WHERE fh.tournament_id = p_tournament_id
                   AND fh.handicap_desde <= v_handicap
                   AND (
                        fh.handicap_hasta IS NULL
                        OR v_handicap <= fh.handicap_hasta
                   )
                 ORDER BY fh.handicap_desde DESC, fh.id
                 LIMIT 1;

                IF v_standard IS NULL THEN
                    RAISE EXCEPTION
                        'No se puede resolver la marca de salida de %: su hándicap % no cae en ninguna franja configurada.',
                        v_reg.player_name,
                        v_handicap
                        USING ERRCODE = '22023';
                END IF;
            END IF;
        END IF;

        SELECT ms.id, ms.nombre
          INTO v_tee_id, v_tee_name
          FROM public.marcas_salida ms
         WHERE ms.campo_golf_id = v_tournament.campo_golf_id
           AND ms.categoria_estandar = v_standard
           AND ms.activo = true
         ORDER BY ms.id
         LIMIT 1;

        IF v_tee_id IS NULL THEN
            RAISE EXCEPTION
                'No se puede resolver la marca de salida de %: el campo no tiene una marca activa para la categoría estándar %.',
                v_reg.player_name,
                v_standard::text
                USING ERRCODE = '22023';
        END IF;

        UPDATE public.tournament_registrations
           SET marca_salida_id = v_tee_id
         WHERE id = v_reg.registration_id
           AND marca_salida_id IS NULL;

        IF FOUND THEN
            v_updated := v_updated + 1;

            v_detail := v_detail || jsonb_build_array(
                jsonb_build_object(
                    'registrationId', v_reg.registration_id,
                    'playerId', v_reg.player_id,
                    'playerName', v_reg.player_name,
                    'handicapIndex', v_handicap,
                    'age', v_age,
                    'standardTeeCategory', v_standard::text,
                    'teeId', v_tee_id,
                    'teeName', v_tee_name
                )
            );
        END IF;
    END LOOP;

    RETURN jsonb_build_object(
        'ok', true,
        'tournamentId', p_tournament_id,
        'totalActiveRegistrations', v_total_active,
        'alreadyAssigned', v_already_assigned,
        'materialized', v_updated,
        'remainingMissing', (
            SELECT count(*)
              FROM public.tournament_registrations reg
             WHERE reg.tournament_id = p_tournament_id
               AND reg.activo = true
               AND reg.marca_salida_id IS NULL
        ),
        'details', v_detail
    );
END;
$function$;

REVOKE ALL ON FUNCTION public.materializar_marcas_salida_categoria_unica_torneo(uuid)
FROM PUBLIC;

REVOKE ALL ON FUNCTION public.materializar_marcas_salida_categoria_unica_torneo(uuid)
FROM anon;

GRANT EXECUTE ON FUNCTION public.materializar_marcas_salida_categoria_unica_torneo(uuid)
TO authenticated;

GRANT EXECUTE ON FUNCTION public.materializar_marcas_salida_categoria_unica_torneo(uuid)
TO service_role;

COMMIT;
