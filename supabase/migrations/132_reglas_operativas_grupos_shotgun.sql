-- ============================================================
-- 132_reglas_operativas_grupos_shotgun.sql
-- GOLF IN FULL
--
-- FASE 3B — REGLAS OPERATIVAS DE GRUPOS SHOTGUN
--
-- OBJETIVOS:
-- 1. Limpiar únicamente datos OPERATIVOS de grupos de prueba.
-- 2. Sustituir la regla histórica de doble salida por PAR.
-- 3. Exigir para Shotgun el modelo:
--      hoyo configurado + posición A/B.
-- 4. Hacer que B solo exista cuando el organizador habilitó
--    salida_doble para ese hoyo/categoría.
-- 5. Usar tamano_grupo_maximo por categoría en individuales.
-- 6. Permitir varios equipos completos en un mismo grupo.
-- 7. Validar máximo de EQUIPOS por grupo según configuración.
-- 8. Validar equipo único por ronda desde tournament_group_teams.
-- 9. Validar que jugador/equipo corresponda a la categoría
--    configurada para ese grupo Shotgun.
--
-- IMPORTANTE:
-- ESTA MIGRACIÓN NO TOCA:
--   public.players
--   public.tournament_registrations
--   public.tournament_teams
--   public.categories
--   public.tournament_categories
--
-- La limpieza se limita a:
--   tournament_group_players
--   tournament_group_teams
--   tournament_groups
--
-- Los jugadores, inscripciones y equipos permanecen intactos.
--
-- tournament_groups.tournament_team_id se conserva como campo
-- LEGACY para compatibilidad, pero el nuevo Shotgun NO lo usa.
--
-- ============================================================

begin;


-- ============================================================
-- 1. LIMPIEZA DE DATOS OPERATIVOS DE GRUPOS DE PRUEBA
--
-- No borra jugadores.
-- No borra inscripciones.
-- No borra equipos.
-- ============================================================

delete from public.tournament_group_players;

delete from public.tournament_group_teams;

update public.tournament_groups
   set activo = false,
       motivo_baja = coalesce(
           motivo_baja,
           'Limpieza de grupos de prueba previa al nuevo motor Shotgun.'
       )
 where activo = true;

delete from public.tournament_groups;


-- ============================================================
-- 2. NUEVA LÓGICA DE FORMATO / POSICIÓN A-B
--
-- Se conserva el nombre de la función existente para no crear
-- dependencias innecesarias.
--
-- SHOTGUN:
--   - requiere vínculo al hoyo configurado
--   - requiere posición A o B
--   - A siempre está permitida
--   - B solo si salida_doble = true
--   - ya NO depende del PAR
--
-- OTROS FORMATOS:
--   - no deben usar los campos específicos del nuevo Shotgun
-- ============================================================

create or replace function public.validar_formato_salida_y_doble_hoyo()
returns trigger
language plpgsql
as $$
declare
    v_formato_salida formato_salida_ronda;
    v_salida_doble   boolean;
    v_hoyo_activo    boolean;
    v_config_activo  boolean;
    v_sc_activo      boolean;
begin

    select tr.formato_salida
      into v_formato_salida
      from public.tournament_round_shifts trs
      join public.tournament_rounds tr
        on tr.id = trs.tournament_round_id
     where trs.id = new.tournament_round_shift_id;


    if v_formato_salida is null then
        raise exception
            'Esta ronda todavía no tiene definido su formato de salida.';
    end if;


    -- --------------------------------------------------------
    -- NUEVO MODELO SHOTGUN
    -- --------------------------------------------------------

    if v_formato_salida = 'shotgun'::formato_salida_ronda then

        if new.tournament_shotgun_category_hole_id is null
           or new.posicion_salida is null then

            raise exception
                'En una ronda Shotgun el grupo debe indicar el hoyo configurado de la categoría y la posición de salida A/B.';
        end if;


        select
            sh.salida_doble,
            sh.activo,
            cfg.activo,
            sc.activo
        into
            v_salida_doble,
            v_hoyo_activo,
            v_config_activo,
            v_sc_activo
        from public.tournament_shotgun_category_holes sh
        join public.tournament_shotgun_category_configs cfg
          on cfg.id = sh.tournament_shotgun_category_config_id
        join public.tournament_round_shift_categories sc
          on sc.id = cfg.tournament_round_shift_category_id
        where sh.id =
              new.tournament_shotgun_category_hole_id;


        if not found then
            raise exception
                'El hoyo Shotgun configurado indicado no existe.';
        end if;


        if v_hoyo_activo = false
           or v_config_activo = false
           or v_sc_activo = false then

            raise exception
                'El hoyo, la configuración o la categoría del turno ya no están activos.';
        end if;


        if new.posicion_salida = 'B'
           and v_salida_doble = false then

            raise exception
                'Este hoyo no tiene habilitada salida doble. Solo puede utilizarse la posición A.';
        end if;


        return new;
    end if;


    -- --------------------------------------------------------
    -- FORMATOS NO SHOTGUN
    -- --------------------------------------------------------

    if new.tournament_shotgun_category_hole_id is not null
       or new.posicion_salida is not null then

        raise exception
            'Los campos de hoyo Shotgun y posición A/B solo pueden utilizarse en rondas Shotgun.';
    end if;


    return new;

end;
$$;


-- El trigger existente trg_validar_formato_salida_y_doble_hoyo
-- continúa utilizando esta función reemplazada.


-- ============================================================
-- 3. ADAPTAR REGLA LEGACY tournament_team_id
--
-- SHOTGUN NUEVO:
--   tournament_team_id DEBE ser NULL.
--   Los equipos viven en tournament_group_teams.
--
-- GRUPOS NO SHOTGUN / LEGACY:
--   conserva la conducta histórica.
-- ============================================================

create or replace function public.validar_team_id_segun_formato_torneo()
returns trigger
language plpgsql
as $$
declare
    v_tipo_participacion formato_juego_torneo;
    v_formato_salida     formato_salida_ronda;
begin

    select
        tf.tipo_participacion,
        tr.formato_salida
    into
        v_tipo_participacion,
        v_formato_salida
    from public.tournament_round_shifts trs
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    join public.tournaments t
      on t.id = tr.tournament_id
    join public.tournament_formats tf
      on tf.id = t.tournament_format_id
    where trs.id = new.tournament_round_shift_id;


    if v_formato_salida = 'shotgun'::formato_salida_ronda
       and new.tournament_shotgun_category_hole_id is not null then

        if new.tournament_team_id is not null then
            raise exception
                'En el nuevo modelo Shotgun tournament_groups.tournament_team_id es legacy. Asigna los equipos mediante tournament_group_teams.';
        end if;

        return new;
    end if;


    -- Compatibilidad para otros flujos aún no migrados.
    if v_tipo_participacion = 'equipo'
       and new.tournament_team_id is null then

        raise exception
            'Este grupo legacy de torneo por equipos requiere tournament_team_id.';
    end if;


    if v_tipo_participacion is distinct from 'equipo'
       and new.tournament_team_id is not null then

        raise exception
            'Este torneo es individual: el grupo no debe tener tournament_team_id.';
    end if;


    return new;

end;
$$;


-- ============================================================
-- 4. ADAPTAR VALIDACIÓN DE JUGADORES INDIVIDUALES
--
-- SHOTGUN NUEVO:
--   usa cfg.tamano_grupo_maximo
--   exige torneo individual
--   exige categoría correcta
--
-- LEGACY / OTROS:
--   conserva tournaments.jugadores_por_grupo
--
-- También conserva:
--   jugador único por ronda.
-- ============================================================

create or replace function public.validar_grupo_individual()
returns trigger
language plpgsql
as $$
declare
    v_round_id              uuid;
    v_tournament_id         uuid;
    v_tipo_participacion    formato_juego_torneo;
    v_formato_salida        formato_salida_ronda;

    v_shotgun_hole_id       uuid;
    v_categoria_grupo       uuid;

    v_maximo                integer;
    v_total_en_grupo        integer;
    v_conflicto_ronda       integer;

    v_reg_tournament_id     uuid;
    v_reg_category_id       uuid;
begin

    select
        tr.id,
        tr.tournament_id,
        tf.tipo_participacion,
        tr.formato_salida,
        g.tournament_shotgun_category_hole_id
    into
        v_round_id,
        v_tournament_id,
        v_tipo_participacion,
        v_formato_salida,
        v_shotgun_hole_id
    from public.tournament_groups g
    join public.tournament_round_shifts trs
      on trs.id = g.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    join public.tournaments t
      on t.id = tr.tournament_id
    join public.tournament_formats tf
      on tf.id = t.tournament_format_id
    where g.id = new.tournament_group_id;


    if v_round_id is null then
        raise exception
            'El grupo indicado no existe.';
    end if;


    select
        reg.tournament_id,
        reg.tournament_category_id
    into
        v_reg_tournament_id,
        v_reg_category_id
    from public.tournament_registrations reg
    where reg.id = new.tournament_registration_id
      and reg.activo = true;


    if v_reg_tournament_id is null then
        raise exception
            'La inscripción indicada no existe o no está activa.';
    end if;


    if v_reg_tournament_id is distinct from v_tournament_id then
        raise exception
            'La inscripción y el grupo pertenecen a torneos diferentes.';
    end if;


    -- --------------------------------------------------------
    -- NUEVO SHOTGUN
    -- --------------------------------------------------------

    if v_formato_salida = 'shotgun'::formato_salida_ronda
       and v_shotgun_hole_id is not null then

        if v_tipo_participacion is distinct from 'individual' then
            raise exception
                'Este torneo es por equipos. Los equipos deben asignarse mediante tournament_group_teams.';
        end if;


        select
            cfg.tamano_grupo_maximo,
            sc.tournament_category_id
        into
            v_maximo,
            v_categoria_grupo
        from public.tournament_shotgun_category_holes sh
        join public.tournament_shotgun_category_configs cfg
          on cfg.id = sh.tournament_shotgun_category_config_id
        join public.tournament_round_shift_categories sc
          on sc.id = cfg.tournament_round_shift_category_id
        where sh.id = v_shotgun_hole_id
          and sh.activo = true
          and cfg.activo = true
          and sc.activo = true;


        if v_maximo is null then
            raise exception
                'No existe una configuración Shotgun activa para este grupo.';
        end if;


        if v_reg_category_id is distinct from v_categoria_grupo then
            raise exception
                'El jugador no pertenece a la categoría configurada para este grupo.';
        end if;

    else

        select t.jugadores_por_grupo
        into v_maximo
        from public.tournament_rounds tr
        join public.tournaments t
          on t.id = tr.tournament_id
        where tr.id = v_round_id;

    end if;


    -- --------------------------------------------------------
    -- MÁXIMO DEL GRUPO
    -- --------------------------------------------------------

    select count(*)
    into v_total_en_grupo
    from public.tournament_group_players gp
    where gp.tournament_group_id = new.tournament_group_id
      and gp.id is distinct from new.id;


    if v_total_en_grupo >= v_maximo then
        raise exception
            'Este grupo ya alcanzó su máximo de % jugadores.',
            v_maximo;
    end if;


    -- --------------------------------------------------------
    -- JUGADOR ÚNICO POR RONDA
    -- --------------------------------------------------------

    select count(*)
    into v_conflicto_ronda
    from public.tournament_group_players gp
    join public.tournament_groups g
      on g.id = gp.tournament_group_id
    join public.tournament_round_shifts trs
      on trs.id = g.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    where tr.id = v_round_id
      and g.activo = true
      and gp.tournament_registration_id =
          new.tournament_registration_id
      and gp.id is distinct from new.id;


    if v_conflicto_ronda > 0 then
        raise exception
            'Este jugador ya está asignado a otro grupo activo en esta ronda.';
    end if;


    return new;

end;
$$;


-- ============================================================
-- 5. VALIDACIÓN OPERATIVA DE EQUIPOS EN GRUPOS SHOTGUN
--
-- Reglas:
-- - Solo torneos por equipos.
-- - El equipo pertenece al mismo torneo.
-- - Debe corresponder a la categoría del grupo.
-- - Categoría NULL del equipo solo se tolera si el torneo tiene
--   exactamente UNA categoría activa.
-- - Máximo del grupo = tamano_grupo_maximo, medido en EQUIPOS.
-- - Un equipo no puede estar en dos grupos activos de la ronda.
-- ============================================================

create or replace function public.validar_group_team_reglas_shotgun()
returns trigger
language plpgsql
as $$
declare
    v_round_id               uuid;
    v_tournament_id          uuid;
    v_tipo_participacion     formato_juego_torneo;
    v_formato_salida         formato_salida_ronda;
    v_shotgun_hole_id        uuid;

    v_categoria_grupo        uuid;
    v_maximo_equipos         integer;

    v_team_tournament_id     uuid;
    v_team_category_id       uuid;
    v_team_activo            boolean;

    v_num_categorias_torneo  integer;
    v_categoria_unica        uuid;

    v_total_equipos_grupo    integer;
    v_conflicto_ronda        integer;
begin

    if new.activo = false then
        return new;
    end if;


    select
        tr.id,
        tr.tournament_id,
        tf.tipo_participacion,
        tr.formato_salida,
        g.tournament_shotgun_category_hole_id
    into
        v_round_id,
        v_tournament_id,
        v_tipo_participacion,
        v_formato_salida,
        v_shotgun_hole_id
    from public.tournament_groups g
    join public.tournament_round_shifts trs
      on trs.id = g.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    join public.tournaments t
      on t.id = tr.tournament_id
    join public.tournament_formats tf
      on tf.id = t.tournament_format_id
    where g.id = new.tournament_group_id;


    if v_round_id is null then
        raise exception
            'El grupo indicado no existe.';
    end if;


    if v_formato_salida is distinct from
       'shotgun'::formato_salida_ronda
       or v_shotgun_hole_id is null then

        raise exception
            'La asignación mediante tournament_group_teams corresponde al nuevo modelo Shotgun.';
    end if;


    if v_tipo_participacion is distinct from 'equipo' then
        raise exception
            'Este torneo es individual. Los participantes se asignan mediante tournament_group_players.';
    end if;


    select
        cfg.tamano_grupo_maximo,
        sc.tournament_category_id
    into
        v_maximo_equipos,
        v_categoria_grupo
    from public.tournament_shotgun_category_holes sh
    join public.tournament_shotgun_category_configs cfg
      on cfg.id = sh.tournament_shotgun_category_config_id
    join public.tournament_round_shift_categories sc
      on sc.id = cfg.tournament_round_shift_category_id
    where sh.id = v_shotgun_hole_id
      and sh.activo = true
      and cfg.activo = true
      and sc.activo = true;


    if v_maximo_equipos is null then
        raise exception
            'No existe una configuración Shotgun activa para este grupo.';
    end if;


    select
        tt.tournament_id,
        tt.tournament_category_id,
        tt.activo
    into
        v_team_tournament_id,
        v_team_category_id,
        v_team_activo
    from public.tournament_teams tt
    where tt.id = new.tournament_team_id;


    if v_team_tournament_id is null then
        raise exception
            'El equipo indicado no existe.';
    end if;


    if v_team_activo = false then
        raise exception
            'El equipo indicado está desactivado.';
    end if;


    if v_team_tournament_id is distinct from v_tournament_id then
        raise exception
            'El equipo y el grupo pertenecen a torneos diferentes.';
    end if;


    -- --------------------------------------------------------
    -- CATEGORÍA DEL EQUIPO
    --
    -- Si team.category es NULL:
    -- solamente es válido en torneo de categoría única.
    -- --------------------------------------------------------

    if v_team_category_id is null then

        select
            count(*),
            min(tc.id::text)::uuid
        into
            v_num_categorias_torneo,
            v_categoria_unica
        from public.tournament_categories tc
        where tc.tournament_id = v_tournament_id;


        if v_num_categorias_torneo <> 1 then
            raise exception
                'El equipo no tiene categoría asignada y el torneo tiene más de una categoría.';
        end if;


        if v_categoria_unica is distinct from v_categoria_grupo then
            raise exception
                'La categoría única del torneo no coincide con la categoría configurada para el grupo.';
        end if;

    elsif v_team_category_id is distinct from v_categoria_grupo then

        raise exception
            'El equipo no pertenece a la categoría configurada para este grupo.';

    end if;


    -- --------------------------------------------------------
    -- MÁXIMO DE EQUIPOS EN EL GRUPO
    -- --------------------------------------------------------

    select count(*)
    into v_total_equipos_grupo
    from public.tournament_group_teams gt
    where gt.tournament_group_id = new.tournament_group_id
      and gt.activo = true
      and gt.id is distinct from new.id;


    if v_total_equipos_grupo >= v_maximo_equipos then
        raise exception
            'Este grupo ya alcanzó su máximo de % equipos.',
            v_maximo_equipos;
    end if;


    -- --------------------------------------------------------
    -- EQUIPO ÚNICO POR RONDA
    -- --------------------------------------------------------

    select count(*)
    into v_conflicto_ronda
    from public.tournament_group_teams gt
    join public.tournament_groups g
      on g.id = gt.tournament_group_id
    join public.tournament_round_shifts trs
      on trs.id = g.tournament_round_shift_id
    join public.tournament_rounds tr
      on tr.id = trs.tournament_round_id
    where tr.id = v_round_id
      and g.activo = true
      and gt.activo = true
      and gt.tournament_team_id = new.tournament_team_id
      and gt.id is distinct from new.id;


    if v_conflicto_ronda > 0 then
        raise exception
            'Este equipo ya está asignado a otro grupo activo en esta ronda.';
    end if;


    return new;

end;
$$;


create trigger trg_validar_group_team_reglas_shotgun
before insert or update
on public.tournament_group_teams
for each row
execute function public.validar_group_team_reglas_shotgun();


-- ============================================================
-- 6. FUNCIÓN LEGACY validar_equipo_unico_por_ronda
--
-- Se mantiene instalada para compatibilidad, pero el nuevo
-- Shotgun usa tournament_group_teams y por ello
-- tournament_groups.tournament_team_id queda NULL.
-- ============================================================


-- ============================================================
-- 7. COMENTARIOS DE TRANSICIÓN
-- ============================================================

comment on column public.tournament_groups.tournament_team_id is
'LEGACY. No utilizar para nuevos grupos Shotgun. En torneos Shotgun por equipos, los equipos se asignan mediante public.tournament_group_teams.';


comment on table public.tournament_group_teams is
'Relación operativa oficial para asignar equipos completos a grupos Shotgun. El tamaño del grupo se mide en equipos y se valida contra tournament_shotgun_category_configs.tamano_grupo_maximo.';


commit;
