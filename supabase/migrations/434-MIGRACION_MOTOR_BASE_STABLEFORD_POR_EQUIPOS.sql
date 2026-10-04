-- 434-MIGRACION_MOTOR_BASE_STABLEFORD_POR_EQUIPOS.sql
-- TEE CENTRAL / GOLF IN FULL
-- Objetivo: habilitar la base deportiva de Stableford por equipos sin crear tarjeta TEAM.
-- Cada integrante conserva tarjeta individual; el resultado TEAM se deriva hoyo por hoyo.
-- IMPORTANTE: ejecutar manualmente en Supabase. Lovable NO ejecuta migraciones.

begin;

-- -----------------------------------------------------------------------------
-- 1. Frontera deportiva explícita para WD / DNF.
--    No se infiere por timestamp y NO rellena huecos de la tarjeta.
-- -----------------------------------------------------------------------------
alter table public.tournament_scorecard_round_outcomes
  add column if not exists effective_through_round_hole_snapshot_id uuid null;

alter table public.tournament_scorecard_round_outcome_events
  add column if not exists old_effective_through_round_hole_snapshot_id uuid null,
  add column if not exists new_effective_through_round_hole_snapshot_id uuid null;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname='tournament_scorecard_round_outcomes_effective_through_hole_fkey'
  ) then
    alter table public.tournament_scorecard_round_outcomes
      add constraint tournament_scorecard_round_outcomes_effective_through_hole_fkey
      foreign key (effective_through_round_hole_snapshot_id)
      references public.tournament_round_hole_snapshots(id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='tournament_scorecard_round_outcome_events_old_through_hole_fkey'
  ) then
    alter table public.tournament_scorecard_round_outcome_events
      add constraint tournament_scorecard_round_outcome_events_old_through_hole_fkey
      foreign key (old_effective_through_round_hole_snapshot_id)
      references public.tournament_round_hole_snapshots(id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname='tournament_scorecard_round_outcome_events_new_through_hole_fkey'
  ) then
    alter table public.tournament_scorecard_round_outcome_events
      add constraint tournament_scorecard_round_outcome_events_new_through_hole_fkey
      foreign key (new_effective_through_round_hole_snapshot_id)
      references public.tournament_round_hole_snapshots(id);
  end if;
end $$;

comment on column public.tournament_scorecard_round_outcomes.effective_through_round_hole_snapshot_id is
'434: último hoyo congelado hasta el cual WD/DNF conserva aportaciones. NULL para DNS/DQ/NO_CARD. No implica continuidad: los huecos SIN SCORE anteriores siguen siendo huecos.';

-- RPC nueva y explícita. La RPC histórica permanece intacta para no romper consumidores.
create or replace function public.establecer_outcome_competitivo_tarjeta_434(
    p_score_card_id uuid,
    p_outcome_code text,
    p_reason text,
    p_effective_through_round_hole_snapshot_id uuid default null
) returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
    v_card record;
    v_admin_id uuid;
    v_new_code text;
    v_reason text;
    v_old_code text;
    v_old_hole uuid;
    v_hole record;
begin
    if auth.uid() is null then
        raise exception 'No autenticado.' using errcode='42501';
    end if;

    v_new_code:=upper(btrim(coalesce(p_outcome_code,'')));
    v_reason:=btrim(coalesce(p_reason,''));

    if v_new_code not in ('WD','DNF','DQ','DNS','NO_CARD') then
        raise exception 'outcome_code inválido. Permitidos: WD, DNF, DQ, DNS, NO_CARD.' using errcode='22023';
    end if;
    if length(v_reason)<5 then
        raise exception 'El motivo debe tener al menos 5 caracteres.' using errcode='22023';
    end if;

    select sc.id,sc.tournament_id,sc.tournament_round_id,sc.tournament_registration_id,
           sc.player_id,sc.status
      into v_card
      from public.tournament_score_cards sc
     where sc.id=p_score_card_id
     for update;

    if v_card.id is null then
        raise exception 'La tarjeta indicada no existe.' using errcode='22023';
    end if;
    if v_card.status<>'issued' then
        raise exception 'Sólo puede establecerse outcome sobre una tarjeta emitida.' using errcode='55000';
    end if;
    if not public.puede_administrar_congelamiento_torneo(v_card.tournament_id) then
        raise exception 'No tienes permiso administrativo para modificar esta tarjeta.' using errcode='42501';
    end if;

    if v_new_code in ('WD','DNF') then
        if p_effective_through_round_hole_snapshot_id is null then
            raise exception 'WD/DNF requiere indicar el último hoyo válido.' using errcode='22023';
        end if;
        select h.id,h.tournament_round_id,h.hole_number
          into v_hole
          from public.tournament_round_hole_snapshots h
         where h.id=p_effective_through_round_hole_snapshot_id;
        if v_hole.id is null or v_hole.tournament_round_id is distinct from v_card.tournament_round_id then
            raise exception 'El último hoyo válido no pertenece a la ronda de la tarjeta.' using errcode='22023';
        end if;
    else
        if p_effective_through_round_hole_snapshot_id is not null then
            raise exception 'DNS/DQ/NO_CARD no admite último hoyo válido.' using errcode='22023';
        end if;
    end if;

    v_admin_id:=public._scorecard_current_admin_id();
    if v_admin_id is null then
        raise exception 'El usuario autenticado no tiene un administrador activo asociado.' using errcode='42501';
    end if;

    select outcome_code,effective_through_round_hole_snapshot_id
      into v_old_code,v_old_hole
      from public.tournament_scorecard_round_outcomes
     where score_card_id=p_score_card_id;

    if v_old_code is not distinct from v_new_code
       and v_old_hole is not distinct from p_effective_through_round_hole_snapshot_id then
        return jsonb_build_object(
            'scoreCardId',p_score_card_id,'outcomeCode',v_new_code,
            'effectiveThroughRoundHoleSnapshotId',p_effective_through_round_hole_snapshot_id,
            'changed',false
        );
    end if;

    insert into public.tournament_scorecard_round_outcomes(
        score_card_id,tournament_id,tournament_round_id,tournament_registration_id,player_id,
        outcome_code,reason,effective_at,effective_through_round_hole_snapshot_id,
        recorded_by_admin_user_id,created_at,updated_at
    ) values (
        v_card.id,v_card.tournament_id,v_card.tournament_round_id,v_card.tournament_registration_id,
        v_card.player_id,v_new_code,v_reason,now(),p_effective_through_round_hole_snapshot_id,
        v_admin_id,now(),now()
    )
    on conflict(score_card_id) do update set
        outcome_code=excluded.outcome_code,
        reason=excluded.reason,
        effective_at=now(),
        effective_through_round_hole_snapshot_id=excluded.effective_through_round_hole_snapshot_id,
        recorded_by_admin_user_id=excluded.recorded_by_admin_user_id,
        updated_at=now();

    insert into public.tournament_scorecard_round_outcome_events(
        score_card_id,tournament_id,tournament_round_id,
        old_outcome_code,new_outcome_code,reason,actor_admin_user_id,
        old_effective_through_round_hole_snapshot_id,
        new_effective_through_round_hole_snapshot_id
    ) values (
        v_card.id,v_card.tournament_id,v_card.tournament_round_id,
        v_old_code,v_new_code,v_reason,v_admin_id,
        v_old_hole,p_effective_through_round_hole_snapshot_id
    );

    return jsonb_build_object(
        'scoreCardId',v_card.id,
        'tournamentId',v_card.tournament_id,
        'tournamentRoundId',v_card.tournament_round_id,
        'oldOutcomeCode',v_old_code,
        'outcomeCode',v_new_code,
        'effectiveThroughRoundHoleSnapshotId',p_effective_through_round_hole_snapshot_id,
        'changed',true
    );
end;
$$;

-- -----------------------------------------------------------------------------
-- 2. Registro del motor de salida Stableford TEAM (Shotgun).
--    La participación competitiva es equipo, pero la unidad de tarjeta es registration.
-- -----------------------------------------------------------------------------
insert into public.tournament_start_engine_registry(
    start_format,participation_type,scoring_engine,
    preparation_engine,validation_engine,contract_version,activo,
    supports_scorecard_emission,scorecard_unit_type,scorecard_emission_engine,
    supports_start_validation,start_validation_handler
)
select
    'shotgun'::public.formato_salida_ronda,'equipo','stableford',
    'shotgun_team_v1','stableford_team_shotgun_v1',2,true,
    true,'registration','official_scorecard_registration_v1',
    true,'shotgun_team_v1'
where not exists (
    select 1 from public.tournament_start_engine_registry r
    where r.start_format::text='shotgun'
      and r.participation_type='equipo'
      and r.scoring_engine='stableford'
);

-- -----------------------------------------------------------------------------
-- 3. Contrato de salida Stableford TEAM.
--    Los grupos contienen equipos, pero se expanden a una unidad registration por integrante.
--    teamId queda congelado en cada unidad para evitar depender de membresía mutable posterior.
-- -----------------------------------------------------------------------------
create or replace function public._construir_contrato_salida_stableford_team_shotgun_434(
    p_tournament_round_id uuid
) returns jsonb
language sql
security definer
set search_path=public,extensions
as $$
with ctx as (
    select tr.id round_id,tr.tournament_id,f.id freeze_id,rcs.id round_condition_snapshot_id,
           tr.numero_ronda,tr.fecha,tr.formato_salida::text start_format,
           rcs.format_code,rcs.format_name,rcs.participation_type,rcs.scoring_engine
      from public.tournament_rounds tr
      join public.tournament_condition_freezes f on f.tournament_id=tr.tournament_id
      join public.tournament_round_condition_snapshots rcs
        on rcs.freeze_id=f.id and rcs.tournament_round_id=tr.id
     where tr.id=p_tournament_round_id
),
group_rows as (
    select g.id group_id,cfg.id config_id,rs.id shift_id,sc.id shift_category_id,
           sc.tournament_category_id,sh.id format_slot_id,sh.hoyo_id,hole.hole_number,
           g.posicion_salida,g.hora_salida,rs.numero_turno,rs.hora_salida shift_time,
           g.etiqueta,cfg.tamano_grupo_normal,cfg.tamano_grupo_maximo
      from ctx
      join public.tournament_round_shifts rs on rs.tournament_round_id=ctx.round_id and rs.activo
      join public.tournament_round_shift_categories sc on sc.tournament_round_shift_id=rs.id and sc.activo
      join public.tournament_shotgun_category_configs cfg on cfg.tournament_round_shift_category_id=sc.id and cfg.activo
      join public.tournament_shotgun_category_holes sh on sh.tournament_shotgun_category_config_id=cfg.id and sh.activo
      join public.tournament_groups g on g.tournament_shotgun_category_hole_id=sh.id and g.tournament_round_shift_id=rs.id and g.activo
      join public.tournament_round_hole_snapshots hole on hole.tournament_round_id=ctx.round_id and hole.source_hole_id=sh.hoyo_id
),
member_rows as (
    select gr.*,gt.tournament_team_id team_id,gt.orden_en_grupo team_order,
           reg.id registration_id,reg.player_id,reg.folio,
           concat_ws(' ',p.nombres,p.apellidos) player_name,
           rhs.handicap_snapshot_id,rhs.id round_handicap_snapshot_id,
           row_number() over(partition by gr.group_id order by gt.orden_en_grupo nulls last,gt.tournament_team_id,p.apellidos,p.nombres,reg.id)::integer order_in_group
      from group_rows gr
      join public.tournament_group_teams gt on gt.tournament_group_id=gr.group_id and gt.activo=true
      join public.tournament_teams tt on tt.id=gt.tournament_team_id and tt.activo=true
      join public.tournament_registrations reg
        on reg.tournament_team_id=tt.id and reg.tournament_id=(select tournament_id from ctx) and reg.activo=true
      join public.players p on p.id=reg.player_id
      left join public.tournament_round_handicap_snapshots rhs
        on rhs.tournament_round_id=p_tournament_round_id
       and rhs.tournament_registration_id=reg.id
       and rhs.player_id=reg.player_id
     where tt.tournament_category_id=gr.tournament_category_id
),
groups_json as (
    select coalesce(jsonb_agg(
        jsonb_build_object(
            'sourceGroupId',gr.group_id,'sourceConfigId',gr.config_id,
            'sourceShiftId',gr.shift_id,'sourceShiftCategoryId',gr.shift_category_id,
            'tournamentCategoryId',gr.tournament_category_id,
            'categoryName',(select c.nombre from public.tournament_categories tc join public.categories c on c.id=tc.category_id where tc.id=gr.tournament_category_id limit 1),
            'sourceFormatSlotId',gr.format_slot_id,'sourceHoleId',gr.hoyo_id,
            'holeNumber',gr.hole_number,'startAt',gr.hora_salida,'startPosition',gr.posicion_salida,
            'shiftNumber',gr.numero_turno,'shiftTime',gr.shift_time,'groupLabel',gr.etiqueta,
            'normalSize',gr.tamano_grupo_normal,'maximumSize',gr.tamano_grupo_maximo,
            'units',coalesce((
                select jsonb_agg(jsonb_build_object(
                    'unitType','registration','registrationId',m.registration_id,
                    'teamId',m.team_id,'playerId',m.player_id,'name',m.player_name,'folio',m.folio,
                    'orderInGroup',m.order_in_group,
                    'handicapSnapshotId',m.handicap_snapshot_id,
                    'roundHandicapSnapshotId',m.round_handicap_snapshot_id
                ) order by m.order_in_group,m.registration_id)
                from member_rows m where m.group_id=gr.group_id
            ),'[]'::jsonb),
            'formatMetadata',jsonb_build_object('startFormat','shotgun','sourceShotgunHoleId',gr.format_slot_id,'startPosition',gr.posicion_salida)
        ) order by gr.numero_turno,gr.hole_number,gr.posicion_salida,gr.group_id
    ),'[]'::jsonb) data
    from group_rows gr
)
select jsonb_build_object(
    'schemaVersion',2,'contract','tee_central_round_start','contractVersion',2,
    'preparationEngine','shotgun_team_v1','validationEngine','stableford_team_shotgun_v1',
    'freezeId',ctx.freeze_id,'roundConditionSnapshotId',ctx.round_condition_snapshot_id,
    'tournament',jsonb_build_object('id',ctx.tournament_id),
    'round',jsonb_build_object('id',ctx.round_id,'number',ctx.numero_ronda,'date',ctx.fecha,'startFormat',ctx.start_format),
    'format',jsonb_build_object('code',ctx.format_code,'name',ctx.format_name,'participationType',ctx.participation_type,'scoringEngine',ctx.scoring_engine),
    'groups',gj.data
)
from ctx cross join groups_json gj;
$$;

-- Dispatcher: conserva motores existentes y agrega sólo Stableford TEAM Shotgun.
create or replace function public._construir_contrato_salida_ronda(p_tournament_round_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
    v_engine jsonb;
    v_start_format text;
    v_preparation_engine text;
    v_scoring_engine text;
    v_participation_type text;
begin
    v_engine:=public.obtener_motor_salida_ronda(p_tournament_round_id);
    if not coalesce((v_engine->>'supported')::boolean,false) then
        raise exception 'No existe un motor de salida activo para esta combinacion de formato, participacion y puntuacion.' using errcode='0A000',detail=v_engine::text;
    end if;
    v_start_format:=v_engine->>'startFormat';
    v_preparation_engine:=v_engine#>>'{engine,preparationEngine}';
    v_scoring_engine:=v_engine#>>'{format,scoringEngine}';
    v_participation_type:=v_engine#>>'{format,participationType}';

    if v_start_format='shotgun' and v_preparation_engine='shotgun_v1' then
        return public._construir_contrato_salida_shotgun_v2(p_tournament_round_id);
    end if;
    if v_start_format='tee_times' and v_preparation_engine='tee_times_v1' then
        return public._construir_contrato_salida_tee_times_v1(p_tournament_round_id);
    end if;
    if v_start_format='shotgun' and v_preparation_engine='shotgun_team_v1' and v_scoring_engine='best_ball' then
        return public._construir_contrato_salida_best_ball_shotgun_v1(p_tournament_round_id);
    end if;
    if v_start_format='shotgun' and v_preparation_engine='shotgun_team_v1' and v_scoring_engine='team_stroke' then
        return public._construir_contrato_salida_shotgun_team_v1(p_tournament_round_id);
    end if;
    if v_start_format='shotgun' and v_preparation_engine='shotgun_team_v1'
       and v_scoring_engine='stableford' and v_participation_type='equipo' then
        return public._construir_contrato_salida_stableford_team_shotgun_434(p_tournament_round_id);
    end if;

    raise exception 'El motor de preparacion % para formato % y scoring % todavia no tiene constructor implementado.',
        coalesce(v_preparation_engine,'NULL'),coalesce(v_start_format,'NULL'),coalesce(v_scoring_engine,'NULL')
        using errcode='0A000',detail=v_engine::text;
end;
$$;

-- -----------------------------------------------------------------------------
-- 4. Núcleo Stableford por tarjeta reutilizable en individual y TEAM.
--    No cambia la RPC histórica individual.
-- -----------------------------------------------------------------------------
create or replace function public.obtener_resultado_stableford_tarjeta_434(p_score_card_id uuid)
returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
    v_official jsonb;
    v_card record;
    v_unit record;
    v_rhs public.tournament_round_handicap_snapshots;
    v_rcs public.tournament_round_condition_snapshots;
    v_engine public.tournament_stableford_engine_snapshots;
    v_holes_count integer;
    v_distinct_si integer;
    v_min_si integer;
    v_max_si integer;
    v_handicap_strokes_total integer;
    v_hio_points integer;
    v_classifications jsonb;
begin
    if auth.uid() is null then raise exception 'No autenticado.' using errcode='42501'; end if;
    v_official:=public.obtener_resultado_oficial_universal_tarjeta(p_score_card_id);

    select sc.id,sc.tournament_id,sc.tournament_round_id,sc.validation_id,sc.validation_unit_id,
           sc.card_number,sc.card_folio,sc.unit_type,sc.tournament_team_id
      into v_card from public.tournament_score_cards sc
     where sc.id=p_score_card_id and sc.status='issued' limit 1;

    select u.id,u.player_id,u.tournament_registration_id,u.tournament_team_id,u.tournament_category_id,
           u.unit_name,u.handicap_snapshot_id,u.round_handicap_snapshot_id
      into v_unit from public.tournament_round_start_validation_units u
     where u.id=v_card.validation_unit_id and u.validation_id=v_card.validation_id limit 1;

    if v_unit.id is null or v_unit.round_handicap_snapshot_id is null then
        raise exception 'La tarjeta no tiene snapshot de hándicap de ronda.' using errcode='55000';
    end if;
    if v_card.unit_type<>'registration' or v_unit.tournament_registration_id is null or v_unit.player_id is null then
        raise exception 'Stableford requiere tarjeta individual de jugador.' using errcode='0A000';
    end if;

    select * into v_rhs from public.tournament_round_handicap_snapshots where id=v_unit.round_handicap_snapshot_id limit 1;
    if v_rhs.id is null then raise exception 'No existe el snapshot de hándicap de ronda.' using errcode='55000'; end if;
    select * into v_rcs from public.tournament_round_condition_snapshots where id=v_rhs.round_condition_snapshot_id limit 1;
    if v_rcs.id is null or v_rcs.scoring_engine<>'stableford' or v_rcs.participation_type not in ('individual','equipo') then
        raise exception 'Esta tarjeta no corresponde a una ronda Stableford soportada.' using errcode='0A000';
    end if;
    if v_rcs.participation_type='equipo' and coalesce(v_unit.tournament_team_id,v_card.tournament_team_id) is null then
        raise exception 'La tarjeta Stableford TEAM no tiene equipo congelado.' using errcode='55000';
    end if;

    select * into v_engine from public.tournament_stableford_engine_snapshots
     where freeze_id=v_rhs.freeze_id and tournament_round_id=v_card.tournament_round_id limit 1;
    if v_engine.id is null then raise exception 'La ronda Stableford no tiene snapshot de versión del motor.' using errcode='55000'; end if;

    select s.points into v_hio_points from public.tournament_stableford_special_rule_snapshots s
     where s.freeze_id=v_rhs.freeze_id and s.rule_code='HOLE_IN_ONE_OVERRIDE' and s.enabled=true and s.behavior='OVERRIDE' limit 1;

    select coalesce(jsonb_agg(s.tipo_resultado::text order by s.tipo_resultado::text),'[]'::jsonb)
      into v_classifications from public.tournament_category_classification_snapshots s
     where s.freeze_id=v_rhs.freeze_id and s.tournament_category_id=v_unit.tournament_category_id;

    with parsed as (select (h->>'strokeIndex')::integer stroke_index from jsonb_array_elements(v_official->'holes') h)
    select count(*),count(distinct stroke_index),min(stroke_index),max(stroke_index)
      into v_holes_count,v_distinct_si,v_min_si,v_max_si from parsed;
    if v_holes_count<=0 or v_distinct_si<>v_holes_count or v_min_si<>1 or v_max_si<>v_holes_count then
        raise exception 'El Stroke Index congelado no forma una secuencia completa 1..N.' using errcode='55000';
    end if;

    with parsed as (select (h->>'strokeIndex')::integer stroke_index from jsonb_array_elements(v_official->'holes') h)
    select sum(public.calcular_golpes_handicap_hoyo(v_rhs.playing_handicap,p.stroke_index,v_holes_count))
      into v_handicap_strokes_total from parsed p;
    if v_handicap_strokes_total is distinct from v_rhs.playing_handicap then
        raise exception 'La distribución por Stroke Index no suma el Playing Handicap.' using errcode='55000';
    end if;

    return (
      with parsed as (
        select (h->>'roundHoleSnapshotId')::uuid round_hole_snapshot_id,
               (h->>'holeNumber')::integer hole_number,(h->>'playSequence')::integer play_sequence,
               (h->>'par')::integer par,(h->>'strokeIndex')::integer stroke_index,
               h->>'officialResultType' official_result_type,
               nullif(h->>'officialGrossScore','')::integer official_gross_score,
               h->>'officialSource' official_source
          from jsonb_array_elements(v_official->'holes') h
      ), handicapped as (
        select p.*,public.calcular_golpes_handicap_hoyo(v_rhs.playing_handicap,p.stroke_index,v_holes_count) handicap_strokes from parsed p
      ), base_points as (
        select h.*,
          case when h.official_result_type='PICKUP' then 0
               when h.official_result_type='SCORE' then public.calcular_puntos_stableford_estandar(h.official_gross_score,h.par)
               else null end gross_points_base,
          case when h.official_result_type='PICKUP' then 0
               when h.official_result_type='SCORE' then public.calcular_puntos_stableford_estandar(h.official_gross_score-h.handicap_strokes,h.par)
               else null end net_points_base,
          (h.official_result_type='SCORE' and h.official_gross_score=1 and v_hio_points is not null) hio_override_applied
        from handicapped h
      ), final_points as (
        select b.*,
          case when b.hio_override_applied then v_hio_points else b.gross_points_base end gross_points,
          case when b.hio_override_applied then v_hio_points else b.net_points_base end net_points,
          case when b.official_result_type='SCORE' then b.official_gross_score-b.handicap_strokes else null end official_net_score
        from base_points b
      ), totals as (
        select coalesce(sum(gross_points),0)::integer gross_points_total,
               coalesce(sum(net_points),0)::integer net_points_total,
               count(*) filter(where official_result_type='PICKUP')::integer pickup_holes,
               count(*) filter(where hio_override_applied)::integer hio_overrides_applied
          from final_points
      )
      select jsonb_build_object(
        'scoreCard',v_official->'scoreCard',
        'team',jsonb_build_object('tournamentTeamId',coalesce(v_unit.tournament_team_id,v_card.tournament_team_id)),
        'engine',jsonb_build_object('engineSnapshotId',v_engine.id,'engineVersion',v_engine.engine_version,'pointsTableVersion',v_engine.points_table_version,'targetScoreBasis',v_engine.target_score_basis,'minimumPoints',v_engine.minimum_points,'maximumPoints',v_engine.maximum_points,'pickupPoints',v_engine.pickup_points),
        'classification',jsonb_build_object('configuredResultTypes',v_classifications,'grossEnabled',v_classifications?'gross','netEnabled',v_classifications?'neto'),
        'handicap',jsonb_build_object('roundHandicapSnapshotId',v_rhs.id,'playingHandicap',v_rhs.playing_handicap,'handicapStrokesTotal',v_handicap_strokes_total),
        'specialRules',jsonb_build_object('holeInOneOverrideEnabled',(v_hio_points is not null),'holeInOneOverridePoints',v_hio_points),
        'result',jsonb_build_object('ready',true,'holes',v_holes_count,'grossPointsTotal',t.gross_points_total,'netPointsTotal',t.net_points_total,'pickupHoles',t.pickup_holes,'holeInOneOverridesApplied',t.hio_overrides_applied),
        'holes',coalesce((select jsonb_agg(jsonb_build_object(
            'roundHoleSnapshotId',f.round_hole_snapshot_id,'holeNumber',f.hole_number,'playSequence',f.play_sequence,
            'par',f.par,'strokeIndex',f.stroke_index,'officialResultType',f.official_result_type,
            'officialGrossScore',f.official_gross_score,'officialSource',f.official_source,
            'handicapStrokes',f.handicap_strokes,'officialNetScore',f.official_net_score,
            'grossPointsBase',f.gross_points_base,'netPointsBase',f.net_points_base,
            'holeInOneOverrideApplied',f.hio_override_applied,'grossPoints',f.gross_points,'netPoints',f.net_points
        ) order by f.play_sequence,f.hole_number) from final_points f),'[]'::jsonb)
      ) from totals t
    );
end;
$$;

-- -----------------------------------------------------------------------------
-- 5. Agregador TEAM: mejor 1 por hoyo, Gross y Neto independientes.
--    SIN SCORE = no candidato; PICKUP = candidato válido con 0.
--    Empates de mejor aportación conservan todos los contribuyentes, cuentan una sola vez.
-- -----------------------------------------------------------------------------
create or replace function public.obtener_resultado_stableford_equipo_ronda_434(
    p_tournament_round_id uuid,
    p_tournament_team_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=public,extensions
as $$
declare
    v_round record;
    v_team record;
    v_rcs record;
    v_missing_boundary integer;
begin
    if auth.uid() is null then raise exception 'No autenticado.' using errcode='42501'; end if;
    select tr.id,tr.tournament_id,tr.numero_ronda,tr.fecha into v_round
      from public.tournament_rounds tr where tr.id=p_tournament_round_id and tr.activo=true;
    if v_round.id is null then raise exception 'La ronda indicada no existe o no está activa.' using errcode='22023'; end if;
    if not public.puede_administrar_congelamiento_torneo(v_round.tournament_id) then
        raise exception 'No tienes permiso administrativo para consultar este resultado.' using errcode='42501';
    end if;
    select tt.id,tt.nombre_equipo,tt.tournament_category_id into v_team
      from public.tournament_teams tt
     where tt.id=p_tournament_team_id and tt.tournament_id=v_round.tournament_id and tt.activo=true;
    if v_team.id is null then raise exception 'El equipo indicado no existe o no está activo en el torneo.' using errcode='22023'; end if;

    select rcs.id,rcs.participation_type,rcs.scoring_engine into v_rcs
      from public.tournament_round_condition_snapshots rcs
     where rcs.tournament_round_id=p_tournament_round_id
     order by rcs.created_at desc,rcs.id desc limit 1;
    if v_rcs.id is null or v_rcs.scoring_engine<>'stableford' or v_rcs.participation_type<>'equipo' then
        raise exception 'La ronda indicada no corresponde a Stableford por equipos.' using errcode='0A000';
    end if;

    select count(*) into v_missing_boundary
      from public.tournament_score_cards sc
      join public.tournament_scorecard_round_outcomes o on o.score_card_id=sc.id
     where sc.tournament_round_id=p_tournament_round_id
       and sc.tournament_team_id=p_tournament_team_id
       and sc.status='issued' and sc.unit_type='registration'
       and o.outcome_code in ('WD','DNF')
       and o.effective_through_round_hole_snapshot_id is null;
    if v_missing_boundary>0 then
        raise exception 'Hay WD/DNF sin último hoyo válido; no se puede calcular el resultado TEAM.' using errcode='23514';
    end if;

    return (
      with cards as (
        select sc.id score_card_id,sc.card_folio,sc.player_id,u.unit_name player_name,
               sc.tournament_registration_id,sc.tournament_team_id,
               o.outcome_code,o.effective_through_round_hole_snapshot_id,
               public.obtener_resultado_stableford_tarjeta_434(sc.id) sf
          from public.tournament_score_cards sc
          join public.tournament_round_start_validation_units u
            on u.id=sc.validation_unit_id and u.validation_id=sc.validation_id
          left join public.tournament_scorecard_round_outcomes o on o.score_card_id=sc.id
         where sc.tournament_round_id=p_tournament_round_id
           and sc.tournament_team_id=p_tournament_team_id
           and sc.status='issued' and sc.unit_type='registration'
      ), boundary as (
        select c.*,
               case when c.outcome_code in ('WD','DNF') then (
                   select (h->>'playSequence')::integer from jsonb_array_elements(c.sf->'holes') h
                    where (h->>'roundHoleSnapshotId')::uuid=c.effective_through_round_hole_snapshot_id limit 1
               ) else null end boundary_play_sequence
          from cards c
      ), player_holes as (
        select b.score_card_id,b.card_folio,b.player_id,b.player_name,b.tournament_registration_id,
               b.outcome_code,b.boundary_play_sequence,
               (h->>'roundHoleSnapshotId')::uuid round_hole_snapshot_id,
               (h->>'holeNumber')::integer hole_number,(h->>'playSequence')::integer play_sequence,
               h->>'officialResultType' result_type,
               nullif(h->>'grossPoints','')::integer gross_points,
               nullif(h->>'netPoints','')::integer net_points,
               case
                 when b.outcome_code in ('DNS','DQ','NO_CARD') then false
                 when b.outcome_code in ('WD','DNF') then (h->>'playSequence')::integer<=b.boundary_play_sequence
                 else true
               end outcome_eligible
          from boundary b cross join lateral jsonb_array_elements(b.sf->'holes') h
      ), eligible as (
        select * from player_holes
         where outcome_eligible=true and result_type in ('SCORE','PICKUP')
      ), holes as (
        select hs.id round_hole_snapshot_id,hs.hole_number
          from public.tournament_round_hole_snapshots hs
         where hs.tournament_round_id=p_tournament_round_id
      ), best as (
        select h.round_hole_snapshot_id,h.hole_number,
               max(e.gross_points) gross_points,max(e.net_points) net_points,
               count(e.score_card_id)>0 has_contribution
          from holes h left join eligible e on e.round_hole_snapshot_id=h.round_hole_snapshot_id
         group by h.round_hole_snapshot_id,h.hole_number
      ), detailed as (
        select b.*,
          coalesce((select jsonb_agg(jsonb_build_object('playerId',e.player_id,'playerName',e.player_name,'scoreCardId',e.score_card_id,'cardFolio',e.card_folio,'resultType',e.result_type,'points',e.gross_points) order by e.player_name,e.player_id)
                    from eligible e where e.round_hole_snapshot_id=b.round_hole_snapshot_id and e.gross_points=b.gross_points),'[]'::jsonb) gross_contributors,
          coalesce((select jsonb_agg(jsonb_build_object('playerId',e.player_id,'playerName',e.player_name,'scoreCardId',e.score_card_id,'cardFolio',e.card_folio,'resultType',e.result_type,'points',e.net_points) order by e.player_name,e.player_id)
                    from eligible e where e.round_hole_snapshot_id=b.round_hole_snapshot_id and e.net_points=b.net_points),'[]'::jsonb) net_contributors
        from best b
      )
      select jsonb_build_object(
        'supported',true,'applicable',true,
        'tournamentId',v_round.tournament_id,'tournamentRoundId',v_round.id,'roundNumber',v_round.numero_ronda,
        'tournamentTeamId',v_team.id,'teamName',v_team.nombre_equipo,'tournamentCategoryId',v_team.tournament_category_id,
        'scoringEngine','stableford','participationType','equipo','competitiveUnit','TEAM','selectionRule','BEST_1_PER_HOLE',
        'result',jsonb_build_object(
            'grossPointsTotal',(select coalesce(sum(coalesce(d.gross_points,0)),0)::integer from detailed d),
            'netPointsTotal',(select coalesce(sum(coalesce(d.net_points,0)),0)::integer from detailed d),
            'holesWithContribution',(select count(*)::integer from detailed d where d.has_contribution),
            'holesWithoutContribution',(select count(*)::integer from detailed d where not d.has_contribution)
        ),
        'members',coalesce((select jsonb_agg(jsonb_build_object('playerId',c.player_id,'playerName',c.player_name,'scoreCardId',c.score_card_id,'cardFolio',c.card_folio,'outcomeCode',c.outcome_code) order by c.player_name,c.player_id) from cards c),'[]'::jsonb),
        'holes',coalesce((select jsonb_agg(jsonb_build_object(
            'roundHoleSnapshotId',d.round_hole_snapshot_id,'holeNumber',d.hole_number,
            'hasContribution',d.has_contribution,
            'grossPoints',coalesce(d.gross_points,0),'netPoints',coalesce(d.net_points,0),
            'grossContributors',d.gross_contributors,'netContributors',d.net_contributors
        ) order by d.hole_number) from detailed d),'[]'::jsonb)
      )
    );
end;
$$;

-- Permisos: conservar patrón RPC para usuarios autenticados; la función valida autorización interna.
grant execute on function public.establecer_outcome_competitivo_tarjeta_434(uuid,text,text,uuid) to authenticated;
grant execute on function public.obtener_resultado_stableford_tarjeta_434(uuid) to authenticated;
grant execute on function public.obtener_resultado_stableford_equipo_ronda_434(uuid,uuid) to authenticated;

commit;
