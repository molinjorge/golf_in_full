-- 394-MIGRACION_PLANTILLA_MAESTRA_WORKFLOW_Y_PREFERENCIAS.sql
-- TEE CENTRAL
-- FUNDACIONAL / DESCRIPTIVA. NO sustituye el workflow vigente ni toca motores, reglas, autorizaciones o bloqueos.

BEGIN;

-- 1) Preferencias funcionales declarativas del torneo.
ALTER TABLE public.tournaments
  ADD COLUMN IF NOT EXISTS usar_tarjeta_digital boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS usar_estaciones_digitales_premios boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS workflow_template_version integer NOT NULL DEFAULT 1;

COMMENT ON COLUMN public.tournaments.usar_tarjeta_digital IS
  'Declaración funcional: se utilizará tarjeta digital para scores. No autoriza ni bloquea operaciones.';
COMMENT ON COLUMN public.tournaments.usar_estaciones_digitales_premios IS
  'Declaración funcional: se utilizarán estaciones digitales de premios especiales. Nunca bloquea el ciclo deportivo.';
COMMENT ON COLUMN public.tournaments.workflow_template_version IS
  'Versión de plantilla maestra usada como guía descriptiva del workflow. No es autoridad operativa.';

ALTER TABLE public.tournaments
  DROP CONSTRAINT IF EXISTS tournaments_workflow_template_version_ck;
ALTER TABLE public.tournaments
  ADD CONSTRAINT tournaments_workflow_template_version_ck CHECK (workflow_template_version > 0);

-- 2) Cabecera versionada de plantillas maestras.
CREATE TABLE IF NOT EXISTS public.workflow_master_templates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_code text NOT NULL,
  version integer NOT NULL,
  name text NOT NULL,
  description text,
  active boolean NOT NULL DEFAULT true,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workflow_master_templates_version_ck CHECK (version > 0),
  CONSTRAINT workflow_master_templates_code_version_uq UNIQUE (template_code, version)
);

-- 3) Nodos declarativos. NO contiene blocked_by ni SQL ejecutable.
CREATE TABLE IF NOT EXISTS public.workflow_master_nodes (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  template_id uuid NOT NULL REFERENCES public.workflow_master_templates(id) ON DELETE RESTRICT,
  code text NOT NULL,
  sequence_no integer NOT NULL,
  scope text NOT NULL,
  phase_code text NOT NULL,
  title text NOT NULL,
  description text,
  action_label text,
  navigation_target text,
  is_actionable boolean NOT NULL DEFAULT true,
  is_required boolean NOT NULL DEFAULT true,
  is_conditional boolean NOT NULL DEFAULT false,
  applicability_rule text NOT NULL DEFAULT 'ALWAYS',
  completion_rule text NOT NULL,
  parallel_group text,
  active boolean NOT NULL DEFAULT true,
  display_order integer NOT NULL,
  metadata jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  CONSTRAINT workflow_master_nodes_scope_ck CHECK (scope IN ('TOURNAMENT','ROUND')),
  CONSTRAINT workflow_master_nodes_sequence_ck CHECK (sequence_no > 0),
  CONSTRAINT workflow_master_nodes_display_ck CHECK (display_order > 0),
  CONSTRAINT workflow_master_nodes_code_uq UNIQUE (template_id, code),
  CONSTRAINT workflow_master_nodes_sequence_uq UNIQUE (template_id, sequence_no),
  CONSTRAINT workflow_master_nodes_display_uq UNIQUE (template_id, display_order)
);

COMMENT ON TABLE public.workflow_master_templates IS
  'Plantillas declarativas/versionadas del ciclo operativo. No autorizan ni bloquean acciones.';
COMMENT ON TABLE public.workflow_master_nodes IS
  'Orden y metadatos descriptivos del workflow. La aplicación conserva toda autoridad operativa.';

-- Defensa en profundidad: tablas maestras no son API de escritura del cliente.
ALTER TABLE public.workflow_master_templates ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.workflow_master_nodes ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON public.workflow_master_templates FROM anon, authenticated;
REVOKE ALL ON public.workflow_master_nodes FROM anon, authenticated;
GRANT SELECT ON public.workflow_master_templates, public.workflow_master_nodes TO authenticated;

DROP POLICY IF EXISTS workflow_master_templates_read_authenticated_394 ON public.workflow_master_templates;
CREATE POLICY workflow_master_templates_read_authenticated_394
ON public.workflow_master_templates FOR SELECT TO authenticated USING (true);

DROP POLICY IF EXISTS workflow_master_nodes_read_authenticated_394 ON public.workflow_master_nodes;
CREATE POLICY workflow_master_nodes_read_authenticated_394
ON public.workflow_master_nodes FOR SELECT TO authenticated USING (true);

-- 4) Plantilla estándar v1.
INSERT INTO public.workflow_master_templates(template_code,version,name,description,active,metadata)
VALUES (
  'TEE_CENTRAL_STANDARD',1,'TEE CENTRAL · Ciclo operativo estándar',
  'Plantilla descriptiva aprobada previa a 394. Plantilla=orden; Evidencia=realidad; Aplicación=autoridad; Asistente=guía.',
  true,
  jsonb_build_object(
    'architecture','MASTER_TEMPLATE_V1',
    'assistant_role','GUIDE_ONLY',
    'terminal_states',jsonb_build_array('finalizado','cancelado','vencido'),
    'expired_evidence','torneo_esta_vencido_295',
    'sports_authority','APPLICATION',
    'special_prizes_block_sports',false,
    'capture_close_is_single_formal_close',true
  )
)
ON CONFLICT (template_code,version) DO UPDATE
SET name=EXCLUDED.name,
    description=EXCLUDED.description,
    active=EXCLUDED.active,
    metadata=EXCLUDED.metadata,
    updated_at=now();

-- 5) Reemplazo idempotente de los nodos de ESTA plantilla/version.
DELETE FROM public.workflow_master_nodes n
USING public.workflow_master_templates t
WHERE n.template_id=t.id
  AND t.template_code='TEE_CENTRAL_STANDARD'
  AND t.version=1;

WITH t AS (
  SELECT id FROM public.workflow_master_templates
  WHERE template_code='TEE_CENTRAL_STANDARD' AND version=1
)
INSERT INTO public.workflow_master_nodes(
  template_id,code,sequence_no,scope,phase_code,title,description,action_label,navigation_target,
  is_actionable,is_required,is_conditional,applicability_rule,completion_rule,parallel_group,active,display_order,metadata
)
SELECT t.id,v.code,v.seq,v.scope,v.phase,v.title,v.description,v.action_label,v.nav,
       v.actionable,v.required,v.conditional,v.app_rule,v.complete_rule,v.parallel_group,true,v.display_order,v.metadata
FROM t
CROSS JOIN (VALUES
 ('CONFIGURATION',10,'TOURNAMENT','SETUP','Configurar datos generales','Información general y preferencias funcionales del torneo.','Revisar datos generales','configuracion',true,true,false,'ALWAYS','TOURNAMENT_CONFIGURATION_COMPLETE',NULL,1,'{}'::jsonb),
 ('HANDICAP_RANGES',20,'TOURNAMENT','SETUP','Configurar categorías / franjas HCP','Configurar categorías y elegibilidad HCP.','Configurar categorías','categorias',true,true,false,'ALWAYS','HANDICAP_RANGES_COMPLETE',NULL,2,'{}'::jsonb),
 ('TIEBREAK_CONFIGURATION',30,'TOURNAMENT','SETUP','Configurar desempates','Definir secuencia de desempates; resolución automática permanece silenciosa.','Configurar desempates','desempates',true,true,false,'ALWAYS','TIEBREAK_CONFIGURATION_COMPLETE',NULL,3,'{}'::jsonb),
 ('ROUND_STRUCTURE',40,'TOURNAMENT','SETUP','Configurar rondas','Crear/configurar la estructura real de rondas.','Configurar rondas','rondas',true,true,false,'ALWAYS','ROUND_STRUCTURE_COMPLETE',NULL,4,'{}'::jsonb),
 ('REGISTRATIONS_OPEN',50,'TOURNAMENT','REGISTRATIONS','Abrir inscripciones','Habilitar el periodo de inscripción mediante el proceso existente.','Abrir inscripciones','inscripciones',true,true,false,'ALWAYS','REGISTRATIONS_OPENED',NULL,5,'{}'::jsonb),
 ('REGISTRATIONS_CLOSE',60,'TOURNAMENT','REGISTRATIONS','Cerrar inscripciones','Cerrar el periodo de inscripción mediante el proceso existente.','Cerrar inscripciones','inscripciones',true,true,false,'ALWAYS','REGISTRATIONS_CLOSED',NULL,6,'{}'::jsonb),
 ('FREEZE',70,'TOURNAMENT','PRE_ROUND','Congelar condiciones','Congelar las condiciones deportivas mediante el proceso existente.','Congelar condiciones','configuracion',true,true,false,'ALWAYS','TOURNAMENT_FROZEN',NULL,7,'{}'::jsonb),
 ('ROUND_TEAM_HCP',80,'ROUND','PRE_ROUND','Configurar HCP de equipos','Aplica únicamente cuando la modalidad requiere HCP TEAM.','Configurar HCP de equipos','hcp-equipos',true,true,true,'TEAM_HCP_REQUIRED','TEAM_HCP_COMPLETE',NULL,8,'{}'::jsonb),
 ('ROUND_GROUPS',90,'ROUND','PRE_ROUND','Preparar grupos','Preparar conformación de grupos cuando aplique.','Preparar grupos','grupos',true,true,true,'WHEN_GROUPS_REQUIRED','ROUND_GROUPS_COMPLETE',NULL,9,'{}'::jsonb),
 ('ROUND_STARTS_PREPARE',100,'ROUND','PRE_ROUND','Preparar salidas','Preparar salidas hasta que la previsualización existente esté lista.','Preparar salidas','salidas',true,true,false,'ALWAYS','ROUND_STARTS_PREPARED',NULL,10,'{}'::jsonb),
 ('ROUND_STARTS_VALIDATE',110,'ROUND','PRE_ROUND','Validar y cerrar salidas','Validación formal de salidas existente.','Validar y cerrar salidas','salidas',true,true,false,'ALWAYS','ROUND_STARTS_VALIDATED',NULL,11,'{}'::jsonb),
 ('SCORECARD_EMISSION',120,'ROUND','PRE_ROUND','Emitir tarjetas','Emitir tarjetas mediante el proceso existente.','Emitir tarjetas','tarjetas',true,true,false,'ALWAYS','SCORECARDS_EMITTED',NULL,12,'{}'::jsonb),
 ('START_TOURNAMENT',130,'TOURNAMENT','PLAY','Iniciar torneo','Inicio único del torneo; distinto de iniciar cada ronda.','Iniciar torneo','operacion',true,true,false,'ALWAYS_ONCE','TOURNAMENT_STARTED',NULL,13,'{}'::jsonb),
 ('ROUND_START',140,'ROUND','PLAY','Iniciar ronda','Inicio formal de la ronda mediante iniciar_ronda_314.','Iniciar ronda','ronda',true,true,false,'ALWAYS','ROUND_STARTED',NULL,14,'{}'::jsonb),
 ('ROUND_DIGITAL_SCORING',150,'ROUND','PLAY','Juego / captura digital','Fase informativa de captura digital de scores cuando el torneo la utiliza.','Ir a captura digital','mis-tarjetas',false,false,true,'DIGITAL_SCORECARD_ENABLED','INFORMATIONAL_UNTIL_CAPTURE_CLOSE','SCORING',15,jsonb_build_object('informational',true,'formal_close','ROUND_CAPTURE_CLOSE')),
 ('ROUND_PHYSICAL_CAPTURE',160,'ROUND','CAPTURE','Capturar tarjetas físicas','Captura física y estados terminales conforme al proceso existente.','Capturar tarjetas físicas','captura-fisica',true,true,false,'ALWAYS','PHYSICAL_CAPTURE_COMPLETE','SCORING',16,'{}'::jsonb),
 ('ROUND_RECONCILIATION',170,'ROUND','CAPTURE','Conciliar tarjetas','Conciliación cuando existe tarjeta digital.','Conciliar tarjetas','captura-fisica',true,true,true,'DIGITAL_SCORECARD_ENABLED','RECONCILIATION_COMPLETE','SCORING',17,'{}'::jsonb),
 ('ROUND_CAPTURE_CLOSE',180,'ROUND','CAPTURE','Cerrar captura','Único cierre formal de captura de scores; cierra la etapa física y digital.','Revisar cierre de captura','captura-fisica',true,true,false,'ALWAYS','CAPTURE_CLOSED',NULL,18,jsonb_build_object('single_formal_capture_close',true)),
 ('ROUND_RESULTS',190,'ROUND','RESULTS','Revisar resultados','Resultados pueden consultarse provisionalmente conforme a las reglas existentes.','Revisar resultados','resultados',true,true,false,'ALWAYS','RESULTS_READY','RESULTS',19,jsonb_build_object('provisional_before_capture_close',true)),
 ('ROUND_TIEBREAK_EXCEPTION',200,'ROUND','RESULTS','Resolver desempate pendiente','Sólo aparece si persiste un desempate que requiere intervención.','Resolver desempate','desempates-ronda',true,true,true,'MANUAL_TIEBREAK_PENDING','NO_MANUAL_TIEBREAK_PENDING','RESULTS',20,jsonb_build_object('automatic_tiebreaks_silent',true)),
 ('ROUND_CATEGORY_CLOSURE',210,'ROUND','RESULTS','Cerrar categorías','Cierre formal de todas las categorías aplicables.','Cerrar categorías','resultados',true,true,false,'ALWAYS','ALL_CATEGORIES_CLOSED',NULL,21,jsonb_build_object('all_categories_required',true)),
 ('ROUND_RESULTS_PUBLICATION',220,'ROUND','RESULTS','Publicar resultados','Publicación formal de resultados por categorías.','Publicar resultados','resultados',true,true,false,'ALWAYS','RESULTS_PUBLISHED',NULL,22,'{}'::jsonb),
 ('ROUND_COMPETITIVE_CLOSE',230,'ROUND','CLOSE','Cerrar ronda','Cierre competitivo formal de la ronda.','Cerrar ronda','ronda',true,true,false,'ALWAYS','ROUND_CLOSED',NULL,23,'{}'::jsonb),
 ('ROUND_CUT',240,'ROUND','POST_ROUND','Aplicar corte','Aplica únicamente cuando existe una regla de corte activa después de la ronda.','Aplicar corte','corte',true,true,true,'CUT_REQUIRED','CUT_COMPLETE',NULL,24,'{}'::jsonb),
 ('TOURNAMENT_FINALIZATION',900,'TOURNAMENT','FINALIZATION','Finalizar torneo','Finalización formal del torneo mediante las reglas existentes.','Finalizar torneo','finalizacion',true,true,false,'ALWAYS','TOURNAMENT_FINALIZED',NULL,25,'{}'::jsonb)
) AS v(code,seq,scope,phase,title,description,action_label,nav,actionable,required,conditional,app_rule,complete_rule,parallel_group,display_order,metadata);

-- 6) Consulta descriptiva. No reconstruye ni modifica tournament_workflow_nodes.
CREATE OR REPLACE FUNCTION public.obtener_plantilla_workflow_394(p_tournament_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public','pg_temp'
AS $function$
DECLARE
  v_version integer;
  v_template_id uuid;
  v_terminal boolean := false;
  v_expired boolean := false;
  v_status text;
  v_digital boolean;
  v_prize_stations boolean;
  v_nodes jsonb;
BEGIN
  IF p_tournament_id IS NULL THEN
    RAISE EXCEPTION 'tournament_id es obligatorio.' USING ERRCODE='22023';
  END IF;

  SELECT workflow_template_version, estatus::text, usar_tarjeta_digital, usar_estaciones_digitales_premios
    INTO v_version,v_status,v_digital,v_prize_stations
    FROM public.tournaments
   WHERE id=p_tournament_id;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'Torneo no encontrado.' USING ERRCODE='P0002';
  END IF;

  -- Vencido usa evidencia existente; si la función no es accesible al invocador, no se fabrica estado.
  BEGIN
    v_expired := COALESCE(public.torneo_esta_vencido_295(p_tournament_id),false);
  EXCEPTION WHEN insufficient_privilege THEN
    v_expired := false;
  END;

  v_terminal := (v_status IN ('finalizado','cancelado')) OR v_expired;

  SELECT id INTO v_template_id
    FROM public.workflow_master_templates
   WHERE template_code='TEE_CENTRAL_STANDARD' AND version=v_version AND active=true;

  IF v_template_id IS NULL THEN
    RAISE EXCEPTION 'No existe plantilla activa TEE_CENTRAL_STANDARD versión %.',v_version USING ERRCODE='P0002';
  END IF;

  SELECT COALESCE(jsonb_agg(jsonb_build_object(
      'code',n.code,
      'sequenceNo',n.sequence_no,
      'scope',n.scope,
      'phaseCode',n.phase_code,
      'title',n.title,
      'description',n.description,
      'actionLabel',n.action_label,
      'navigationTarget',n.navigation_target,
      'isActionable',n.is_actionable,
      'isRequired',n.is_required,
      'isConditional',n.is_conditional,
      'applicabilityRule',n.applicability_rule,
      'completionRule',n.completion_rule,
      'parallelGroup',n.parallel_group,
      'metadata',n.metadata
    ) ORDER BY n.sequence_no),'[]'::jsonb)
    INTO v_nodes
    FROM public.workflow_master_nodes n
   WHERE n.template_id=v_template_id AND n.active=true;

  RETURN jsonb_build_object(
    'ok',true,
    'tournamentId',p_tournament_id,
    'templateCode','TEE_CENTRAL_STANDARD',
    'templateVersion',v_version,
    'tournamentStatus',v_status,
    'expired',v_expired,
    'assistantOperational',NOT v_terminal,
    'usarTarjetaDigital',v_digital,
    'usarEstacionesDigitalesPremios',v_prize_stations,
    'usarControlAccesoQr',(SELECT usar_control_acceso_qr FROM public.tournaments WHERE id=p_tournament_id),
    'nodes',v_nodes,
    'authority','APPLICATION',
    'assistantRole','GUIDE_ONLY'
  );
END;
$function$;

-- La función sólo lee datos. Se permite a usuarios autenticados; las tablas maestras permanecen sin acceso directo.
REVOKE ALL ON FUNCTION public.obtener_plantilla_workflow_394(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.obtener_plantilla_workflow_394(uuid) TO authenticated, service_role;
GRANT SELECT ON public.workflow_master_templates, public.workflow_master_nodes TO service_role;

-- 7) Invariantes de la migración. Si algo no coincide, rollback total.
DO $verify$
DECLARE
  v_template_id uuid;
  v_count integer;
BEGIN
  SELECT id INTO v_template_id FROM public.workflow_master_templates
   WHERE template_code='TEE_CENTRAL_STANDARD' AND version=1 AND active=true;
  IF v_template_id IS NULL THEN RAISE EXCEPTION '394: plantilla v1 no creada.'; END IF;

  SELECT count(*) INTO v_count FROM public.workflow_master_nodes WHERE template_id=v_template_id AND active=true;
  IF v_count<>25 THEN RAISE EXCEPTION '394: se esperaban 25 nodos y existen %.',v_count; END IF;

  IF EXISTS (SELECT 1 FROM public.workflow_master_nodes WHERE template_id=v_template_id AND code ILIKE '%PRIZE%') THEN
    RAISE EXCEPTION '394: premios/estaciones no deben formar parte del workflow deportivo.';
  END IF;

  IF NOT EXISTS (SELECT 1 FROM public.workflow_master_nodes WHERE template_id=v_template_id AND code='START_TOURNAMENT') THEN
    RAISE EXCEPTION '394: falta START_TOURNAMENT.';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.workflow_master_nodes WHERE template_id=v_template_id AND code='ROUND_CAPTURE_CLOSE') THEN
    RAISE EXCEPTION '394: falta ROUND_CAPTURE_CLOSE.';
  END IF;
END
$verify$;

COMMIT;
