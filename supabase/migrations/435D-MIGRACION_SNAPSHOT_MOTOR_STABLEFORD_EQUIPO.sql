-- 435D-MIGRACION_SNAPSHOT_MOTOR_STABLEFORD_EQUIPO.sql
-- TEE CENTRAL / GOLF IN FULL
-- OBJETIVO: congelar el mismo motor Stableford por jugador tanto para
-- Stableford individual como para STABLEFORD_EQUIPO y reparar freezes ya existentes.

BEGIN;

-- 1) Reparación segura de freezes Stableford TEAM ya existentes.
INSERT INTO public.tournament_stableford_engine_snapshots(
 freeze_id,tournament_id,tournament_round_id,round_condition_snapshot_id,
 engine_version,points_table_version,target_score_basis,
 minimum_points,maximum_points,pickup_points
)
SELECT rcs.freeze_id,rcs.tournament_id,rcs.tournament_round_id,rcs.id,
       'stableford_individual_v1','R21.1_STANDARD_V1','PAR',0,6,0
FROM public.tournament_round_condition_snapshots rcs
WHERE rcs.scoring_engine='stableford'
  AND (
       rcs.participation_type='individual'
       OR (rcs.participation_type='equipo' AND rcs.format_code='STABLEFORD_EQUIPO')
  )
ON CONFLICT (freeze_id,tournament_round_id) DO NOTHING;

-- 2) Corregir congelamientos futuros. Se conserva el cuerpo vigente y sólo se
-- amplía el filtro histórico participation_type='individual'.
DO $block$
DECLARE
  v_oid oid;
  v_def text;
BEGIN
  SELECT p.oid INTO v_oid
  FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
  WHERE n.nspname='public'
    AND p.proname='congelar_condiciones_y_handicaps_torneo'
    AND pg_get_function_identity_arguments(p.oid)='p_tournament_id uuid'
  LIMIT 1;

  IF v_oid IS NULL THEN
    RAISE EXCEPTION 'No existe congelar_condiciones_y_handicaps_torneo(uuid).';
  END IF;

  v_def:=pg_get_functiondef(v_oid);

  IF position('AND rcs.participation_type=''individual''' in v_def)=0 THEN
    RAISE EXCEPTION 'No se encontró el filtro Stableford individual esperado; no se modifica la función.';
  END IF;

  v_def:=replace(
    v_def,
    'AND rcs.participation_type=''individual''',
    'AND (rcs.participation_type=''individual'' OR (rcs.participation_type=''equipo'' AND rcs.format_code=''STABLEFORD_EQUIPO''))'
  );

  EXECUTE v_def;
END;
$block$;

COMMIT;
