-- MIGRACION 136
-- Preview PDF de tarjetas de score — Shotgun · Stroke Play · Individual
-- IMPORTANTE: revisar en el chat antes de ejecutar en Supabase.

BEGIN;

CREATE OR REPLACE FUNCTION public.obtener_preview_tarjetas_score_shotgun_individual(
    p_config_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
STABLE
SECURITY DEFINER
SET search_path = public
AS $function$
DECLARE
    v_ctx record;
    v_result jsonb;
BEGIN
    IF auth.uid() IS NULL THEN
        RAISE EXCEPTION 'No autenticado.' USING ERRCODE = '42501';
    END IF;

    IF NOT public.can_manage_tournament_shotgun_config(auth.uid(), p_config_id) THEN
        RAISE EXCEPTION 'No tienes permisos para consultar esta configuración Shotgun.' USING ERRCODE = '42501';
    END IF;

    SELECT
        cfg.id AS config_id,
        cfg.tamano_grupo_normal,
        cfg.tamano_grupo_maximo,
        cfg.intervalo_salida_b_minutos,
        rsc.id AS round_shift_category_id,
        rsc.tournament_category_id,
        tc.category_id,
        cat.nombre AS category_nombre,
        cat.codigo AS category_codigo,
        rs.id AS shift_id,
        rs.numero_turno,
        rs.hora_salida AS shift_hora_salida,
        tr.id AS round_id,
        tr.numero_ronda,
        tr.fecha AS round_fecha,
        tr.formato_salida,
        tr.campo_golf_id,
        t.id AS tournament_id,
        t.nombre AS tournament_nombre,
        t.logo_url AS tournament_logo_url,
        t.es_beneficencia,
        t.club_id,
        c.nombre AS club_nombre,
        cg.nombre_oficial AS course_nombre,
        cg.numero_hoyos AS course_numero_hoyos,
        cg.timezone_id AS course_timezone,
        tf.id AS format_id,
        tf.name AS format_name,
        tf.code AS format_code,
        tf.scoring_engine,
        tf.tipo_participacion
    INTO v_ctx
    FROM public.tournament_shotgun_category_configs cfg
    JOIN public.tournament_round_shift_categories rsc
      ON rsc.id = cfg.tournament_round_shift_category_id
    JOIN public.tournament_categories tc
      ON tc.id = rsc.tournament_category_id
    JOIN public.categories cat
      ON cat.id = tc.category_id
    JOIN public.tournament_round_shifts rs
      ON rs.id = rsc.tournament_round_shift_id
    JOIN public.tournament_rounds tr
      ON tr.id = rs.tournament_round_id
    JOIN public.tournaments t
      ON t.id = tr.tournament_id
    LEFT JOIN public.clubs c
      ON c.id = t.club_id
    JOIN public.campos_golf cg
      ON cg.id = tr.campo_golf_id
    JOIN public.tournament_formats tf
      ON tf.id = COALESCE(tr.tournament_format_id, t.tournament_format_id)
    WHERE cfg.id = p_config_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'La configuración Shotgun no existe o su cadena de contexto está incompleta.';
    END IF;

    WITH
    course_holes AS (
        SELECT
            h.id AS hoyo_id,
            h.numero_hoyo,
            h.par,
            h.handicap_hoyo
        FROM public.hoyos h
        WHERE h.campo_golf_id = v_ctx.campo_golf_id
        ORDER BY h.numero_hoyo
    ),
    holes_json AS (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'hoyoId', ch.hoyo_id,
                    'numero', ch.numero_hoyo,
                    'par', ch.par,
                    'strokeIndex', ch.handicap_hoyo
                ) ORDER BY ch.numero_hoyo
            ), '[]'::jsonb
        ) AS data
        FROM course_holes ch
    ),
    course_par AS (
        SELECT
            SUM(par) FILTER (WHERE numero_hoyo BETWEEN 1 AND 9) AS par_out,
            SUM(par) FILTER (WHERE numero_hoyo BETWEEN 10 AND 18) AS par_in,
            SUM(par) AS par_total
        FROM course_holes
    ),
    active_group_base AS (
        SELECT
            g.id AS group_id,
            g.tournament_shotgun_category_hole_id AS shotgun_category_hole_id,
            g.hoyo_id AS group_hoyo_id,
            g.posicion_salida,
            g.hora_salida AS hora_salida_materializada,
            g.etiqueta,
            sh.hoyo_id AS config_hoyo_id,
            sh.salida_doble,
            h.numero_hoyo,
            CASE
                WHEN g.hora_salida IS NOT NULL THEN g.hora_salida
                WHEN g.posicion_salida = 'B' AND NOT COALESCE(sh.salida_doble, false) THEN NULL
                ELSE public.hora_salida_shotgun(sh.id, g.posicion_salida)
            END AS hora_salida
        FROM public.tournament_groups g
        JOIN public.tournament_shotgun_category_holes sh
          ON sh.id = g.tournament_shotgun_category_hole_id
        LEFT JOIN public.hoyos h
          ON h.id = sh.hoyo_id
        WHERE sh.tournament_shotgun_category_config_id = p_config_id
          AND sh.activo = true
          AND g.activo = true
    ),
    assigned AS (
        SELECT
            agb.*,
            gp.tournament_registration_id AS registration_id,
            gp.orden_en_grupo,
            reg.folio,
            reg.player_id,
            reg.tournament_category_id AS registration_category_id,
            reg.marca_salida_id,
            p.nombres,
            p.apellidos,
            p.sexo,
            p.numero_ghin,
            p.handicap_verificado,
            p.handicap_declarado,
            p.handicap_estatus,
            p.activo AS player_activo,
            pc.nombre AS player_club_nombre,
            ms.nombre AS tee_nombre,
            ms.color_hex AS tee_color_hex,
            ms.campo_golf_id AS tee_campo_golf_id,
            ms.activo AS tee_activo
        FROM active_group_base agb
        JOIN public.tournament_group_players gp
          ON gp.tournament_group_id = agb.group_id
        JOIN public.tournament_registrations reg
          ON reg.id = gp.tournament_registration_id
         AND reg.activo = true
        LEFT JOIN public.players p
          ON p.id = reg.player_id
        LEFT JOIN public.clubs pc
          ON pc.id = p.club_id
        LEFT JOIN public.marcas_salida ms
          ON ms.id = reg.marca_salida_id
    ),
    effective_tees AS (
        SELECT DISTINCT marca_salida_id
        FROM assigned
        WHERE marca_salida_id IS NOT NULL
    ),
    tee_distances AS (
        SELECT
            et.marca_salida_id,
            ch.hoyo_id,
            ch.numero_hoyo,
            dh.distancia_yardas
        FROM effective_tees et
        CROSS JOIN course_holes ch
        LEFT JOIN public.distancias_hoyo dh
          ON dh.hoyo_id = ch.hoyo_id
         AND dh.marca_salida_id = et.marca_salida_id
    ),
    tee_distance_arrays AS (
        SELECT
            marca_salida_id,
            jsonb_agg(
                jsonb_build_object(
                    'numero', numero_hoyo,
                    'distancia', distancia_yardas
                ) ORDER BY numero_hoyo
            ) AS distances,
            SUM(distancia_yardas) FILTER (WHERE numero_hoyo BETWEEN 1 AND 9) AS yards_out,
            SUM(distancia_yardas) FILTER (WHERE numero_hoyo BETWEEN 10 AND 18) AS yards_in,
            SUM(distancia_yardas) AS yards_total
        FROM tee_distances
        GROUP BY marca_salida_id
    ),
    group_companions AS (
        SELECT
            a.group_id,
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', a.registration_id,
                    'nombreCompleto', trim(concat_ws(' ', a.nombres, a.apellidos))
                ) ORDER BY a.orden_en_grupo NULLS LAST, a.apellidos, a.nombres
            ) AS members
        FROM assigned a
        GROUP BY a.group_id
    ),
    duplicate_regs AS (
        SELECT registration_id, COUNT(*) AS n
        FROM assigned
        GROUP BY registration_id
        HAVING COUNT(*) > 1
    ),
    cards_json AS (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', a.registration_id,
                    'folio', a.folio,
                    'player', jsonb_build_object(
                        'id', a.player_id,
                        'nombres', a.nombres,
                        'apellidos', a.apellidos,
                        'nombreCompleto', trim(concat_ws(' ', a.nombres, a.apellidos)),
                        'sexo', a.sexo,
                        'numeroGhin', a.numero_ghin,
                        'clubNombre', a.player_club_nombre
                    ),
                    'handicap', jsonb_build_object(
                        'valor', COALESCE(a.handicap_verificado, a.handicap_declarado),
                        'origen', CASE
                            WHEN a.handicap_verificado IS NOT NULL THEN 'verificado'
                            WHEN a.handicap_declarado IS NOT NULL THEN 'declarado'
                            ELSE 'null'
                        END,
                        'estatus', a.handicap_estatus
                    ),
                    'category', jsonb_build_object(
                        'tournamentCategoryId', v_ctx.tournament_category_id,
                        'categoryId', v_ctx.category_id,
                        'nombre', v_ctx.category_nombre
                    ),
                    'tee', CASE WHEN a.marca_salida_id IS NULL THEN NULL ELSE jsonb_build_object(
                        'marcaSalidaId', a.marca_salida_id,
                        'nombre', a.tee_nombre,
                        'colorHex', a.tee_color_hex
                    ) END,
                    'start', jsonb_build_object(
                        'tournamentGroupId', a.group_id,
                        'shotgunCategoryHoleId', a.shotgun_category_hole_id,
                        'hoyoId', a.config_hoyo_id,
                        'numeroHoyo', a.numero_hoyo,
                        'posicion', a.posicion_salida,
                        'hora', a.hora_salida,
                        'horaLocalTexto', CASE
                            WHEN a.hora_salida IS NULL THEN NULL
                            ELSE to_char(a.hora_salida AT TIME ZONE v_ctx.course_timezone, 'HH24:MI')
                        END,
                        'etiqueta', a.etiqueta,
                        'ordenEnGrupo', a.orden_en_grupo,
                        'companeros', COALESCE(gc.members, '[]'::jsonb)
                    ),
                    'holes', COALESCE(tda.distances, '[]'::jsonb),
                    'totals', jsonb_build_object(
                        'parOut', cp.par_out,
                        'parIn', cp.par_in,
                        'parTotal', cp.par_total,
                        'yardsOut', tda.yards_out,
                        'yardsIn', tda.yards_in,
                        'yardsTotal', tda.yards_total
                    ),
                    'warnings', COALESCE((
                        SELECT jsonb_agg(w.code ORDER BY w.code)
                        FROM (
                            SELECT 'handicap_nulo'::text AS code
                            WHERE a.handicap_verificado IS NULL AND a.handicap_declarado IS NULL
                            UNION ALL SELECT 'handicap_no_verificado'
                            WHERE a.handicap_verificado IS NULL AND a.handicap_declarado IS NOT NULL
                            UNION ALL SELECT 'handicap_vencido'
                            WHERE a.handicap_estatus::text = 'vencido'
                            UNION ALL SELECT 'marca_inactiva'
                            WHERE a.marca_salida_id IS NOT NULL AND COALESCE(a.tee_activo, false) = false
                            UNION ALL SELECT 'distancia_faltante'
                            WHERE EXISTS (
                                SELECT 1 FROM tee_distances td
                                WHERE td.marca_salida_id = a.marca_salida_id
                                  AND td.distancia_yardas IS NULL
                            )
                        ) w
                    ), '[]'::jsonb)
                ) ORDER BY
                    a.numero_hoyo,
                    a.posicion_salida,
                    a.orden_en_grupo NULLS LAST,
                    a.apellidos,
                    a.nombres
            ), '[]'::jsonb
        ) AS data
        FROM assigned a
        CROSS JOIN course_par cp
        LEFT JOIN tee_distance_arrays tda
          ON tda.marca_salida_id = a.marca_salida_id
        LEFT JOIN group_companions gc
          ON gc.group_id = a.group_id
    ),
    unassigned_rows AS (
        SELECT
            reg.id AS registration_id,
            reg.player_id,
            reg.folio,
            reg.marca_salida_id,
            p.nombres,
            p.apellidos,
            p.handicap_verificado,
            p.handicap_declarado,
            p.handicap_estatus,
            ms.nombre AS tee_nombre,
            ms.color_hex AS tee_color_hex
        FROM public.tournament_registrations reg
        LEFT JOIN public.players p ON p.id = reg.player_id
        LEFT JOIN public.marcas_salida ms ON ms.id = reg.marca_salida_id
        WHERE reg.tournament_id = v_ctx.tournament_id
          AND reg.tournament_category_id = v_ctx.tournament_category_id
          AND reg.activo = true
          AND NOT EXISTS (
              SELECT 1
              FROM public.tournament_group_players gp2
              JOIN public.tournament_groups g2
                ON g2.id = gp2.tournament_group_id
               AND g2.activo = true
              JOIN public.tournament_shotgun_category_holes sh2
                ON sh2.id = g2.tournament_shotgun_category_hole_id
              JOIN public.tournament_shotgun_category_configs cfg2
                ON cfg2.id = sh2.tournament_shotgun_category_config_id
              JOIN public.tournament_round_shift_categories rsc2
                ON rsc2.id = cfg2.tournament_round_shift_category_id
              JOIN public.tournament_round_shifts rs2
                ON rs2.id = rsc2.tournament_round_shift_id
              WHERE gp2.tournament_registration_id = reg.id
                AND rs2.tournament_round_id = v_ctx.round_id
          )
    ),
    unassigned_json AS (
        SELECT COALESCE(
            jsonb_agg(
                jsonb_build_object(
                    'registrationId', u.registration_id,
                    'playerId', u.player_id,
                    'folio', u.folio,
                    'nombreCompleto', trim(concat_ws(' ', u.nombres, u.apellidos)),
                    'category', jsonb_build_object(
                        'tournamentCategoryId', v_ctx.tournament_category_id,
                        'categoryId', v_ctx.category_id,
                        'nombre', v_ctx.category_nombre
                    ),
                    'tee', CASE WHEN u.marca_salida_id IS NULL THEN NULL ELSE jsonb_build_object(
                        'marcaSalidaId', u.marca_salida_id,
                        'nombre', u.tee_nombre,
                        'colorHex', u.tee_color_hex
                    ) END,
                    'handicap', jsonb_build_object(
                        'valor', COALESCE(u.handicap_verificado, u.handicap_declarado),
                        'origen', CASE
                            WHEN u.handicap_verificado IS NOT NULL THEN 'verificado'
                            WHEN u.handicap_declarado IS NOT NULL THEN 'declarado'
                            ELSE 'null'
                        END,
                        'estatus', u.handicap_estatus
                    )
                ) ORDER BY u.apellidos, u.nombres
            ), '[]'::jsonb
        ) AS data,
        COUNT(*) AS n
        FROM unassigned_rows u
    ),
    errors AS (
        SELECT 'ronda_no_shotgun'::text AS code,
               'La ronda no está configurada con salida Shotgun.'::text AS message,
               NULL::uuid AS registration_id, NULL::uuid AS group_id, NULL::uuid AS hoyo_id
        WHERE v_ctx.formato_salida::text <> 'shotgun'

        UNION ALL
        SELECT 'formato_no_soportado',
               'Preview V1 sólo soporta Stroke Play individual.', NULL, NULL, NULL
        WHERE COALESCE(v_ctx.tipo_participacion::text, '') <> 'individual'
           OR COALESCE(v_ctx.scoring_engine::text, '') <> 'stroke'

        UNION ALL
        SELECT 'registro_sin_jugador',
               'Existe una inscripción asignada cuyo jugador no existe o está inactivo.',
               a.registration_id, a.group_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.player_id IS NULL OR COALESCE(a.player_activo, false) = false

        UNION ALL
        SELECT 'jugador_duplicado',
               'La misma inscripción aparece asignada más de una vez en la configuración.',
               d.registration_id, NULL, NULL
        FROM duplicate_regs d

        UNION ALL
        SELECT 'grupo_hoyo_inconsistente',
               'El grupo y la configuración Shotgun apuntan a hoyos distintos.',
               NULL, agb.group_id, agb.config_hoyo_id
        FROM active_group_base agb
        WHERE agb.group_hoyo_id IS DISTINCT FROM agb.config_hoyo_id

        UNION ALL
        SELECT 'posicion_b_sin_salida_doble',
               'Existe un grupo B en un hoyo que no tiene salida doble habilitada.',
               NULL, agb.group_id, agb.config_hoyo_id
        FROM active_group_base agb
        WHERE agb.posicion_salida::text = 'B' AND COALESCE(agb.salida_doble, false) = false

        UNION ALL
        SELECT 'marca_efectiva_inexistente_o_de_otro_campo',
               'La inscripción no tiene una marca de salida válida para el campo de la ronda.',
               a.registration_id, a.group_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.marca_salida_id IS NULL
           OR a.tee_nombre IS NULL
           OR a.tee_campo_golf_id IS DISTINCT FROM v_ctx.campo_golf_id

        UNION ALL
        SELECT 'inscripcion_de_otra_categoria',
               'La inscripción asignada no pertenece a la categoría de esta configuración.',
               a.registration_id, a.group_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.registration_category_id IS DISTINCT FROM v_ctx.tournament_category_id

        UNION ALL
        SELECT 'hora_salida_irresoluble',
               'No fue posible resolver la hora de salida del grupo.',
               a.registration_id, a.group_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.hora_salida IS NULL
    ),
    warnings AS (
        SELECT 'campo_incompleto'::text AS code,
               format('El campo tiene %s hoyos en catálogo; se esperaban 18.', COUNT(*))::text AS message,
               NULL::uuid AS registration_id, NULL::uuid AS hoyo_id
        FROM course_holes
        HAVING COUNT(*) <> 18

        UNION ALL
        SELECT 'par_faltante',
               format('Falta PAR en el hoyo %s.', ch.numero_hoyo), NULL, ch.hoyo_id
        FROM course_holes ch
        WHERE ch.par IS NULL

        UNION ALL
        SELECT 'stroke_index_faltante',
               format('Falta Stroke Index/HCP en el hoyo %s.', ch.numero_hoyo), NULL, ch.hoyo_id
        FROM course_holes ch
        WHERE ch.handicap_hoyo IS NULL

        UNION ALL
        SELECT 'stroke_index_duplicado_o_incompleto',
               'El conjunto de Stroke Index/HCP del campo no contiene exactamente los valores 1 a 18.',
               NULL, NULL
        WHERE (
            SELECT COUNT(*) = 18
               AND COUNT(DISTINCT handicap_hoyo) = 18
               AND MIN(handicap_hoyo) = 1
               AND MAX(handicap_hoyo) = 18
            FROM course_holes
        ) IS NOT TRUE

        UNION ALL
        SELECT 'handicap_nulo',
               'El jugador no tiene hándicap declarado ni verificado.',
               a.registration_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.handicap_verificado IS NULL AND a.handicap_declarado IS NULL

        UNION ALL
        SELECT 'handicap_no_verificado',
               'Se utilizará el hándicap declarado porque no existe hándicap verificado.',
               a.registration_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.handicap_verificado IS NULL AND a.handicap_declarado IS NOT NULL

        UNION ALL
        SELECT 'handicap_vencido',
               'El hándicap verificado del jugador figura como vencido.',
               a.registration_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.handicap_estatus::text = 'vencido'

        UNION ALL
        SELECT 'marca_inactiva',
               'La marca efectiva del jugador está inactiva.',
               a.registration_id, a.config_hoyo_id
        FROM assigned a
        WHERE a.marca_salida_id IS NOT NULL AND COALESCE(a.tee_activo, false) = false

        UNION ALL
        SELECT 'distancia_faltante',
               format('Falta distancia para la marca del jugador en el hoyo %s.', td.numero_hoyo),
               a.registration_id, td.hoyo_id
        FROM assigned a
        JOIN tee_distances td ON td.marca_salida_id = a.marca_salida_id
        WHERE td.distancia_yardas IS NULL

        UNION ALL
        SELECT 'jugador_sin_asignar',
               'El jugador está activo en la categoría pero todavía no tiene grupo en esta ronda.',
               u.registration_id, NULL
        FROM unassigned_rows u

        UNION ALL
        SELECT 'grupo_vacio',
               'Existe un grupo activo sin jugadores.', NULL, agb.config_hoyo_id
        FROM active_group_base agb
        WHERE NOT EXISTS (
            SELECT 1 FROM public.tournament_group_players gp
            WHERE gp.tournament_group_id = agb.group_id
        )

        UNION ALL
        SELECT 'grupo_excede_tamano_maximo',
               format('El grupo tiene %s jugadores y el máximo configurado es %s.', COUNT(*), v_ctx.tamano_grupo_maximo),
               NULL, agb.config_hoyo_id
        FROM active_group_base agb
        JOIN public.tournament_group_players gp ON gp.tournament_group_id = agb.group_id
        GROUP BY agb.group_id, agb.config_hoyo_id
        HAVING COUNT(*) > v_ctx.tamano_grupo_maximo
    ),
    errors_json AS (
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'code', code,
            'message', message,
            'registrationId', registration_id,
            'groupId', group_id,
            'hoyoId', hoyo_id
        )) ORDER BY code, message), '[]'::jsonb) AS data,
        COUNT(*) AS n
        FROM errors
    ),
    warnings_json AS (
        SELECT COALESCE(jsonb_agg(jsonb_strip_nulls(jsonb_build_object(
            'code', code,
            'message', message,
            'registrationId', registration_id,
            'hoyoId', hoyo_id
        )) ORDER BY code, message), '[]'::jsonb) AS data,
        COUNT(*) AS n
        FROM warnings
    ),
    group_count AS (
        SELECT COUNT(*) AS n FROM active_group_base
    )
    SELECT jsonb_build_object(
        'generadoEn', now(),
        'tournament', jsonb_build_object(
            'id', v_ctx.tournament_id,
            'nombre', v_ctx.tournament_nombre,
            'logoUrl', v_ctx.tournament_logo_url,
            'esBeneficencia', v_ctx.es_beneficencia,
            'club', jsonb_build_object('id', v_ctx.club_id, 'nombre', v_ctx.club_nombre),
            'formato', jsonb_build_object(
                'id', v_ctx.format_id,
                'code', v_ctx.format_code,
                'name', v_ctx.format_name,
                'scoringEngine', v_ctx.scoring_engine,
                'tipoParticipacion', v_ctx.tipo_participacion
            )
        ),
        'course', jsonb_build_object(
            'id', v_ctx.campo_golf_id,
            'nombreOficial', v_ctx.course_nombre,
            'numeroHoyos', v_ctx.course_numero_hoyos,
            'timezone', v_ctx.course_timezone
        ),
        'round', jsonb_build_object(
            'id', v_ctx.round_id,
            'numeroRonda', v_ctx.numero_ronda,
            'fecha', v_ctx.round_fecha,
            'formatoSalida', v_ctx.formato_salida,
            'shift', jsonb_build_object(
                'id', v_ctx.shift_id,
                'numeroTurno', v_ctx.numero_turno,
                'horaSalidaBase', v_ctx.shift_hora_salida
            )
        ),
        'config', jsonb_build_object(
            'id', v_ctx.config_id,
            'tamanoGrupoNormal', v_ctx.tamano_grupo_normal,
            'tamanoGrupoMaximo', v_ctx.tamano_grupo_maximo,
            'intervaloSalidaBMinutos', v_ctx.intervalo_salida_b_minutos
        ),
        'category', jsonb_build_object(
            'tournamentCategoryId', v_ctx.tournament_category_id,
            'categoryId', v_ctx.category_id,
            'nombre', v_ctx.category_nombre,
            'codigo', v_ctx.category_codigo
        ),
        'holes', hj.data,
        'coursePar', jsonb_build_object('out', cp.par_out, 'in', cp.par_in, 'total', cp.par_total),
        'cards', cj.data,
        'unassigned', uj.data,
        'errors', ej.data,
        'warnings', wj.data,
        'counts', jsonb_build_object(
            'cards', jsonb_array_length(cj.data),
            'unassigned', uj.n,
            'grupos', gcnt.n,
            'errors', ej.n,
            'warnings', wj.n
        )
    )
    INTO v_result
    FROM holes_json hj
    CROSS JOIN course_par cp
    CROSS JOIN cards_json cj
    CROSS JOIN unassigned_json uj
    CROSS JOIN errors_json ej
    CROSS JOIN warnings_json wj
    CROSS JOIN group_count gcnt;

    RETURN v_result;
END;
$function$;

REVOKE ALL ON FUNCTION public.obtener_preview_tarjetas_score_shotgun_individual(uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.obtener_preview_tarjetas_score_shotgun_individual(uuid) FROM anon;
GRANT EXECUTE ON FUNCTION public.obtener_preview_tarjetas_score_shotgun_individual(uuid) TO authenticated;

COMMIT;

-- ============================================================
-- VERIFICACION POSTERIOR A LA MIGRACION
-- Ejecutar DESPUES de que la migracion termine correctamente.
-- ============================================================

SELECT jsonb_pretty(jsonb_build_object(
    'funcion_existe', to_regprocedure('public.obtener_preview_tarjetas_score_shotgun_individual(uuid)') IS NOT NULL,
    'permisos', jsonb_build_object(
        'anon', has_function_privilege('anon', 'public.obtener_preview_tarjetas_score_shotgun_individual(uuid)', 'EXECUTE'),
        'authenticated', has_function_privilege('authenticated', 'public.obtener_preview_tarjetas_score_shotgun_individual(uuid)', 'EXECUTE')
    ),
    'propiedades', (
        SELECT jsonb_build_object(
            'security_definer', p.prosecdef,
            'volatility', CASE p.provolatile WHEN 'i' THEN 'IMMUTABLE' WHEN 's' THEN 'STABLE' WHEN 'v' THEN 'VOLATILE' END,
            'return_type', pg_get_function_result(p.oid)
        )
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public'
          AND p.proname = 'obtener_preview_tarjetas_score_shotgun_individual'
          AND pg_get_function_identity_arguments(p.oid) = 'p_config_id uuid'
        LIMIT 1
    )
)) AS verificacion_migracion_136;
