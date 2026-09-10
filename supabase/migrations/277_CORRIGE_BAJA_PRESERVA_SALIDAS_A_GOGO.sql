-- ============================================================
-- TEE CENTRAL / GOLF IN FULL
-- MIGRACION 277
-- Correccion de la baja 276: conservar salidas validadas
-- hasta conocer la resolucion del equipo incompleto.
--
-- NO cambia la regla de baja, NO resuelve composicion,
-- NO recalcula HCP TEAM y NO modifica tarjetas/marcadores/salidas.
-- ============================================================

CREATE OR REPLACE FUNCTION public.dar_de_baja_jugador_a_gogo_276(
 p_registration_id uuid,
 p_reason text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
 v_reg public.tournament_registrations%ROWTYPE;
 v_t public.tournaments%ROWTYPE;
 v_team public.tournament_teams%ROWTYPE;
 v_admin_id uuid;
 v_freeze_id uuid;
 v_format record;
 v_change_id uuid;
 v_slot_id uuid;
 v_validated_rounds integer := 0;
 v_cards_issued boolean := false;
 v_remaining integer := 0;
 v_composition jsonb;
BEGIN
 IF auth.uid() IS NULL THEN
   RAISE EXCEPTION 'No autenticado.' USING ERRCODE='42501';
 END IF;
 IF length(btrim(COALESCE(p_reason,''))) < 5 THEN
   RAISE EXCEPTION 'El motivo de la baja debe contener al menos 5 caracteres.' USING ERRCODE='22023';
 END IF;

 SELECT * INTO v_reg FROM public.tournament_registrations
 WHERE id=p_registration_id FOR UPDATE;
 IF v_reg.id IS NULL OR NOT v_reg.activo THEN
   RAISE EXCEPTION 'La inscripcion no existe o ya esta inactiva.' USING ERRCODE='22023';
 END IF;
 IF v_reg.tournament_team_id IS NULL THEN
   RAISE EXCEPTION 'La inscripcion no pertenece a un equipo.' USING ERRCODE='23514';
 END IF;

 SELECT * INTO v_t FROM public.tournaments
 WHERE id=v_reg.tournament_id AND activo=true FOR UPDATE;
 IF v_t.id IS NULL THEN RAISE EXCEPTION 'El torneo no existe o esta inactivo.'; END IF;
 IF v_t.estatus::text IN ('en_curso','finalizado','cancelado') THEN
   RAISE EXCEPTION 'El torneo ya inicio o termino. La composicion competitiva ya no puede modificarse.' USING ERRCODE='55000';
 END IF;
 IF NOT public.puede_administrar_congelamiento_torneo(v_t.id) THEN
   RAISE EXCEPTION 'No tienes permiso para dar de baja integrantes de este torneo.' USING ERRCODE='42501';
 END IF;

 SELECT au.id INTO v_admin_id FROM public.admin_users au
 WHERE au.auth_user_id=auth.uid() AND au.activo=true ORDER BY au.id LIMIT 1;
 IF v_admin_id IS NULL THEN
   RAISE EXCEPTION 'El usuario autenticado no tiene un administrador activo asociado.' USING ERRCODE='42501';
 END IF;

 SELECT tf.code,tf.tipo_participacion::text participation_type,tf.scoring_engine::text scoring_engine
 INTO v_format FROM public.tournament_formats tf WHERE tf.id=v_t.tournament_format_id;
 IF v_format.code IS DISTINCT FROM 'A_GOGO'
    OR v_format.participation_type IS DISTINCT FROM 'equipo'
    OR v_format.scoring_engine IS DISTINCT FROM 'team_stroke' THEN
   RAISE EXCEPTION 'Este procedimiento solo aplica a A-Go-Go/team_stroke.' USING ERRCODE='22023';
 END IF;

 SELECT f.id INTO v_freeze_id FROM public.tournament_condition_freezes f
 WHERE f.tournament_id=v_t.id ORDER BY f.frozen_at DESC LIMIT 1;
 IF v_freeze_id IS NULL THEN
   RAISE EXCEPTION 'El torneo todavia no esta congelado; utiliza el flujo normal de composicion.' USING ERRCODE='55000';
 END IF;

 SELECT * INTO v_team FROM public.tournament_teams tt
 WHERE tt.id=v_reg.tournament_team_id AND tt.tournament_id=v_t.id AND tt.activo=true FOR UPDATE;
 IF v_team.id IS NULL THEN RAISE EXCEPTION 'El equipo ya no esta activo.' USING ERRCODE='55000'; END IF;

 PERFORM pg_advisory_xact_lock(hashtextextended(v_reg.id::text,277));
 PERFORM pg_advisory_xact_lock(hashtextextended(v_team.id::text,277));

 -- 277: se observa el estado operativo, pero NO se reabre ni altera.
 SELECT count(*)::integer INTO v_validated_rounds
 FROM public.tournament_round_start_validations v
 WHERE v.tournament_id=v_t.id
   AND v.status='validated'
   AND v.start_format='shotgun'
   AND v.participation_type='equipo'
   AND v.scoring_engine='team_stroke';

 v_cards_issued := EXISTS (
   SELECT 1 FROM public.tournament_score_card_emissions e
   WHERE e.tournament_id=v_t.id AND e.status='issued'
 );

 -- La baja real. El trigger 204 conserva su responsabilidad de
 -- invalidar HCP TEAM, pero las salidas/tarjetas quedan intactas.
 UPDATE public.tournament_registrations
 SET activo=false,motivo_baja=btrim(p_reason),fecha_baja=now(),dado_de_baja_por=v_admin_id
 WHERE id=v_reg.id;

 SELECT rs.id INTO v_slot_id FROM public.tournament_team_roster_slots rs
 WHERE rs.tournament_registration_id=v_reg.id AND rs.status<>'cancelled'
 ORDER BY rs.created_at LIMIT 1 FOR UPDATE;
 IF v_slot_id IS NOT NULL THEN
   UPDATE public.tournament_team_roster_slots
   SET status='cancelled',cancelled_at=now(),updated_at=now()
   WHERE id=v_slot_id;
 END IF;

 SELECT count(*)::integer INTO v_remaining
 FROM public.tournament_registrations tr
 WHERE tr.tournament_id=v_t.id AND tr.tournament_team_id=v_team.id AND tr.activo=true;

 INSERT INTO public.tournament_team_composition_changes(
  tournament_id,tournament_registration_id,player_id,replacement_player_id,
  change_type,old_team_id,new_team_id,reason,changed_by_admin_id,freeze_id,metadata
 ) VALUES (
  v_t.id,v_reg.id,v_reg.player_id,NULL,'player_withdrawal',v_team.id,v_team.id,
  btrim(p_reason),v_admin_id,v_freeze_id,
  jsonb_build_object(
   'phase','277_WITHDRAWAL_PRESERVE_STARTS',
   'postFreeze',true,
   'startTournamentBoundary',true,
   'remainingActiveMembers',v_remaining,
   'teamRequiresResolution',(v_remaining<2),
   'validatedRoundsPreserved',v_validated_rounds,
   'startsPreserved',true,
   'cardsWereIssued',v_cards_issued,
   'cardsPreservedPendingResolution',v_cards_issued,
   'rosterSlotCancelled',v_slot_id
  )
 ) RETURNING id INTO v_change_id;

 v_composition:=public.obtener_estado_equipos_incompletos_a_gogo_274(v_t.id);

 RETURN jsonb_build_object(
  'status','completed',
  'tournamentId',v_t.id,
  'teamId',v_team.id,
  'teamName',v_team.nombre_equipo,
  'changeId',v_change_id,
  'withdrawnRegistrationId',v_reg.id,
  'withdrawnPlayerId',v_reg.player_id,
  'remainingActiveMembers',v_remaining,
  'teamRequiresResolution',(v_remaining<2),
  'validatedRoundsPreserved',v_validated_rounds,
  'startsPreserved',true,
  'cardsWereIssued',v_cards_issued,
  'cardsPreservedPendingResolution',v_cards_issued,
  'composition',v_composition
 );
END;
$function$;

COMMENT ON FUNCTION public.dar_de_baja_jugador_a_gogo_276(uuid,text)
IS '276/277: baja administrativa A-Go-Go post-Freeze/pre-inicio; 277 conserva salidas validadas y tarjetas hasta que el organizador resuelva la composicion.';

REVOKE ALL ON FUNCTION public.dar_de_baja_jugador_a_gogo_276(uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION public.dar_de_baja_jugador_a_gogo_276(uuid,text) FROM anon;
GRANT EXECUTE ON FUNCTION public.dar_de_baja_jugador_a_gogo_276(uuid,text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.dar_de_baja_jugador_a_gogo_276(uuid,text) TO service_role;
