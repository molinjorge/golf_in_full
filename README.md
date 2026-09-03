# Migraciones de base de datos — Tee Central / GOLF IN FULL

Este documento conserva un registro breve de cada migración aplicada o preparada en el proyecto.

**Proyecto Supabase:** `GOLFING_FULL`  
**Aplicación:** las migraciones se ejecutan manualmente en Supabase, en orden.  
**Criterio del README:** una entrada por migración, sin repetir el SQL. Supabase es la fuente de verdad del esquema vivo.

## Orden de migraciones

| # | Qué hace |
|---|---|
| 001 | Crea la tabla maestra de jugadores con identificación, contacto y hándicap declarado/verificado. |
| 002 | Crea parámetros del sistema y la primera estructura de administradores/organizadores. |
| 003 | Rediseña permisos con catálogo de roles, asignaciones por club/torneo y helpers de autorización. |
| 004 | Agrega límites de asignación por rol, reglas para otorgarlos y auditoría genérica. |
| 005 | Permite activar/desactivar personas, roles y asignaciones sin borrarlos, dejando trazabilidad. |
| 006 | Impide borrar administradores con historial; obliga a desactivarlos. |
| 007 | Recrea triggers faltantes de jugadores, administradores, roles y asignaciones. |
| 008 | Crea clubes y torneos, activa relaciones pendientes y aplica RLS por rol. |
| 009 | Restringe teléfono y correo de clubes a usuarios autenticados. |
| 010 | Define RLS de jugadores: cada jugador ve/edita su perfil y administradores autorizados gestionan perfiles. |
| 011 | Agrega GRANT faltantes para que las políticas RLS puedan evaluarse correctamente. |
| 012 | Corrige recursión RLS haciendo seguros los helpers de autorización SECURITY DEFINER. |
| 013 | Crea geografía normalizada de países, estados y ciudades con huso horario. |
| 014 | Elimina ciudad/estado en texto libre de clubes y deja city_id como fuente normalizada. |
| 015 | Hace obligatorio city_id en clubes. |
| 016 | Crea catálogo amigable de husos horarios y lo vincula con ciudades. |
| 017 | Crea módulos y licencias por club para controlar contratación y vigencia. |
| 018 | Agrega formato de juego, modalidad, tamaño de equipo y categorías por torneo. |
| 019 | Agrega rangos opcionales de edad y hándicap a categorías. |
| 020 | Vincula automáticamente al confirmar correo un jugador con un perfil previamente registrado. |
| 021 | Agrega alta/baja lógica y auditoría a jugadores. |
| 022 | Reintenta en cada login la vinculación de perfiles pre-registrados. |
| 023 | Crea campos de golf por club con hoyos, timezone y coordenadas opcionales. |
| 024 | Crea marcas de salida, hoyos y distancias por marca. |
| 025 | Separa Course Rating y Slope por caballeros y damas. |
| 026 | Habilita PostGIS y coordenadas frente/centro/atrás del green. |
| 026A | Agrega helper RPC y vista para manejar coordenadas de green sin exponer PostGIS al frontend. |
| 027 | Estandariza categorías de marcas y calcula automáticamente su orden visual. |
| 028 | Crea vistas de resumen de par y yardaje por campo/marca. |
| 029 | Crea catálogo de formatos de torneo y define participación y scoring_engine. |
| 030 | Migra torneos al catálogo de formatos y elimina enums anteriores de modalidad. |
| 031 | Crea métodos/reglas de desempate, allowance por formato y overrides de rating/slope por torneo. |
| 032 | Crea rondas, herencia de formato/allowance y reglas de corte por categoría. |
| 033 | Crea turnos por ronda y cupo máximo por categoría. |
| 034 | Vincula el torneo con su campo de golf y valida pertenencia al club sede. |
| 035 | Agrega alta/baja lógica y auditoría a reglas de corte. |
| 036 | Incluye al organizador entre quienes pueden consultar/editar su torneo. |
| 037 | Agrega número de rondas planeadas al torneo. |
| 038 | Impide crear más rondas activas que las planeadas. |
| 039 | Agrega el estado de inscripción cerrada al ciclo de vida del torneo. |
| 040 | Define el orden estándar de presentación de métodos de desempate. |
| 041 | Agrega alta/baja lógica a reglas de desempate y libera posiciones al desactivarlas. |
| 042 | Agrega tarifa individual, tarifa por equipo completo y moneda. |
| 043 | Hace teléfono de jugador obligatorio/único y restringe su edición tras confirmar cuenta. |
| 044 | Reemplaza error técnico de teléfono duplicado por mensaje comprensible. |
| 045 | Corrige la detección de teléfono duplicado usando SECURITY DEFINER. |
| 046 | Crea información comercial/marketing del torneo. |
| 047 | Agrega ventana de fecha/hora válida para acceso por QR al torneo. |
| 048 | Crea inscripciones pagadas con QR, cupo por categoría y registro de intentos. |
| 049 | Crea pre-reservas separadas de inscripciones pagadas y unifica participantes para roster. |
| 050 | Permite confirmar una pre-reserva y convertirla en inscripción real sin perder historial. |
| 051 | Separa el catálogo de medios de pago de torneo del de licencias. |
| 052 | Crea payment_attempts genérico y procesamiento temporal/simulado de pagos. |
| 053 | Habilita pgcrypto para tokens y referencias aleatorias. |
| 054 | Corrige el uso de pgcrypto en el esquema extensions dentro de funciones seguras. |
| 055 | Agrega folio legible consecutivo por torneo a las inscripciones. |
| 056 | Agrega mensaje claro para inscripción duplicada. |
| 057 | Agrega bandera para evitar reenvío accidental del correo de confirmación. |
| 058 | Limita la visibilidad del organizador a jugadores relacionados con sus torneos. |
| 059 | Agrega hora de escopetazo a la información del torneo. |
| 060 | Crea solicitud de recibo deducible y referencia a constancia fiscal. |
| 061 | Crea bucket privado para constancias fiscales con permisos por jugador y administrador. |
| 062 | Corrige recursión RLS en visibilidad de jugadores para organizadores. |
| 063 | Registra desde el intento de pago la intención de solicitar recibo deducible. |
| 064 | Agrega datos de beneficencia al torneo y limita recibos deducibles a esos eventos. |
| 065 | Agrega Early Bird y cálculo server-side de tarifa vigente. |
| 066 | Amplía permisos sobre marketing y prepara validación de tarifa de socios. |
| 067 | Separa tarifa de socios de Early Bird y bloquea tarifas cuando ya existen inscripciones. |
| 068 | Permite perfiles incompletos en pre-registro y exige datos completos al inscribirse realmente. |
| 069 | Crea búsqueda acotada de jugador por teléfono para reservas telefónicas. |
| 070 | Crea reservas telefónicas para personas aún no registradas y su reconciliación posterior. |
| 071 | Crea vista unificada de pre-reservas y reservas telefónicas. |
| 072 | Exige perfil completo solo en inscripción real, no en pre-reserva. |
| 073 | Normaliza fecha límite de pago y la valida contra inicio del torneo. |
| 074 | Agrega bandera para evitar reenvío accidental de correo de pre-reserva. |
| 075 | Permite al jugador pagar en línea su propia pre-reserva pendiente. |
| 076 | Normaliza códigos de país telefónicos y agrega consentimiento de WhatsApp. |
| 077 | Crea plantillas/secuencias de desempate y método mexicano por hándicap. |
| 078 | Permite desempates distintos por categoría y por resultado Gross/Neto. |
| 079 | Crea equipos, vincula inscripciones a equipo y permite reasignar jugadores. |
| 080 | Simplifica torneos de categoría única usando la categoría real ÚNICA. |
| 081 | Permite que un jugador autenticado cree su propio equipo. |
| 082 | Agrega logo de torneo y bucket público controlado. |
| 083 | Propaga equipo a pre-reservas, reservas telefónicas y conversión a inscripción. |
| 084 | Corrige validación para permitir categoría NULL cuando corresponde. |
| 085 | Exige categoría desde la pre-reserva cuando el jugador todavía no tiene equipo. |
| 086 | Agrega club y número de membresía al jugador. |
| 087 | Restringe la edición de membresía al jugador o superadmin. |
| 088 | Aplica tarifa real de socio según club y membresía del jugador. |
| 089 | Valida cupo de equipo contando inscripciones, pre-reservas y reservas telefónicas sin doble conteo. |
| 090 | Hace obligatoria la fecha límite de pago para transferencias. |
| 091 | Asigna automáticamente marca de salida según categoría, franjas y hándicap. |
| 092 | Agrega orden de visualización a categorías. |
| 093 | Carga el orden estándar de categorías de Scratch/Premier hasta Damas y Única. |
| 094 | Evita reasignar categorías sin rango de hándicap definido. |
| 095 | Extiende la resolución de categoría para validar también por edad. |
| 096 | Blinda franjas de hándicap contra huecos/traslapes y consolida herencia de rangos. |
| 097 | Ajusta reglas de categorías y franjas para mantener consistencia en la asignación automática. |
| 098 | Refuerza la resolución de categoría/marca en escenarios de torneo con reglas especiales. |
| 099 | Corrige validaciones de elegibilidad y asignación derivadas de género, edad y hándicap. |
| 100 | Consolida reglas de inscripción para categorías y marcas de salida. |
| 101 | Refuerza consistencia entre categorías del torneo, rangos efectivos y selección del jugador. |
| 102 | Ajusta validaciones de inscripción y resolución automática para casos límite. |
| 103 | Consolida reglas de género y elegibilidad en categorías del torneo. |
| 104 | Ajusta el tratamiento de categorías Senior y su convivencia con categorías regulares. |
| 105 | Refuerza reglas de inscripción para evitar selecciones incompatibles. |
| 106 | Corrige la resolución de marca/categoría para conservar la configuración válida del torneo. |
| 107 | Ajusta reglas de cupo y elegibilidad en los distintos canales de inscripción. |
| 108 | Consolida controles de consistencia de inscripciones y reservas. |
| 109 | Refuerza sincronización de categoría, marca y equipo durante la inscripción. |
| 110 | Ajusta validaciones de cupo y duplicidad entre canales de participación. |
| 111 | Consolida reglas operativas para reservas, inscripciones y equipos. |
| 112 | Refuerza validaciones de datos deportivos usados al inscribir jugadores. |
| 113 | Ajusta comportamiento de categorías y marcas ante cambios de configuración. |
| 114 | Consolida reglas de elegibilidad antes del congelamiento del torneo. |
| 115 | Refuerza controles de integridad en inscripciones y pre-reservas. |
| 116 | Ajusta sincronización y validaciones de información competitiva del jugador. |
| 117 | Consolida reglas de categorías, equipos y cupos previas a la operación de rondas. |
| 118 | Refuerza validaciones de reservas/inscripciones para evitar estados inconsistentes. |
| 119 | Ajusta reglas de cortesías y capacidad relacionadas con participantes del torneo. |
| 120 | Consolida controles de cupo y participación para los distintos canales de alta. |
| 121 | Refuerza consistencia de categoría y marca en participantes ya registrados. |
| 122 | Ajusta validaciones administrativas sobre participantes y configuración deportiva. |
| 123 | Consolida reglas previas al cierre/congelamiento de inscripciones. |
| 124 | Refuerza integridad de equipos, categorías y reservas antes de preparar salidas. |
| 125 | Ajusta validaciones de inscripción y asignación para casos detectados en pruebas. |
| 126 | Consolida correcciones de elegibilidad/cupo previas al motor de rondas. |
| 127 | Refuerza consistencia final de categorías, marcas y participantes. |
| 128 | Cierra la etapa de correcciones de inscripción/configuración previa al motor operativo de salidas. |
| 129 | Inicia la infraestructura operativa de salidas por ronda. |
| 130 | Extiende la preparación de salidas y sus validaciones estructurales. |
| 131 | Consolida configuración de grupos/unidades para salidas. |
| 132 | Refuerza preparación y consistencia de salidas antes de validarlas. |
| 133 | Amplía el motor de preparación de salidas y su información operativa. |
| 134 | Ajusta validaciones y contratos de preparación de ronda. |
| 135 | Prepara la transición entre configuración deportiva y emisión de tarjetas. |
| 136 | Congela condiciones y hándicaps por ronda mediante snapshots inmutables. |
| 137 | Crea preview de tarjetas de Shotgun individual sin emitir identidad oficial. |
| 138 | Blinda secuencia de rondas y permite reactivar la siguiente ronda inactiva. |
| 139 | Permite a administradores ver rondas inactivas para poder reactivarlas. |
| 140 | Crea validación versionada de salidas, snapshot operativo y bloqueo hasta reapertura. |
| 141 | Corrige el validador para ignorar categorías vacías y arregla mensajes. |
| 142 | Agrega historial auditable de validaciones y reaperturas de salidas. |
| 143 | Refuerza bloqueo y consistencia de objetos de salida después de validar. |
| 144 | Consolida el contrato operativo de salidas validadas para etapas posteriores. |
| 145 | Prepara la emisión oficial de tarjetas a partir de una salida validada. |
| 146 | Extiende la preemisión/emisión y controles de tarjetas por ronda. |
| 147 | Refuerza identidad y trazabilidad de tarjetas oficiales. |
| 148 | Consolida controles de emisión y acceso a tarjetas. |
| 149 | Cierra la base operativa de tarjetas para iniciar captura de resultados. |
| 150 | Inicia captura de resultados por hoyo sobre tarjetas oficiales. |
| 151 | Extiende captura digital y controles de resultados por hoyo. |
| 152 | Consolida captura física/digital y reglas necesarias para conciliación. |
| 153 | Crea/fortalece conciliación entre evidencia física y digital. |
| 154 | Agrega resolución auditable de diferencias y disputas por hoyo. |
| 155 | Consolida resultado oficial por tarjeta a partir de evidencia conciliada. |
| 156 | Refuerza uso de snapshots de hándicap y condiciones en el resultado oficial. |
| 157 | Agrega estados terminales/outcomes competitivos del jugador. |
| 158 | Construye leaderboard oficial Gross/Neto sobre resultados oficiales. |
| 159 | Refuerza consistencia del leaderboard y cierre de resultados de ronda. |
| 160 | Crea motor de desempates aplicable a resultados oficiales. |
| 161 | Agrega resolución manual auditable de desempates. |
| 162 | Consolida estado competitivo/cierre de ronda después de desempates. |
| 163 | Inicia estructura de provisionamiento y estado comercial del torneo. |
| 164 | Extiende perfil comercial/fiscal y controles administrativos. |
| 165 | Consolida flujo de servicio/provisionamiento para torneos. |
| 166 | Crea infraestructura de invitaciones para organizadores. |
| 167 | Permite aceptar invitación administrativa con usuario autenticado y correo verificado. |
| 168 | Agrega trazabilidad de envío/reenvío de invitaciones administrativas. |
| 169 | Generaliza invitaciones para club_admin y tournament_organizer. |
| 170 | Agrega nombres/apellidos estructurados y firma canónica de aceptación administrativa. |
| 171 | Adapta provisionamiento para crear/asignar organizador con datos estructurados. |
| 172 | Hace que conciliación parta de snapshots; digital deja de ser requisito y física sigue obligatoria. |
| 173 | Hace que finalización/resolución partan de snapshots y solo bloqueen diferencias/disputas reales. |
| 174 | Hace oficiales los resultados desde snapshots, aceptando PHYSICAL_ONLY con tarjeta física completa. |
| 175 | Centraliza categorías elegibles: natural o superior, con reglas de género, edad y hándicap. |
| 176 | Agrega finalización/reapertura de configuración y control administrativo de liberación del torneo. |
| 177 | Agrega teléfono del organizador/administrador y su sincronización operativa. |
| 178 | Corrige y consolida RPC/flujo administrativo derivado de configuración y liberación. |
| 179 | Inicia adaptación del motor común para Stableford individual. |
| 180 | Extiende contratos de scoring y captura necesarios para Stableford. |
| 181 | Incorpora semántica Stableford en captura/resultados manteniendo infraestructura común. |
| 182 | Consolida fases iniciales de Stableford sobre tarjetas y conciliación existentes. |
| 183 | Extiende resultado oficial y operación Stableford sin crear pipeline paralelo. |
| 184 | Consolida leaderboard y reglas de clasificación Stableford. |
| 185 | Extiende desempates/operación Stableford reutilizando infraestructura común. |
| 186 Fase 1A | Crea clasificaciones competitivas Gross/Neto por categoría y snapshots inmutables. |
| 186 Fase 1B | Registra Stableford individual en motores comunes de salida Shotgun/Tee Times. |
| 186 Fases posteriores | Completa contratos universales de resultado de hoyo, PICKUP y piezas comunes necesarias para Stableford. |
| 187 | Continúa integración de Stableford en captura, conciliación y resultado oficial. |
| 188 | Consolida asistente operativo y contratos necesarios para el flujo Stableford. |
| 189 | Extiende leaderboard/resultado Stableford a nivel de ronda. |
| 190 | Consolida acumulación y comportamiento Stableford a nivel de torneo. |
| 191 | Ajusta dependencias operativas del asistente para trabajar con motores comunes. |
| 192 | Define contrato común de leaderboard por ronda para Stroke Play y Stableford. |
| 193 | Consolida implementación Stableford y su integración con infraestructura común. |
| 194 | Agrega estado/cierre competitivo por categoría. |
| 195 | Agrega publicación y reporte de resultados por categoría. |
| 196 | Inicia consolidación de clasificación competitiva Gross/Neto en el flujo oficial. |
| 197 | Extiende consumo de clasificación competitiva en resultados/leaderboards. |
| 198 Fase 2 | Integra clasificación competitiva en Stroke Play respetando Gross/Neto configurados. |
| 198 Fase 2A | Blinda funciones internas de Stroke Play relacionadas con clasificación competitiva. |
| 199 Fase 1B | Agrega capitán explícito y roster provisional por nombre/correo para A-Go-Go, con confirmación personal y bloqueo de duplicidades antes de reservar plaza. |
| 200 Fase 1C | Implementa pago de equipo completo A-Go-Go mediante una cobertura económica única: el capitán paga una sola vez, los integrantes confirmados se convierten a inscripción y los pendientes quedan cubiertos hasta confirmar personalmente. |
| 201 Fase 2A | Permite reasignar de forma controlada y auditada una inscripción A-Go-Go existente entre equipos después del freeze, sin relajar el congelamiento general ni modificar salidas ya validadas. |
| 202 Fase 2B | Implementa sustitución post-freeze de integrantes A-Go-Go sin cambiar identidades históricas: el saliente conserva su inscripción, el reemplazo confirma personalmente y recibe una nueva inscripción sin cobro adicional, con cobertura de equipo cuando aplica. |
| 203 Fase 3A | Crea el hándicap competitivo de equipo A-Go-Go separado de snapshots individuales, con configuración Gross-only/promedio porcentual/tabla por suma/WHS Scramble, versiones por ronda y evidencia auditable de cada integrante. |
| 204 Fase 3B | Añade vigencia automática al HCP competitivo de equipo: cambios de composición, Handicap Index, tee o configuración marcan la versión activa como obsoleta; expone estado MISSING/STALE/CURRENT y permite recálculo masivo por ronda. |
| 205 Fase 4A | Habilita formalmente salidas Shotgun A-Go-Go por equipo: registra el motor team_stroke, construye contrato común v2 con unitType=team, valida asignación única/categoría y exige HCP competitivo CURRENT; la emisión de tarjeta se mantiene deshabilitada hasta Fase 5. |
| 206 Fase 4B | Permite reacomodar un equipo A-Go-Go Shotgun después de validar salidas sin editar el snapshot histórico: el movimiento es localizado y atómico, la validación anterior queda histórica y se crea una nueva versión formal; se bloquea si ya existen tarjetas emitidas. |
| 207 Fase 4C | Permite reasignaciones y sustituciones de integrantes A-Go-Go después de validar salidas: reutiliza los flujos 201/202, recalcula HCP de equipos afectados y genera nuevas versiones formales de las rondas validadas de forma atómica; bloquea cambios si ya hay tarjetas emitidas. |
| 208 Fase 5 | Habilita tarjeta oficial A-Go-Go por equipo sobre tournament_score_cards: preview y emisión TEAM, snapshot imprimible con integrantes y versión exacta de HCP validado, firmas requeridas y consulta rápida de todas las tarjetas del mismo grupo; la captura por hoyo queda para Fase 6. |
| 209 Fase 6 | Habilita captura A-Go-Go sobre la infraestructura común: inicializa sesiones y un score por equipo/hoyo, asigna marcador de otro equipo, permite confirmar/disputar a integrantes del equipo, reutiliza captura física y conciliación y blinda que team_stroke nunca admita PICKUP. |
| 210 Fase 7 | Construye el resultado oficial A-Go-Go por equipo reutilizando la evidencia universal de física/conciliación: exige todos los hoyos SCORE y ambas firmas, toma el HCP congelado en la tarjeta, calcula Gross y Net y consume los snapshots comunes de clasificación Gross/Neto. |
| 211 Fase 8 | Construye el leaderboard A-Go-Go de ronda por equipos: consume resultados oficiales, ordena Gross/Neto ascendente según clasificación congelada, integra outcomes terminales, detecta empates pendientes y extiende el dispatcher operativo común declarando TEAM como unidad competitiva. |
| 212 Fase 9 | Implementa desempates A-Go-Go por equipo reutilizando reglas, métodos, evaluador y tablas comunes: soporta secuencias distintas para Gross/Neto, distribuye el Team Playing Handicap por Stroke Index para countback Neto, permite resolución manual por score_card_id y aplica finalRank al leaderboard. |
| 213 Fase 10 | Integra A-Go-Go al cierre competitivo, publicación y finalización comunes: extiende los gates de resultados y desempates para TEAM/team_stroke, preserva Stroke/Stableford y reutiliza sin tablas paralelas los cierres por categoría/ronda, publicaciones y sello final del torneo. |
| 214 Fase 11A | Completa la experiencia digital A-Go-Go para integrantes TEAM: visibilidad de tarjeta, apertura por QR, detalle/panel/mis rondas, confirmación/disputa por cualquier integrante y cambio administrativo de marker entre equipos, preservando el flujo individual existente. |
| 215 Fase 11B1 | Permite reasignaciones y sustituciones de integrantes después de emitir tarjetas A-Go-Go conservando el mismo score_card_id y folio: revalida salidas, recalcula HCP TEAM, actualiza el snapshot vigente con historial de revisiones y refresca markers afectados; además corrige los assignment_source TEAM. |
| 216 Fase 11B2 | Permite reacomodar un TEAM entre grupos/hoyos Shotgun después de emitir tarjetas, sólo antes del primer score en los grupos afectados: conserva score_card_id y emisión, crea nueva validación, sincroniza sesión de captura, recalcula la secuencia de la tarjeta movida y reconstruye únicamente los markers de origen/destino. |
| 217 Fase L2 | Completa el contrato de configuración HCP TEAM para frontend: lectura segura de método/porcentaje/rangos, reemplazo atómico de rangos y limpieza de rangos al abandonar el método por tabla, sin abrir SELECT directo a las tablas. |
| 218 | Adapta el congelamiento común a A-Go-Go/team_stroke: Handicap Allowance individual deja de ser requisito, el snapshot de ronda admite “no aplica” y no se fabrican Playing Handicaps individuales; Stroke Play y Stableford conservan su contrato. |
| 219 | Corrige las operaciones A-Go-Go post-freeze para localizar el congelamiento vigente por `frozen_at` en lugar de la columna inexistente `created_at`, sin cambiar contratos ni reglas funcionales. |
| 220 | Corrige la clasificación competitiva por categoría para registrar `created_by` con `admin_users.id` en lugar de `auth.uid()`, eliminando la violación de FK al guardar Gross/Neto/Both. |
| 221 | Corrige el trigger común de PICKUP para separar las ramas digital y física por tabla, evitando referencias a columnas inexistentes sin relajar el bloqueo de PICKUP en A-Go-Go. |
| 222 | Hace opcional `tournament_team_roster_slots.invited_by_player_id` para permitir sustituciones administrativas A-Go-Go en equipos sin capitán, preservando la autoría administrativa existente. |
| 223 | Agrega pago grupal parcial de 1–N plazas en torneos por equipos reutilizando roster y coberturas económicas, permite múltiples coberturas parciales por equipo y conserva intactos el pago individual y el pago de equipo completo. |
| 224 | Encapsula los helpers internos SECURITY DEFINER del pago grupal parcial, retirando ejecución directa a `anon` y `authenticated` sin cambiar la lógica ni los RPC públicos de la Migración 223. |
| 225 | Permite invitar a un jugador ya inscrito y pagado que aún está sin equipo; al aceptar, reutiliza su misma inscripción y la incorpora al equipo sin segundo cobro ni inscripción duplicada. |
| 226 | Crea de forma atómica un equipo nuevo de inscripción grupal sin capitán obligatorio y su plaza inicial “TÚ” como miembro confirmado, sin crear todavía inscripción ni pago. |
| 227 | Permite al iniciador de una inscripción grupal agregar plazas provisionales de terceros sin capitán obligatorio, enlazando jugadores existentes cuando corresponde y dejando personas nuevas pendientes de confirmación, sin crear inscripción ni pago. |
| 228 | Retira el permiso de ejecución del rol `anon` sobre los tres RPC de pago grupal, preservando `authenticated` y `service_role`, sin modificar lógica, firmas, tablas ni datos. |
| 229 | Corrige la resolución automática de categoría única al crear equipos, eliminando el uso incompatible de `min(uuid)` sin cambiar las reglas para torneos sin categoría, con categoría única o multicategoría. |
| 230 | Permite configurar desempates Gross y Neto simultáneamente para el mismo torneo/categoría/alcance, aislando el reemplazo por tipo de resultado y cerrando la ejecución anónima de la RPC de configuración. |
## Pendientes

### A-Go-Go / Scramble
- **Fase 11C:** E2E integral A-Go-Go sobre un torneo operativo preparado; crear correcciones posteriores sólo si la prueba real descubre fallas.
- Integrar en frontend la creación del equipo grupal y plaza inicial mediante la Migración 226 y las plazas provisionales de terceros mediante la Migración 227; después conectar el pago parcial 1–N de las Migraciones 223/224.
- Integrar en frontend el flujo de invitación/aceptación de jugadores ya inscritos y pagados sin equipo, usando el contrato de la Migración 225.
- Mantener y terminar de integrar en UI la opción de pago individual cuando la configuración del torneo lo permita.
- Best Ball y Shamble permanecen como motores separados.

### Generales
- Eliminar la función huérfana `validar_cupo_categoria()` reemplazada por `validar_cupo_categoria_cruzado()`.
- Agregar ciudades al catálogo conforme se incorporen clubes en nuevas localidades.
- Configurar SMTP personalizado de Supabase antes de operar con jugadores reales.
- Revisar el flujo de cambio de correo jugador ↔ Auth para exigir confirmación del nuevo correo.
- Soporte futuro para campos de 27+ hoyos con nueves combinables.
- Completar pantallas administrativas/club y licencias que sigan pendientes.
- Mantener pendientes los ajustes del motor de salidas que todavía requieran acomodación manual, balanceo o validación integral antes de tarjetas.

## Regla de mantenimiento

A partir de la siguiente migración, agregar **una sola entrada breve por migración** y actualizar **Pendientes** cuando corresponda. No incluir nombres de archivos SQL ni documentación exhaustiva del código en este README.
