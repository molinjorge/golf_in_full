# Migraciones de base de datos --- Tee Central / GOLF IN FULL

Este documento conserva un registro breve de cada migración aplicada o
preparada en el proyecto.

**Proyecto Supabase:** `GOLFING_FULL`\
**Aplicación:** las migraciones se ejecutan manualmente en Supabase, en
orden.\
**Criterio del README:** una entrada por migración, sin repetir el SQL.
Supabase es la fuente de verdad del esquema vivo.

## Orden de migraciones

  --------------------------------------------------------------------------
  \#                   Qué hace
  -------------------- -----------------------------------------------------
  001                  Crea la tabla maestra de jugadores con
                       identificación, contacto y hándicap
                       declarado/verificado.

  002                  Crea parámetros del sistema y la primera estructura
                       de administradores/organizadores.

  003                  Rediseña permisos con catálogo de roles, asignaciones
                       por club/torneo y helpers de autorización.

  004                  Agrega límites de asignación por rol, reglas para
                       otorgarlos y auditoría genérica.

  005                  Permite activar/desactivar personas, roles y
                       asignaciones sin borrarlos, dejando trazabilidad.

  006                  Impide borrar administradores con historial; obliga a
                       desactivarlos.

  007                  Recrea triggers faltantes de jugadores,
                       administradores, roles y asignaciones.

  008                  Crea clubes y torneos, activa relaciones pendientes y
                       aplica RLS por rol.

  009                  Restringe teléfono y correo de clubes a usuarios
                       autenticados.

  010                  Define RLS de jugadores: cada jugador ve/edita su
                       perfil y administradores autorizados gestionan
                       perfiles.

  011                  Agrega GRANT faltantes para que las políticas RLS
                       puedan evaluarse correctamente.

  012                  Corrige recursión RLS haciendo seguros los helpers de
                       autorización SECURITY DEFINER.

  013                  Crea geografía normalizada de países, estados y
                       ciudades con huso horario.

  014                  Elimina ciudad/estado en texto libre de clubes y deja
                       city_id como fuente normalizada.

  015                  Hace obligatorio city_id en clubes.

  016                  Crea catálogo amigable de husos horarios y lo vincula
                       con ciudades.

  017                  Crea módulos y licencias por club para controlar
                       contratación y vigencia.

  018                  Agrega formato de juego, modalidad, tamaño de equipo
                       y categorías por torneo.

  019                  Agrega rangos opcionales de edad y hándicap a
                       categorías.

  020                  Vincula automáticamente al confirmar correo un
                       jugador con un perfil previamente registrado.

  021                  Agrega alta/baja lógica y auditoría a jugadores.

  022                  Reintenta en cada login la vinculación de perfiles
                       pre-registrados.

  023                  Crea campos de golf por club con hoyos, timezone y
                       coordenadas opcionales.

  024                  Crea marcas de salida, hoyos y distancias por marca.

  025                  Separa Course Rating y Slope por caballeros y damas.

  026                  Habilita PostGIS y coordenadas frente/centro/atrás
                       del green.

  026A                 Agrega helper RPC y vista para manejar coordenadas de
                       green sin exponer PostGIS al frontend.

  027                  Estandariza categorías de marcas y calcula
                       automáticamente su orden visual.

  028                  Crea vistas de resumen de par y yardaje por
                       campo/marca.

  029                  Crea catálogo de formatos de torneo y define
                       participación y scoring_engine.

  030                  Migra torneos al catálogo de formatos y elimina enums
                       anteriores de modalidad.

  031                  Crea métodos/reglas de desempate, allowance por
                       formato y overrides de rating/slope por torneo.

  032                  Crea rondas, herencia de formato/allowance y reglas
                       de corte por categoría.

  033                  Crea turnos por ronda y cupo máximo por categoría.

  034                  Vincula el torneo con su campo de golf y valida
                       pertenencia al club sede.

  035                  Agrega alta/baja lógica y auditoría a reglas de
                       corte.

  036                  Incluye al organizador entre quienes pueden
                       consultar/editar su torneo.

  037                  Agrega número de rondas planeadas al torneo.

  038                  Impide crear más rondas activas que las planeadas.

  039                  Agrega el estado de inscripción cerrada al ciclo de
                       vida del torneo.

  040                  Define el orden estándar de presentación de métodos
                       de desempate.

  041                  Agrega alta/baja lógica a reglas de desempate y
                       libera posiciones al desactivarlas.

  042                  Agrega tarifa individual, tarifa por equipo completo
                       y moneda.

  043                  Hace teléfono de jugador obligatorio/único y
                       restringe su edición tras confirmar cuenta.

  044                  Reemplaza error técnico de teléfono duplicado por
                       mensaje comprensible.

  045                  Corrige la detección de teléfono duplicado usando
                       SECURITY DEFINER.

  046                  Crea información comercial/marketing del torneo.

  047                  Agrega ventana de fecha/hora válida para acceso por
                       QR al torneo.

  048                  Crea inscripciones pagadas con QR, cupo por categoría
                       y registro de intentos.

  049                  Crea pre-reservas separadas de inscripciones pagadas
                       y unifica participantes para roster.

  050                  Permite confirmar una pre-reserva y convertirla en
                       inscripción real sin perder historial.

  051                  Separa el catálogo de medios de pago de torneo del de
                       licencias.

  052                  Crea payment_attempts genérico y procesamiento
                       temporal/simulado de pagos.

  053                  Habilita pgcrypto para tokens y referencias
                       aleatorias.

  054                  Corrige el uso de pgcrypto en el esquema extensions
                       dentro de funciones seguras.

  055                  Agrega folio legible consecutivo por torneo a las
                       inscripciones.

  056                  Agrega mensaje claro para inscripción duplicada.

  057                  Agrega bandera para evitar reenvío accidental del
                       correo de confirmación.

  058                  Limita la visibilidad del organizador a jugadores
                       relacionados con sus torneos.

  059                  Agrega hora de escopetazo a la información del
                       torneo.

  060                  Crea solicitud de recibo deducible y referencia a
                       constancia fiscal.

  061                  Crea bucket privado para constancias fiscales con
                       permisos por jugador y administrador.

  062                  Corrige recursión RLS en visibilidad de jugadores
                       para organizadores.

  063                  Registra desde el intento de pago la intención de
                       solicitar recibo deducible.

  064                  Agrega datos de beneficencia al torneo y limita
                       recibos deducibles a esos eventos.

  065                  Agrega Early Bird y cálculo server-side de tarifa
                       vigente.

  066                  Amplía permisos sobre marketing y prepara validación
                       de tarifa de socios.

  067                  Separa tarifa de socios de Early Bird y bloquea
                       tarifas cuando ya existen inscripciones.

  068                  Permite perfiles incompletos en pre-registro y exige
                       datos completos al inscribirse realmente.

  069                  Crea búsqueda acotada de jugador por teléfono para
                       reservas telefónicas.

  070                  Crea reservas telefónicas para personas aún no
                       registradas y su reconciliación posterior.

  071                  Crea vista unificada de pre-reservas y reservas
                       telefónicas.

  072                  Exige perfil completo solo en inscripción real, no en
                       pre-reserva.

  073                  Normaliza fecha límite de pago y la valida contra
                       inicio del torneo.

  074                  Agrega bandera para evitar reenvío accidental de
                       correo de pre-reserva.

  075                  Permite al jugador pagar en línea su propia
                       pre-reserva pendiente.

  076                  Normaliza códigos de país telefónicos y agrega
                       consentimiento de WhatsApp.

  077                  Crea plantillas/secuencias de desempate y método
                       mexicano por hándicap.

  078                  Permite desempates distintos por categoría y por
                       resultado Gross/Neto.

  079                  Crea equipos, vincula inscripciones a equipo y
                       permite reasignar jugadores.

  080                  Simplifica torneos de categoría única usando la
                       categoría real ÚNICA.

  081                  Permite que un jugador autenticado cree su propio
                       equipo.

  082                  Agrega logo de torneo y bucket público controlado.

  083                  Propaga equipo a pre-reservas, reservas telefónicas y
                       conversión a inscripción.

  084                  Corrige validación para permitir categoría NULL
                       cuando corresponde.

  085                  Exige categoría desde la pre-reserva cuando el
                       jugador todavía no tiene equipo.

  086                  Agrega club y número de membresía al jugador.

  087                  Restringe la edición de membresía al jugador o
                       superadmin.

  088                  Aplica tarifa real de socio según club y membresía
                       del jugador.

  089                  Valida cupo de equipo contando inscripciones,
                       pre-reservas y reservas telefónicas sin doble conteo.

  090                  Hace obligatoria la fecha límite de pago para
                       transferencias.

  091                  Asigna automáticamente marca de salida según
                       categoría, franjas y hándicap.

  092                  Agrega orden de visualización a categorías.

  093                  Carga el orden estándar de categorías de
                       Scratch/Premier hasta Damas y Única.

  094                  Evita reasignar categorías sin rango de hándicap
                       definido.

  095                  Extiende la resolución de categoría para validar
                       también por edad.

  096                  Blinda franjas de hándicap contra huecos/traslapes y
                       consolida herencia de rangos.

  097                  Ajusta reglas de categorías y franjas para mantener
                       consistencia en la asignación automática.

  098                  Refuerza la resolución de categoría/marca en
                       escenarios de torneo con reglas especiales.

  099                  Corrige validaciones de elegibilidad y asignación
                       derivadas de género, edad y hándicap.

  100                  Consolida reglas de inscripción para categorías y
                       marcas de salida.

  101                  Refuerza consistencia entre categorías del torneo,
                       rangos efectivos y selección del jugador.

  102                  Ajusta validaciones de inscripción y resolución
                       automática para casos límite.

  103                  Consolida reglas de género y elegibilidad en
                       categorías del torneo.

  104                  Ajusta el tratamiento de categorías Senior y su
                       convivencia con categorías regulares.

  105                  Refuerza reglas de inscripción para evitar
                       selecciones incompatibles.

  106                  Corrige la resolución de marca/categoría para
                       conservar la configuración válida del torneo.

  107                  Ajusta reglas de cupo y elegibilidad en los distintos
                       canales de inscripción.

  108                  Consolida controles de consistencia de inscripciones
                       y reservas.

  109                  Refuerza sincronización de categoría, marca y equipo
                       durante la inscripción.

  110                  Ajusta validaciones de cupo y duplicidad entre
                       canales de participación.

  111                  Consolida reglas operativas para reservas,
                       inscripciones y equipos.

  112                  Refuerza validaciones de datos deportivos usados al
                       inscribir jugadores.

  113                  Ajusta comportamiento de categorías y marcas ante
                       cambios de configuración.

  114                  Consolida reglas de elegibilidad antes del
                       congelamiento del torneo.

  115                  Refuerza controles de integridad en inscripciones y
                       pre-reservas.

  116                  Ajusta sincronización y validaciones de información
                       competitiva del jugador.

  117                  Consolida reglas de categorías, equipos y cupos
                       previas a la operación de rondas.

  118                  Refuerza validaciones de reservas/inscripciones para
                       evitar estados inconsistentes.

  119                  Ajusta reglas de cortesías y capacidad relacionadas
                       con participantes del torneo.

  120                  Consolida controles de cupo y participación para los
                       distintos canales de alta.

  121                  Refuerza consistencia de categoría y marca en
                       participantes ya registrados.

  122                  Ajusta validaciones administrativas sobre
                       participantes y configuración deportiva.

  123                  Consolida reglas previas al cierre/congelamiento de
                       inscripciones.

  124                  Refuerza integridad de equipos, categorías y reservas
                       antes de preparar salidas.

  125                  Ajusta validaciones de inscripción y asignación para
                       casos detectados en pruebas.

  126                  Consolida correcciones de elegibilidad/cupo previas
                       al motor de rondas.

  127                  Refuerza consistencia final de categorías, marcas y
                       participantes.

  128                  Cierra la etapa de correcciones de
                       inscripción/configuración previa al motor operativo
                       de salidas.

  129                  Inicia la infraestructura operativa de salidas por
                       ronda.

  130                  Extiende la preparación de salidas y sus validaciones
                       estructurales.

  131                  Consolida configuración de grupos/unidades para
                       salidas.

  132                  Refuerza preparación y consistencia de salidas antes
                       de validarlas.

  133                  Amplía el motor de preparación de salidas y su
                       información operativa.

  134                  Ajusta validaciones y contratos de preparación de
                       ronda.

  135                  Prepara la transición entre configuración deportiva y
                       emisión de tarjetas.

  136                  Congela condiciones y hándicaps por ronda mediante
                       snapshots inmutables.

  137                  Crea preview de tarjetas de Shotgun individual sin
                       emitir identidad oficial.

  138                  Blinda secuencia de rondas y permite reactivar la
                       siguiente ronda inactiva.

  139                  Permite a administradores ver rondas inactivas para
                       poder reactivarlas.

  140                  Crea validación versionada de salidas, snapshot
                       operativo y bloqueo hasta reapertura.

  141                  Corrige el validador para ignorar categorías vacías y
                       arregla mensajes.

  142                  Agrega historial auditable de validaciones y
                       reaperturas de salidas.

  143                  Refuerza bloqueo y consistencia de objetos de salida
                       después de validar.

  144                  Consolida el contrato operativo de salidas validadas
                       para etapas posteriores.

  145                  Prepara la emisión oficial de tarjetas a partir de
                       una salida validada.

  146                  Extiende la preemisión/emisión y controles de
                       tarjetas por ronda.

  147                  Refuerza identidad y trazabilidad de tarjetas
                       oficiales.

  148                  Consolida controles de emisión y acceso a tarjetas.

  149                  Cierra la base operativa de tarjetas para iniciar
                       captura de resultados.

  150                  Inicia captura de resultados por hoyo sobre tarjetas
                       oficiales.

  151                  Extiende captura digital y controles de resultados
                       por hoyo.

  152                  Consolida captura física/digital y reglas necesarias
                       para conciliación.

  153                  Crea/fortalece conciliación entre evidencia física y
                       digital.

  154                  Agrega resolución auditable de diferencias y disputas
                       por hoyo.

  155                  Consolida resultado oficial por tarjeta a partir de
                       evidencia conciliada.

  156                  Refuerza uso de snapshots de hándicap y condiciones
                       en el resultado oficial.

  157                  Agrega estados terminales/outcomes competitivos del
                       jugador.

  158                  Construye leaderboard oficial Gross/Neto sobre
                       resultados oficiales.

  159                  Refuerza consistencia del leaderboard y cierre de
                       resultados de ronda.

  160                  Crea motor de desempates aplicable a resultados
                       oficiales.

  161                  Agrega resolución manual auditable de desempates.

  162                  Consolida estado competitivo/cierre de ronda después
                       de desempates.

  163                  Inicia estructura de provisionamiento y estado
                       comercial del torneo.

  164                  Extiende perfil comercial/fiscal y controles
                       administrativos.

  165                  Consolida flujo de servicio/provisionamiento para
                       torneos.

  166                  Crea infraestructura de invitaciones para
                       organizadores.

  167                  Permite aceptar invitación administrativa con usuario
                       autenticado y correo verificado.

  168                  Agrega trazabilidad de envío/reenvío de invitaciones
                       administrativas.

  169                  Generaliza invitaciones para club_admin y
                       tournament_organizer.

  170                  Agrega nombres/apellidos estructurados y firma
                       canónica de aceptación administrativa.

  171                  Adapta provisionamiento para crear/asignar
                       organizador con datos estructurados.

  172                  Hace que conciliación parta de snapshots; digital
                       deja de ser requisito y física sigue obligatoria.

  173                  Hace que finalización/resolución partan de snapshots
                       y solo bloqueen diferencias/disputas reales.

  174                  Hace oficiales los resultados desde snapshots,
                       aceptando PHYSICAL_ONLY con tarjeta física completa.

  175                  Centraliza categorías elegibles: natural o superior,
                       con reglas de género, edad y hándicap.

  176                  Agrega finalización/reapertura de configuración y
                       control administrativo de liberación del torneo.

  177                  Agrega teléfono del organizador/administrador y su
                       sincronización operativa.

  178                  Corrige y consolida RPC/flujo administrativo derivado
                       de configuración y liberación.

  179                  Inicia adaptación del motor común para Stableford
                       individual.

  180                  Extiende contratos de scoring y captura necesarios
                       para Stableford.

  181                  Incorpora semántica Stableford en captura/resultados
                       manteniendo infraestructura común.

  182                  Consolida fases iniciales de Stableford sobre
                       tarjetas y conciliación existentes.

  183                  Extiende resultado oficial y operación Stableford sin
                       crear pipeline paralelo.

  184                  Consolida leaderboard y reglas de clasificación
                       Stableford.

  185                  Extiende desempates/operación Stableford reutilizando
                       infraestructura común.

  186 Fase 1A          Crea clasificaciones competitivas Gross/Neto por
                       categoría y snapshots inmutables.

  186 Fase 1B          Registra Stableford individual en motores comunes de
                       salida Shotgun/Tee Times.

  186 Fases            Completa contratos universales de resultado de hoyo,
  posteriores          PICKUP y piezas comunes necesarias para Stableford.

  187                  Continúa integración de Stableford en captura,
                       conciliación y resultado oficial.

  188                  Consolida asistente operativo y contratos necesarios
                       para el flujo Stableford.

  189                  Extiende leaderboard/resultado Stableford a nivel de
                       ronda.

  190                  Consolida acumulación y comportamiento Stableford a
                       nivel de torneo.

  191                  Ajusta dependencias operativas del asistente para
                       trabajar con motores comunes.

  192                  Define contrato común de leaderboard por ronda para
                       Stroke Play y Stableford.

  193                  Consolida implementación Stableford y su integración
                       con infraestructura común.

  194                  Agrega estado/cierre competitivo por categoría.

  195                  Agrega publicación y reporte de resultados por
                       categoría.

  196                  Inicia consolidación de clasificación competitiva
                       Gross/Neto en el flujo oficial.

  197                  Extiende consumo de clasificación competitiva en
                       resultados/leaderboards.

  198 Fase 2           Integra clasificación competitiva en Stroke Play
                       respetando Gross/Neto configurados.

  198 Fase 2A          Blinda funciones internas de Stroke Play relacionadas
                       con clasificación competitiva.

  199 Fase 1B          Agrega capitán explícito y roster provisional por
                       nombre/correo para A-Go-Go, con confirmación personal
                       y bloqueo de duplicidades antes de reservar plaza.

  200 Fase 1C          Implementa pago de equipo completo A-Go-Go mediante
                       una cobertura económica única: el capitán paga una
                       sola vez, los integrantes confirmados se convierten a
                       inscripción y los pendientes quedan cubiertos hasta
                       confirmar personalmente.

  201 Fase 2A          Permite reasignar de forma controlada y auditada una
                       inscripción A-Go-Go existente entre equipos después
                       del freeze, sin relajar el congelamiento general ni
                       modificar salidas ya validadas.

  202 Fase 2B          Implementa sustitución post-freeze de integrantes
                       A-Go-Go sin cambiar identidades históricas: el
                       saliente conserva su inscripción, el reemplazo
                       confirma personalmente y recibe una nueva inscripción
                       sin cobro adicional, con cobertura de equipo cuando
                       aplica.

  203 Fase 3A          Crea el hándicap competitivo de equipo A-Go-Go
                       separado de snapshots individuales, con configuración
                       Gross-only/promedio porcentual/tabla por suma/WHS
                       Scramble, versiones por ronda y evidencia auditable
                       de cada integrante.

  204 Fase 3B          Añade vigencia automática al HCP competitivo de
                       equipo: cambios de composición, Handicap Index, tee o
                       configuración marcan la versión activa como obsoleta;
                       expone estado MISSING/STALE/CURRENT y permite
                       recálculo masivo por ronda.

  205 Fase 4A          Habilita formalmente salidas Shotgun A-Go-Go por
                       equipo: registra el motor team_stroke, construye
                       contrato común v2 con unitType=team, valida
                       asignación única/categoría y exige HCP competitivo
                       CURRENT; la emisión de tarjeta se mantiene
                       deshabilitada hasta Fase 5.

  206 Fase 4B          Permite reacomodar un equipo A-Go-Go Shotgun después
                       de validar salidas sin editar el snapshot histórico:
                       el movimiento es localizado y atómico, la validación
                       anterior queda histórica y se crea una nueva versión
                       formal; se bloquea si ya existen tarjetas emitidas.

  207 Fase 4C          Permite reasignaciones y sustituciones de integrantes
                       A-Go-Go después de validar salidas: reutiliza los
                       flujos 201/202, recalcula HCP de equipos afectados y
                       genera nuevas versiones formales de las rondas
                       validadas de forma atómica; bloquea cambios si ya hay
                       tarjetas emitidas.

  208 Fase 5           Habilita tarjeta oficial A-Go-Go por equipo sobre
                       tournament_score_cards: preview y emisión TEAM,
                       snapshot imprimible con integrantes y versión exacta
                       de HCP validado, firmas requeridas y consulta rápida
                       de todas las tarjetas del mismo grupo; la captura por
                       hoyo queda para Fase 6.

  209 Fase 6           Habilita captura A-Go-Go sobre la infraestructura
                       común: inicializa sesiones y un score por
                       equipo/hoyo, asigna marcador de otro equipo, permite
                       confirmar/disputar a integrantes del equipo,
                       reutiliza captura física y conciliación y blinda que
                       team_stroke nunca admita PICKUP.

  210 Fase 7           Construye el resultado oficial A-Go-Go por equipo
                       reutilizando la evidencia universal de
                       física/conciliación: exige todos los hoyos SCORE y
                       ambas firmas, toma el HCP congelado en la tarjeta,
                       calcula Gross y Net y consume los snapshots comunes
                       de clasificación Gross/Neto.

  211 Fase 8           Construye el leaderboard A-Go-Go de ronda por
                       equipos: consume resultados oficiales, ordena
                       Gross/Neto ascendente según clasificación congelada,
                       integra outcomes terminales, detecta empates
                       pendientes y extiende el dispatcher operativo común
                       declarando TEAM como unidad competitiva.

  212 Fase 9           Implementa desempates A-Go-Go por equipo reutilizando
                       reglas, métodos, evaluador y tablas comunes: soporta
                       secuencias distintas para Gross/Neto, distribuye el
                       Team Playing Handicap por Stroke Index para countback
                       Neto, permite resolución manual por score_card_id y
                       aplica finalRank al leaderboard.

  213 Fase 10          Integra A-Go-Go al cierre competitivo, publicación y
                       finalización comunes: extiende los gates de
                       resultados y desempates para TEAM/team_stroke,
                       preserva Stroke/Stableford y reutiliza sin tablas
                       paralelas los cierres por categoría/ronda,
                       publicaciones y sello final del torneo.

  214 Fase 11A         Completa la experiencia digital A-Go-Go para
                       integrantes TEAM: visibilidad de tarjeta, apertura
                       por QR, detalle/panel/mis rondas,
                       confirmación/disputa por cualquier integrante y
                       cambio administrativo de marker entre equipos,
                       preservando el flujo individual existente.

  215 Fase 11B1        Permite reasignaciones y sustituciones de integrantes
                       después de emitir tarjetas A-Go-Go conservando el
                       mismo score_card_id y folio: revalida salidas,
                       recalcula HCP TEAM, actualiza el snapshot vigente con
                       historial de revisiones y refresca markers afectados;
                       además corrige los assignment_source TEAM.

  216 Fase 11B2        Permite reacomodar un TEAM entre grupos/hoyos Shotgun
                       después de emitir tarjetas, sólo antes del primer
                       score en los grupos afectados: conserva score_card_id
                       y emisión, crea nueva validación, sincroniza sesión
                       de captura, recalcula la secuencia de la tarjeta
                       movida y reconstruye únicamente los markers de
                       origen/destino.

  217 Fase L2          Completa el contrato de configuración HCP TEAM para
                       frontend: lectura segura de método/porcentaje/rangos,
                       reemplazo atómico de rangos y limpieza de rangos al
                       abandonar el método por tabla, sin abrir SELECT
                       directo a las tablas.

  218                  Adapta el congelamiento común a A-Go-Go/team_stroke:
                       Handicap Allowance individual deja de ser requisito,
                       el snapshot de ronda admite "no aplica" y no se
                       fabrican Playing Handicaps individuales; Stroke Play
                       y Stableford conservan su contrato.

  219                  Corrige las operaciones A-Go-Go post-freeze para
                       localizar el congelamiento vigente por `frozen_at` en
                       lugar de la columna inexistente `created_at`, sin
                       cambiar contratos ni reglas funcionales.

  220                  Corrige la clasificación competitiva por categoría
                       para registrar `created_by` con `admin_users.id` en
                       lugar de `auth.uid()`, eliminando la violación de FK
                       al guardar Gross/Neto/Both.

  221                  Corrige el trigger común de PICKUP para separar las
                       ramas digital y física por tabla, evitando
                       referencias a columnas inexistentes sin relajar el
                       bloqueo de PICKUP en A-Go-Go.

  222                  Hace opcional
                       `tournament_team_roster_slots.invited_by_player_id`
                       para permitir sustituciones administrativas A-Go-Go
                       en equipos sin capitán, preservando la autoría
                       administrativa existente.

  223                  Agrega pago grupal parcial de 1--N plazas en torneos
                       por equipos reutilizando roster y coberturas
                       económicas, permite múltiples coberturas parciales
                       por equipo y conserva intactos el pago individual y
                       el pago de equipo completo.

  224                  Encapsula los helpers internos SECURITY DEFINER del
                       pago grupal parcial, retirando ejecución directa a
                       `anon` y `authenticated` sin cambiar la lógica ni los
                       RPC públicos de la Migración 223.

  225                  Permite invitar a un jugador ya inscrito y pagado que
                       aún está sin equipo; al aceptar, reutiliza su misma
                       inscripción y la incorpora al equipo sin segundo
                       cobro ni inscripción duplicada.

  226                  Crea de forma atómica un equipo nuevo de inscripción
                       grupal sin capitán obligatorio y su plaza inicial
                       "TÚ" como miembro confirmado, sin crear todavía
                       inscripción ni pago.

  227                  Permite al iniciador de una inscripción grupal
                       agregar plazas provisionales de terceros sin capitán
                       obligatorio, enlazando jugadores existentes cuando
                       corresponde y dejando personas nuevas pendientes de
                       confirmación, sin crear inscripción ni pago.

  228                  Retira el permiso de ejecución del rol `anon` sobre
                       los tres RPC de pago grupal, preservando
                       `authenticated` y `service_role`, sin modificar
                       lógica, firmas, tablas ni datos.

  229                  Corrige la resolución automática de categoría única
                       al crear equipos, eliminando el uso incompatible de
                       `min(uuid)` sin cambiar las reglas para torneos sin
                       categoría, con categoría única o multicategoría.

  230                  Permite configurar desempates Gross y Neto
                       simultáneamente para el mismo
                       torneo/categoría/alcance, aislando el reemplazo por
                       tipo de resultado y cerrando la ejecución anónima de
                       la RPC de configuración.

  231                  Impide congelar A-Go-Go/team_stroke con clasificación
                       Neto sin una configuración HCP TEAM válida; rechaza
                       GROSS_ONLY para Neto y exige rangos cuando se usa
                       ASSIGNED_TABLE_SUM_HI, preservando Gross-only y los
                       motores Stroke/Stableford.

  232                  Agrega una reparación excepcional, atómica y
                       auditable para freezes históricos A-Go-Go/team_stroke
                       con Neto creados sin HCP TEAM antes de la 231; sólo
                       opera si no existe ninguna evidencia competitiva y
                       recalcula las versiones TEAM sin modificar el freeze
                       ni sus snapshots.

  233                  Convierte `estatus=cancelado` en estado operativo de
                       sólo lectura: refuerza guards comunes y bloquea
                       mutaciones de configuración, inscripción, equipos,
                       salidas, tarjetas y captura competitiva sin alterar
                       `activo`, `estado_servicio`, pagos, freezes,
                       snapshots ni históricos.

  234                  Refuerza el congelamiento A-Go-Go con Neto exigiendo
                       HCP TEAM CURRENT para cada equipo activo en cada
                       ronda `team_stroke`; bloquea `MISSING`/`STALE` antes
                       del freeze sin impedir recálculos ni versionado
                       posteriores.

  235                  Incorpora `ROUND_GROUPS` al Asistente Operativo para
                       rondas Shotgun, distinguiendo PLAYER/TEAM y exigiendo
                       conformación completa antes de habilitar Salidas;
                       preserva sin cambios el flujo no-Shotgun.

  236                  Corrige el helper `ROUND_GROUPS` para tratar
                       `formato_salida = NULL` como no-Shotgun mediante
                       comparación NULL-safe, evitando falsos bloqueos en
                       rondas históricas Stableford sin alterar el flujo
                       Shotgun.

  237                  Corrige la capacidad Shotgun por equipos para medir
                       jugadores físicos activos ---no cantidad de
                       equipos--- y evita que `ROUND_GROUPS` quede COMPLETE
                       cuando existe sobrecupo físico; preserva individual,
                       no-Shotgun y el payload existente.

  238                  Enriquece la previsualización de tarjetas A-Go-Go
                       TEAM con contexto congelado de torneo/ronda/campo,
                       integrantes y marcas por jugador, PAR/HCP de hoyo y
                       yardajes por tee, sin inventar una tee o distancia
                       única del equipo ni alterar emisión/scoring.

  239                  Corrige el nombre de la marca en el preview A-Go-Go
                       TEAM usando como fallback el snapshot histórico del
                       mismo freeze/inscripción/jugador/tee cuando el
                       snapshot específico de ronda viene vacío; no usa
                       catálogo vivo ni fabrica color histórico.

  240                  Extiende el payload oficial común de tarjetas con
                       contrato A-Go-Go TEAM basado en la tarjeta/snapshot
                       oficial vigente, integrantes, HCP TEAM, salida y
                       yardajes por tee; preserva PLAYER y excluye QR de la
                       rama TEAM.

  241                  Agrega materialización administrativa de marcas de
                       salida faltantes para torneos de categoría única
                       antes del freeze, reutilizando prioridad Damas→Rojas,
                       Senior→Doradas y franjas por hándicap, sin
                       sobrescribir marcas ya asignadas ni relajar el
                       congelamiento.

  242                  Corrige vigencia de HCP TEAM ante cambios de marca de
                       salida: `marca_salida_id` ahora invalida la versión
                       TEAM y se reparan de forma controlada `tee_id`
                       faltantes en versiones activas ya vinculadas a
                       validaciones TEAM vigentes usando el snapshot
                       congelado, sin recalcular ni alterar versiones
                       superseded.

  243                  Permite automarcado A-Go-Go TEAM únicamente cuando un
                       equipo juega solo en su grupo; para grupos con 2+
                       equipos conserva marcado circular y exige que
                       cualquier marcador administrativo pertenezca al mismo
                       grupo, manteniendo cambios localizados por secuencia
                       y sin afectar PLAYER.

  244                  Alinea el contrato HCP TEAM de A-Go-Go: lo exige
                       también en Gross-only, agrega su estado al Asistente
                       Operativo antes de grupos/salidas y habilita una
                       reparación auditada GROSS_ONLY para freezes
                       históricos sin HCP TEAM que aún no tienen validación
                       ni tarjetas.

  245                  Hace explícita la inicialización de captura A-Go-Go
                       TEAM en el Asistente Operativo: tras emitir tarjetas
                       muestra Iniciar captura, detecta estados
                       parciales/inconsistentes y sólo después permite pasar
                       a revisar captura y conciliación, sin alterar Stroke
                       Play ni Stableford.

  246                  Homologa A-Go-Go con Stroke Play/Stableford haciendo
                       atómica la emisión + inicialización digital,
                       generaliza el diagnóstico de inicialización en el
                       Asistente y bloquea la captura física si la
                       estructura digital de la ronda no está íntegra,
                       preservando NRQ cuando la sesión existe pero no fue
                       usada.

  247                  Enriquece el payload oficial de tarjetas A-Go-Go TEAM
                       con quién marca a cada equipo y qué jugador propio
                       marca al oponente, reutilizando las asignaciones
                       activas sin alterar captura, scoring ni el contrato
                       PLAYER.

  248                  Blinda la revisión digital A-Go-Go TEAM: una disputa
                       activa no puede ser sobrescrita por el marcador y la
                       autocaptura `self_team` no admite confirmación ni
                       disputa contra el propio equipo.

  249                  Ordena el cierre formal A-Go-Go: una ronda sólo queda
                       lista para cierre después de cerrar formalmente todas
                       sus categorías y el Asistente prioriza ese paso.

  250                  Completa el reporte congelado de cierre por categoría
                       exponiendo número y fecha de ronda desde el propio
                       cierre formal, sin recalcular resultados ni consultar
                       leaderboard vivo.

  251                  Agrega reporte operativo A-Go-Go por categoría con
                       todos los scores de tarjeta física por hoyo en una
                       sola fila por equipo, ordenado por ranking Gross/Neto
                       y disponible sin depender del cierre de categoría.

  252                  Corrige el countback por tarjeta para usar los hoyos
                       reglamentarios y reordena el leaderboard A-Go-Go
                       después de aplicar finalRank de desempate.

  253                  Refuerza la capacidad de equipos en asignaciones y
                       reasignaciones: valida el cupo real según
                       `jugadores_por_equipo`, cuenta ocupación activa
                       incluyendo roster pendiente/confirmado y bloquea
                       sobrecupos de forma transaccional sin impedir
                       movimientos que no aumentan ocupación.

  254                  Formaliza las franjas de hándicap como prerrequisito
                       de configuración: agrega un validador global
                       independiente del orden de captura, detecta rangos
                       invertidos, huecos, traslapes y extremos abiertos
                       inválidos, y lo integra a la
                       confirmación/configuración operativa sin exigir un
                       límite inferior universal.

  255                  Corrige la seguridad del validador de franjas de
                       hándicap retirando `EXECUTE` a `anon` y conservándolo
                       únicamente para roles autorizados, sin cambiar su
                       lógica ni sus resultados.

  256                  Establece el inicio formal del torneo como frontera
                       competitiva: agrega estado de preparación para
                       iniciar, incorpora `START_TOURNAMENT` al Asistente y
                       bloquea scores competitivos, captura física y
                       conciliación antes de que el torneo esté `en_curso`,
                       permitiendo sólo la inicialización técnica previa
                       necesaria.

  257                  Hace del campo de golf la fuente de verdad del club
                       del torneo y elimina `duracion_dias`: el club se
                       deriva automáticamente del campo seleccionado, la
                       configuración mínima exige campo válido y se preserva
                       el provisionamiento comercial sin alterar el campo
                       específico de cada ronda.

  258                  Impide congelar un torneo si alguna ronda activa no
                       tiene modalidad de salida definida o al menos un
                       turno activo; integra estas validaciones al preview
                       de congelamiento sin modificar los datos
                       competitivos.

  259                  Completa el contrato de
                       `obtener_estado_inicio_torneo_256` después de iniciar
                       o finalizar el torneo, devolviendo siempre todos los
                       campos de preparación y evitando falsos avisos de
                       frontend por respuestas parciales.

  260                  Corrige el orden del Asistente para colocar
                       `START_TOURNAMENT` inmediatamente antes de la primera
                       captura competitiva, preservando dependencias
                       previas, modalidades Shotgun/Tee Times soportadas y
                       el flujo específico de A-Go-Go TEAM.

  261                  Convierte la configuración de desempates en requisito
                       formal antes de confirmar la configuración del
                       torneo: valida la secuencia R&A oficial por tipo de
                       resultado, normaliza la configuración global del
                       torneo y agrega `TIEBREAK_CONFIGURATION` al Asistente
                       antes de `CONFIGURATION_CONFIRMATION`.

  262                  Agrega compatibilidad temporal para torneos cuya
                       configuración ya había sido confirmada antes del
                       nuevo contrato de desempates: el Asistente considera
                       cumplido ese paso por antecedente de
                       `configuracion_finalizada_at`, sin relajar la
                       validación estricta para torneos nuevos ni reescribir
                       históricos.

  263                  Incorpora `ROUND_CONFIGURATION` como paso explícito
                       del Asistente antes de congelar: valida número de
                       rondas, fecha, campo, formato competitivo efectivo,
                       Handicap Allowance, modalidad de salida, turno activo
                       y existencia de un motor de salida soportado; los
                       torneos ya congelados quedan reconocidos como
                       históricos válidos.

  264                  Separa en el Asistente la operación que antes
                       aparecía como "Captura y conciliación" en dos pasos
                       reales: `ROUND_PHYSICAL_CAPTURE` y
                       `ROUND_RECONCILIATION`; distingue tarjetas físicas
                       pendientes, conciliación requerida y casos NRQ,
                       reutilizando la infraestructura común de Stroke Play,
                       Stableford y A-Go-Go.

  265                  Formaliza el cierre competitivo común de ronda en
                       cuatro etapas: Resultados → Cierre de categorías →
                       Publicación de resultados → Cierre de ronda; exige
                       backend que todas las categorías estén cerradas y
                       publicadas antes del cierre final y conserva como
                       válidos los cierres históricos ya formalizados.

  266                  Endurece las dependencias del Asistente Operativo:
                       elimina esperas hacia el paso obsoleto
                       `ROUND_SCORING`, difiere la evaluación competitiva
                       profunda hasta completar conciliación, normaliza
                       `START_TOURNAMENT` cuando sólo espera prerrequisitos
                       normales y evita bloqueos/crashes prematuros sin
                       modificar datos ni reglas competitivas.

  267                  Corrige el validador estructural de Rondas para
                       respetar que A-Go-Go TEAM (`equipo` + `team_stroke`)
                       no utiliza Handicap Allowance individual: permite
                       `NULL` en ese motor, conserva la exigencia 0--100
                       para Stroke Play/Stableford y alinea el Asistente con
                       el contrato de congelamiento establecido en la
                       Migración 218.

  268                  Corrige la secuencia del Asistente A-Go-Go colocando
                       HCP TEAM antes del congelamiento: HCP TEAM espera
                       inscripciones cerradas y Rondas completas, el
                       congelamiento espera HCP TEAM CURRENT y Armar grupos
                       permanece después del freeze, eliminando la
                       dependencia circular sin cambiar el motor de
                       congelamiento ni el cálculo competitivo.

  269                  Habilita la corrección controlada de HCP declarado en
                       A-Go-Go TEAM después del congelamiento y antes de
                       iniciar el torneo: conserva los snapshots históricos,
                       invalida/recalcula HCP TEAM, revalida salidas cuando
                       corresponde, versiona tarjetas ya emitidas sin
                       cambiar su `score_card_id` y devuelve las tarjetas
                       afectadas para reimpresión.

  270                  Corrige el flujo HCP post-emisión de la 269
                       activando, sólo cuando ya existen tarjetas oficiales,
                       el guard transaccional
                       `app.revisar_tarjeta_team_post_emision`; permite la
                       reapertura auditada, revalidación y revisión 215 sin
                       debilitar el trigger protector ni alterar snapshots o
                       tarjetas históricas.
  --------------------------------------------------------------------------

| 271 \| Habilita sustitución administrativa directa de integrantes
  A-Go-Go después del freeze y antes de iniciar el torneo: reutiliza o
  crea al jugador en catálogo, genera una nueva inscripción sin cobro
  conservando cobertura y cadena histórica, fija la marca de salida,
  recalcula HCP TEAM, revalida salidas y versiona tarjetas emitidas
  cuando corresponde, sin depender de capitán ni confirmación del
  sustituto. \|

| 272 \| Corrige la seguridad de las funciones de sustitución
  administrativa 271: revoca explícitamente EXECUTE a `anon` y conserva
  acceso únicamente para `authenticated` y `service_role`; no modifica
  lógica ni datos competitivos. \|

| 273 \| Corrige el guard de marcadores TEAM para sustituciones
  post-emisión: mantiene la validación estricta de pertenencia al
  snapshot vigente para asignaciones activas, pero permite cerrar como
  `ended` una asignación histórica del jugador saliente sin reescribir
  evidencia previa. \|

| 274 \| Agrega un detector de sólo lectura para la composición A-Go-Go
  antes del inicio: identifica equipos activos con un solo integrante,
  jugadores sueltos, equipos vacíos e inscripciones activas sin equipo,
  fija mínimo competitivo de 2 y expone un estado agregado sin modificar
  HCP TEAM, salidas, tarjetas ni resultados. \|

| 275 \| Integra el detector 274 con START_TOURNAMENT: el estado de
  inicio expone la composición A-Go-Go y `iniciar_torneo` bloquea desde
  backend cualquier inicio con equipos incompletos o jugadores activos
  sin equipo; no resuelve ni modifica composiciones. \|

| 276 \| Habilita la baja administrativa auditada de un integrante
  A-Go-Go después del Freeze y antes de START_TOURNAMENT; inactiva su
  inscripción, cancela su slot, deja HCP TEAM obsoleto mediante el
  trigger existente y reabre salidas validadas, manteniendo la
  composición y tarjetas pendientes de regularización antes del inicio.
  \|

| 277 \| Corrige la baja administrativa 276 para preservar intactas las
  salidas validadas y las tarjetas ya emitidas mientras el equipo
  incompleto sigue pendiente de resolución; la baja sólo actualiza
  composición/roster/auditoría y deja START_TOURNAMENT bloqueado por
  274--275 hasta que el organizador decida la resolución. \|

| 278 \| Amplía el detector 274 para controlar globalmente la
  composición A-Go-Go: detecta equipos excepción de tamaño normal +1,
  permite como máximo uno por torneo, detecta sobrecupos inválidos y
  vuelve a marcar la composición como pendiente si coexisten un equipo
  excepción y cualquier jugador suelto. START_TOURNAMENT hereda el
  bloqueo mediante compositionReady. No mueve jugadores, salidas ni
  tarjetas. \|

| 279 \| Reequilibrio A-Go-Go 3+1 → 2+2 post-Freeze/pre-START: el
  administrador elige un integrante del único equipo excepción de 3 y lo
  mueve al equipo incompleto de 1. Conserva ambos equipos y sus salidas
  físicas, recalcula HCP TEAM, renueva la validación lógica y revisa
  tarjetas/markers si ya fueron emitidos. Sólo las tarjetas de los dos
  equipos afectados se devuelven para reimpresión material. No cambia
  categorías y START_TOURNAMENT sigue dependiendo del detector global
  278. \|

| 280 \| A-Go-Go: elimina las firmas de jugador/equipo y marcador como
  requisito competitivo. Resultado oficial y leaderboard pasan a
  depender de tarjeta física CAPTURED + conciliación COMPLETED + score
  válido; las firmas pueden conservarse como datos
  históricos/informativos, pero no participan en ningún STOP
  competitivo. La primera versión preparada de 280 abortó sin aplicar
  cambios; se sustituyó por la versión corregida. Corrige el caso
  CENIR/2026 sin alterar sus datos. \|

## Pendientes

### A-Go-Go / Scramble

-   Completar el flujo pre-inicio de equipos incompletos: integrar el
    detector 274 con START_TOURNAMENT y después habilitar baja
    administrativa, retiro competitivo, excepción +1 y reagrupación
    auditada de jugadores sueltos.
-   Continuar el E2E integral A-Go-Go con torneos nuevos creados por el
    flujo real de organizador, siguiendo el Asistente Operativo hasta
    detectar únicamente fallas reales de operación.
-   Integrar en frontend la creación del equipo grupal y plaza inicial
    mediante la Migración 226 y las plazas provisionales de terceros
    mediante la Migración 227; después conectar el pago parcial 1--N de
    las Migraciones 223/224.
-   Integrar en frontend el flujo de invitación/aceptación de jugadores
    ya inscritos y pagados sin equipo, usando el contrato de la
    Migración 225.
-   Mantener y terminar de integrar en UI la opción de pago individual
    cuando la configuración del torneo lo permita.
-   Best Ball y Shamble permanecen como motores separados.

### Generales

-   Eliminar la función huérfana `validar_cupo_categoria()` reemplazada
    por `validar_cupo_categoria_cruzado()`.
-   Agregar ciudades al catálogo conforme se incorporen clubes en nuevas
    localidades.
-   Configurar SMTP personalizado de Supabase antes de operar con
    jugadores reales.
-   Revisar el flujo de cambio de correo jugador ↔ Auth para exigir
    confirmación del nuevo correo.
-   Soporte futuro para campos de 27+ hoyos con nueves combinables.
-   Completar pantallas administrativas/club y licencias que sigan
    pendientes.
-   Mantener pendientes los ajustes del motor de salidas que todavía
    requieran acomodación manual, balanceo o validación integral antes
    de tarjetas.

## Regla de mantenimiento

A partir de la siguiente migración, agregar **una sola entrada breve por
migración** y actualizar **Pendientes** cuando corresponda. No incluir
nombres de archivos SQL ni documentación exhaustiva del código en este
README.

## Migración 281 --- Incorporación de jugador suelto como única excepción +1 A-Go-Go (pre-emisión)

**Objetivo:** resolver el caso en que una baja deja un solo integrante
activo en un equipo A-Go-Go y el organizador decide incorporarlo a otro
equipo que ya tiene el tamaño normal configurado, creando la única
excepción `+1` permitida antes de `START_TOURNAMENT`.

**Qué hace:** agrega
`incorporar_suelto_como_excepcion_a_gogo_281(uuid, uuid, text)`. Exige
A-Go-Go TEAM, Freeze, permisos administrativos, mismo torneo/categoría,
origen con exactamente un jugador activo reconocido como suelto, destino
con tamaño normal completo, ausencia de otra excepción y máximo absoluto
de cuatro integrantes. Mueve la inscripción existente sin crear otra,
deja el equipo origen como histórico/inactivo, conserva la salida física
del equipo destino, recalcula su HCP TEAM y renueva la validación lógica
cuando corresponde. Todo queda auditado en
`tournament_team_composition_changes`.

**Alcance de esta fase:** sólo antes de la emisión oficial de tarjetas.
Si ya existen tarjetas emitidas, la RPC bloquea la operación para no
alterar silenciosamente tarjetas ni relaciones de marcador; ese
escenario se resolverá en una fase posterior específica.

## Migración 282 --- Corrección de excepción +1 frente al control general de cupo

**Objetivo:** corregir la contradicción entre la RPC 281 y el trigger general
de cupo de la Migración 253, que impedía ejecutar el caso válido
`2/2 → 3/2` aunque la propia RPC 281 exigía que el equipo destino estuviera
completo.

**Qué hace:** la RPC
`incorporar_suelto_como_excepcion_a_gogo_281(uuid, uuid, text)` reutiliza
la válvula oficial `app.saltar_validacion_cupo_equipo` exclusivamente
durante el `UPDATE` controlado que mueve al jugador suelto al equipo
destino. La señal se activa inmediatamente antes del movimiento y se
restaura inmediatamente después. No modifica el trigger general ni
relaja las operaciones ordinarias.

**Alcance:** conserva intactas todas las validaciones de la 281: A-Go-Go
TEAM, Freeze, pre-START_TOURNAMENT, pre-emisión, origen con un único
jugador suelto, destino con tamaño normal completo, misma categoría,
máximo absoluto de cuatro jugadores, una sola excepción global,
recálculo HCP TEAM, auditoría y postcondición `compositionReady=true`.

## Migración 283 --- Corrección de relación grupos / turnos / rondas en RPC 281

**Objetivo:** corregir un error de ejecución detectado en la prueba E2E de la
RPC 281. La función intentaba filtrar grupos mediante
`tournament_round_shifts.tournament_id`, columna que no existe.

**Qué hace:** sustituye exclusivamente ese tramo de la RPC
`incorporar_suelto_como_excepcion_a_gogo_281(uuid, uuid, text)` por la
relación correcta:
`tournament_groups -> tournament_round_shifts -> tournament_rounds`,
filtrando finalmente por `tournament_rounds.tournament_id`. Se conserva el
retiro lógico de grupos vacíos sin modificar salidas físicas del equipo
destino.

**Alcance:** no cambia frontend, trigger de cupo, reglas de composición,
HCP TEAM, permisos, auditoría ni límites de la excepción +1. Conserva las
correcciones de las migraciones 281 y 282.

## Migración 284 --- Retiro competitivo de equipo incompleto A-Go-Go

**Objetivo:** resolver la segunda alternativa administrativa cuando, después
del Freeze y antes de iniciar el torneo, un equipo A-Go-Go queda con un solo
integrante y el organizador decide no incorporarlo a otro equipo.

**Qué hace:** agrega la RPC
`retirar_equipo_incompleto_competencia_a_gogo_284(uuid,text)`. La operación
requiere un equipo activo reconocido como INCOMPLETE con exactamente un
integrante, bloquea después de START_TOURNAMENT y bloquea si ya existen
tarjetas oficiales emitidas. Conserva históricamente equipo, inscripción y
HCP TEAM, pero los retira de la competencia oficial; inactiva la asignación
de salida y cualquier grupo que quede vacío; revalida rondas Shotgun TEAM
que ya estaban validadas.

**Auditoría:** registra `team_competitive_withdrawal` con fase
`284_RETIRE_INCOMPLETE_TEAM_PRE_EMISSION`, preservando jugador afectado,
equipo, motivo, administrador y contexto para la futura bitácora de
movimientos del torneo.

**Criterio:** no es una descalificación deportiva. El jugador permanece en
el historial de inscritos, pero deja de ser competidor oficial. Si juega
recreativamente, queda fuera de tarjetas, scoring y resultados de Tee
Central.


## Migración 285 — Corrección de reapertura de validación al retirar equipo A-Go-Go

**Objetivo:** corregir la RPC `retirar_equipo_incompleto_competencia_a_gogo_284` cuando existen salidas Shotgun TEAM ya validadas.

**Qué hace:** sustituye el intento inválido de cambiar una validación `validated` directamente a `superseded` por el contrato autorizado `validated → reopened`, habilitando temporalmente `app.reabrir_validacion_salida_ronda`, registrando `reopened_at`, `reopened_by` y `reopen_reason`, y restaurando después la señal. Conserva la previsualización y revalidación formal posteriores de la 284.

**Qué no cambia:** no modifica ni debilita `_proteger_validacion_salida_ronda`; no altera las reglas de A-Go-Go, la frontera `START_TOURNAMENT`, el bloqueo pre-emisión, la composición, los HCP TEAM ni otros motores/modalidades.

**Archivos:**
- `285_CORRIGE_REAPERTURA_VALIDACION_RETIRO_EQUIPO_A_GOGO.sql`
- `285_VERIFICACION_CORRIGE_REAPERTURA_VALIDACION_RETIRO_EQUIPO_A_GOGO.sql`
