# Migraciones de base de datos --- Tee Central / GOLF IN FULL

Este documento conserva un registro breve de cada migración aplicada o
preparada en el proyecto.

**Proyecto Supabase:** `GOLFING_FULL`\
**Aplicación:** las migraciones se ejecutan manualmente en Supabase, en
orden.\
**Criterio del README:** una entrada por migración, sin repetir el SQL.
Supabase es la fuente de verdad del esquema vivo.

## Orden de migraciones

  -----------------------------------------------------------------------
  \#                Qué hace
  ----------------- -----------------------------------------------------
  001               Crea la tabla maestra de jugadores con
                    identificación, contacto y hándicap
                    declarado/verificado.

  002               Crea parámetros del sistema y la primera estructura
                    de administradores/organizadores.

  003               Rediseña permisos con catálogo de roles, asignaciones
                    por club/torneo y helpers de autorización.

  004               Agrega límites de asignación por rol, reglas para
                    otorgarlos y auditoría genérica.

  005               Permite activar/desactivar personas, roles y
                    asignaciones sin borrarlos, dejando trazabilidad.

  006               Impide borrar administradores con historial; obliga a
                    desactivarlos.

  007               Recrea triggers faltantes de jugadores,
                    administradores, roles y asignaciones.

  008               Crea clubes y torneos, activa relaciones pendientes y
                    aplica RLS por rol.

  009               Restringe teléfono y correo de clubes a usuarios
                    autenticados.

  010               Define RLS de jugadores: cada jugador ve/edita su
                    perfil y administradores autorizados gestionan
                    perfiles.

  011               Agrega GRANT faltantes para que las políticas RLS
                    puedan evaluarse correctamente.

  012               Corrige recursión RLS haciendo seguros los helpers de
                    autorización SECURITY DEFINER.

  013               Crea geografía normalizada de países, estados y
                    ciudades con huso horario.

  014               Elimina ciudad/estado en texto libre de clubes y deja
                    city_id como fuente normalizada.

  015               Hace obligatorio city_id en clubes.

  016               Crea catálogo amigable de husos horarios y lo vincula
                    con ciudades.

  017               Crea módulos y licencias por club para controlar
                    contratación y vigencia.

  018               Agrega formato de juego, modalidad, tamaño de equipo
                    y categorías por torneo.

  019               Agrega rangos opcionales de edad y hándicap a
                    categorías.

  020               Vincula automáticamente al confirmar correo un
                    jugador con un perfil previamente registrado.

  021               Agrega alta/baja lógica y auditoría a jugadores.

  022               Reintenta en cada login la vinculación de perfiles
                    pre-registrados.

  023               Crea campos de golf por club con hoyos, timezone y
                    coordenadas opcionales.

  024               Crea marcas de salida, hoyos y distancias por marca.

  025               Separa Course Rating y Slope por caballeros y damas.

  026               Habilita PostGIS y coordenadas frente/centro/atrás
                    del green.

  026A              Agrega helper RPC y vista para manejar coordenadas de
                    green sin exponer PostGIS al frontend.

  027               Estandariza categorías de marcas y calcula
                    automáticamente su orden visual.

  028               Crea vistas de resumen de par y yardaje por
                    campo/marca.

  029               Crea catálogo de formatos de torneo y define
                    participación y scoring_engine.

  030               Migra torneos al catálogo de formatos y elimina enums
                    anteriores de modalidad.

  031               Crea métodos/reglas de desempate, allowance por
                    formato y overrides de rating/slope por torneo.

  032               Crea rondas, herencia de formato/allowance y reglas
                    de corte por categoría.

  033               Crea turnos por ronda y cupo máximo por categoría.

  034               Vincula el torneo con su campo de golf y valida
                    pertenencia al club sede.

  035               Agrega alta/baja lógica y auditoría a reglas de
                    corte.

  036               Incluye al organizador entre quienes pueden
                    consultar/editar su torneo.

  037               Agrega número de rondas planeadas al torneo.

  038               Impide crear más rondas activas que las planeadas.

  039               Agrega el estado de inscripción cerrada al ciclo de
                    vida del torneo.

  040               Define el orden estándar de presentación de métodos
                    de desempate.

  041               Agrega alta/baja lógica a reglas de desempate y
                    libera posiciones al desactivarlas.

  042               Agrega tarifa individual, tarifa por equipo completo
                    y moneda.

  043               Hace teléfono de jugador obligatorio/único y
                    restringe su edición tras confirmar cuenta.

  044               Reemplaza error técnico de teléfono duplicado por
                    mensaje comprensible.

  045               Corrige la detección de teléfono duplicado usando
                    SECURITY DEFINER.

  046               Crea información comercial/marketing del torneo.

  047               Agrega ventana de fecha/hora válida para acceso por
                    QR al torneo.

  048               Crea inscripciones pagadas con QR, cupo por categoría
                    y registro de intentos.

  049               Crea pre-reservas separadas de inscripciones pagadas
                    y unifica participantes para roster.

  050               Permite confirmar una pre-reserva y convertirla en
                    inscripción real sin perder historial.

  051               Separa el catálogo de medios de pago de torneo del de
                    licencias.

  052               Crea payment_attempts genérico y procesamiento
                    temporal/simulado de pagos.

  053               Habilita pgcrypto para tokens y referencias
                    aleatorias.

  054               Corrige el uso de pgcrypto en el esquema extensions
                    dentro de funciones seguras.

  055               Agrega folio legible consecutivo por torneo a las
                    inscripciones.

  056               Agrega mensaje claro para inscripción duplicada.

  057               Agrega bandera para evitar reenvío accidental del
                    correo de confirmación.

  058               Limita la visibilidad del organizador a jugadores
                    relacionados con sus torneos.

  059               Agrega hora de escopetazo a la información del
                    torneo.

  060               Crea solicitud de recibo deducible y referencia a
                    constancia fiscal.

  061               Crea bucket privado para constancias fiscales con
                    permisos por jugador y administrador.

  062               Corrige recursión RLS en visibilidad de jugadores
                    para organizadores.

  063               Registra desde el intento de pago la intención de
                    solicitar recibo deducible.

  064               Agrega datos de beneficencia al torneo y limita
                    recibos deducibles a esos eventos.

  065               Agrega Early Bird y cálculo server-side de tarifa
                    vigente.

  066               Amplía permisos sobre marketing y prepara validación
                    de tarifa de socios.

  067               Separa tarifa de socios de Early Bird y bloquea
                    tarifas cuando ya existen inscripciones.

  068               Permite perfiles incompletos en pre-registro y exige
                    datos completos al inscribirse realmente.

  069               Crea búsqueda acotada de jugador por teléfono para
                    reservas telefónicas.

  070               Crea reservas telefónicas para personas aún no
                    registradas y su reconciliación posterior.

  071               Crea vista unificada de pre-reservas y reservas
                    telefónicas.

  072               Exige perfil completo solo en inscripción real, no en
                    pre-reserva.

  073               Normaliza fecha límite de pago y la valida contra
                    inicio del torneo.

  074               Agrega bandera para evitar reenvío accidental de
                    correo de pre-reserva.

  075               Permite al jugador pagar en línea su propia
                    pre-reserva pendiente.

  076               Normaliza códigos de país telefónicos y agrega
                    consentimiento de WhatsApp.

  077               Crea plantillas/secuencias de desempate y método
                    mexicano por hándicap.

  078               Permite desempates distintos por categoría y por
                    resultado Gross/Neto.

  079               Crea equipos, vincula inscripciones a equipo y
                    permite reasignar jugadores.

  080               Simplifica torneos de categoría única usando la
                    categoría real ÚNICA.

  081               Permite que un jugador autenticado cree su propio
                    equipo.

  082               Agrega logo de torneo y bucket público controlado.

  083               Propaga equipo a pre-reservas, reservas telefónicas y
                    conversión a inscripción.

  084               Corrige validación para permitir categoría NULL
                    cuando corresponde.

  085               Exige categoría desde la pre-reserva cuando el
                    jugador todavía no tiene equipo.

  086               Agrega club y número de membresía al jugador.

  087               Restringe la edición de membresía al jugador o
                    superadmin.

  088               Aplica tarifa real de socio según club y membresía
                    del jugador.

  089               Valida cupo de equipo contando inscripciones,
                    pre-reservas y reservas telefónicas sin doble conteo.

  090               Hace obligatoria la fecha límite de pago para
                    transferencias.

  091               Asigna automáticamente marca de salida según
                    categoría, franjas y hándicap.

  092               Agrega orden de visualización a categorías.

  093               Carga el orden estándar de categorías de
                    Scratch/Premier hasta Damas y Única.

  094               Evita reasignar categorías sin rango de hándicap
                    definido.

  095               Extiende la resolución de categoría para validar
                    también por edad.

  096               Blinda franjas de hándicap contra huecos/traslapes y
                    consolida herencia de rangos.

  097               Ajusta reglas de categorías y franjas para mantener
                    consistencia en la asignación automática.

  098               Refuerza la resolución de categoría/marca en
                    escenarios de torneo con reglas especiales.

  099               Corrige validaciones de elegibilidad y asignación
                    derivadas de género, edad y hándicap.

  100               Consolida reglas de inscripción para categorías y
                    marcas de salida.

  101               Refuerza consistencia entre categorías del torneo,
                    rangos efectivos y selección del jugador.

  102               Ajusta validaciones de inscripción y resolución
                    automática para casos límite.

  103               Consolida reglas de género y elegibilidad en
                    categorías del torneo.

  104               Ajusta el tratamiento de categorías Senior y su
                    convivencia con categorías regulares.

  105               Refuerza reglas de inscripción para evitar
                    selecciones incompatibles.

  106               Corrige la resolución de marca/categoría para
                    conservar la configuración válida del torneo.

  107               Ajusta reglas de cupo y elegibilidad en los distintos
                    canales de inscripción.

  108               Consolida controles de consistencia de inscripciones
                    y reservas.

  109               Refuerza sincronización de categoría, marca y equipo
                    durante la inscripción.

  110               Ajusta validaciones de cupo y duplicidad entre
                    canales de participación.

  111               Consolida reglas operativas para reservas,
                    inscripciones y equipos.

  112               Refuerza validaciones de datos deportivos usados al
                    inscribir jugadores.

  113               Ajusta comportamiento de categorías y marcas ante
                    cambios de configuración.

  114               Consolida reglas de elegibilidad antes del
                    congelamiento del torneo.

  115               Refuerza controles de integridad en inscripciones y
                    pre-reservas.

  116               Ajusta sincronización y validaciones de información
                    competitiva del jugador.

  117               Consolida reglas de categorías, equipos y cupos
                    previas a la operación de rondas.

  118               Refuerza validaciones de reservas/inscripciones para
                    evitar estados inconsistentes.

  119               Ajusta reglas de cortesías y capacidad relacionadas
                    con participantes del torneo.

  120               Consolida controles de cupo y participación para los
                    distintos canales de alta.

  121               Refuerza consistencia de categoría y marca en
                    participantes ya registrados.

  122               Ajusta validaciones administrativas sobre
                    participantes y configuración deportiva.

  123               Consolida reglas previas al cierre/congelamiento de
                    inscripciones.

  124               Refuerza integridad de equipos, categorías y reservas
                    antes de preparar salidas.

  125               Ajusta validaciones de inscripción y asignación para
                    casos detectados en pruebas.

  126               Consolida correcciones de elegibilidad/cupo previas
                    al motor de rondas.

  127               Refuerza consistencia final de categorías, marcas y
                    participantes.

  128               Cierra la etapa de correcciones de
                    inscripción/configuración previa al motor operativo
                    de salidas.

  129               Inicia la infraestructura operativa de salidas por
                    ronda.

  130               Extiende la preparación de salidas y sus validaciones
                    estructurales.

  131               Consolida configuración de grupos/unidades para
                    salidas.

  132               Refuerza preparación y consistencia de salidas antes
                    de validarlas.

  133               Amplía el motor de preparación de salidas y su
                    información operativa.

  134               Ajusta validaciones y contratos de preparación de
                    ronda.

  135               Prepara la transición entre configuración deportiva y
                    emisión de tarjetas.

  136               Congela condiciones y hándicaps por ronda mediante
                    snapshots inmutables.

  137               Crea preview de tarjetas de Shotgun individual sin
                    emitir identidad oficial.

  138               Blinda secuencia de rondas y permite reactivar la
                    siguiente ronda inactiva.

  139               Permite a administradores ver rondas inactivas para
                    poder reactivarlas.

  140               Crea validación versionada de salidas, snapshot
                    operativo y bloqueo hasta reapertura.

  141               Corrige el validador para ignorar categorías vacías y
                    arregla mensajes.

  142               Agrega historial auditable de validaciones y
                    reaperturas de salidas.

  143               Refuerza bloqueo y consistencia de objetos de salida
                    después de validar.

  144               Consolida el contrato operativo de salidas validadas
                    para etapas posteriores.

  145               Prepara la emisión oficial de tarjetas a partir de
                    una salida validada.

  146               Extiende la preemisión/emisión y controles de
                    tarjetas por ronda.

  147               Refuerza identidad y trazabilidad de tarjetas
                    oficiales.

  148               Consolida controles de emisión y acceso a tarjetas.

  149               Cierra la base operativa de tarjetas para iniciar
                    captura de resultados.

  150               Inicia captura de resultados por hoyo sobre tarjetas
                    oficiales.

  151               Extiende captura digital y controles de resultados
                    por hoyo.

  152               Consolida captura física/digital y reglas necesarias
                    para conciliación.

  153               Crea/fortalece conciliación entre evidencia física y
                    digital.

  154               Agrega resolución auditable de diferencias y disputas
                    por hoyo.

  155               Consolida resultado oficial por tarjeta a partir de
                    evidencia conciliada.

  156               Refuerza uso de snapshots de hándicap y condiciones
                    en el resultado oficial.

  157               Agrega estados terminales/outcomes competitivos del
                    jugador.

  158               Construye leaderboard oficial Gross/Neto sobre
                    resultados oficiales.

  159               Refuerza consistencia del leaderboard y cierre de
                    resultados de ronda.

  160               Crea motor de desempates aplicable a resultados
                    oficiales.

  161               Agrega resolución manual auditable de desempates.

  162               Consolida estado competitivo/cierre de ronda después
                    de desempates.

  163               Inicia estructura de provisionamiento y estado
                    comercial del torneo.

  164               Extiende perfil comercial/fiscal y controles
                    administrativos.

  165               Consolida flujo de servicio/provisionamiento para
                    torneos.

  166               Crea infraestructura de invitaciones para
                    organizadores.

  167               Permite aceptar invitación administrativa con usuario
                    autenticado y correo verificado.

  168               Agrega trazabilidad de envío/reenvío de invitaciones
                    administrativas.

  169               Generaliza invitaciones para club_admin y
                    tournament_organizer.

  170               Agrega nombres/apellidos estructurados y firma
                    canónica de aceptación administrativa.

  171               Adapta provisionamiento para crear/asignar
                    organizador con datos estructurados.

  172               Hace que conciliación parta de snapshots; digital
                    deja de ser requisito y física sigue obligatoria.

  173               Hace que finalización/resolución partan de snapshots
                    y solo bloqueen diferencias/disputas reales.

  174               Hace oficiales los resultados desde snapshots,
                    aceptando PHYSICAL_ONLY con tarjeta física completa.

  175               Centraliza categorías elegibles: natural o superior,
                    con reglas de género, edad y hándicap.

  176               Agrega finalización/reapertura de configuración y
                    control administrativo de liberación del torneo.

  177               Agrega teléfono del organizador/administrador y su
                    sincronización operativa.

  178               Corrige y consolida RPC/flujo administrativo derivado
                    de configuración y liberación.

  179               Inicia adaptación del motor común para Stableford
                    individual.

  180               Extiende contratos de scoring y captura necesarios
                    para Stableford.

  181               Incorpora semántica Stableford en captura/resultados
                    manteniendo infraestructura común.

  182               Consolida fases iniciales de Stableford sobre
                    tarjetas y conciliación existentes.

  183               Extiende resultado oficial y operación Stableford sin
                    crear pipeline paralelo.

  184               Consolida leaderboard y reglas de clasificación
                    Stableford.

  185               Extiende desempates/operación Stableford reutilizando
                    infraestructura común.

  186 Fase 1A       Crea clasificaciones competitivas Gross/Neto por
                    categoría y snapshots inmutables.

  186 Fase 1B       Registra Stableford individual en motores comunes de
                    salida Shotgun/Tee Times.

  186 Fases         Completa contratos universales de resultado de hoyo,
  posteriores       PICKUP y piezas comunes necesarias para Stableford.

  187               Continúa integración de Stableford en captura,
                    conciliación y resultado oficial.

  188               Consolida asistente operativo y contratos necesarios
                    para el flujo Stableford.

  189               Extiende leaderboard/resultado Stableford a nivel de
                    ronda.

  190               Consolida acumulación y comportamiento Stableford a
                    nivel de torneo.

  191               Ajusta dependencias operativas del asistente para
                    trabajar con motores comunes.

  192               Define contrato común de leaderboard por ronda para
                    Stroke Play y Stableford.

  193               Consolida implementación Stableford y su integración
                    con infraestructura común.

  194               Agrega estado/cierre competitivo por categoría.

  195               Agrega publicación y reporte de resultados por
                    categoría.

  196               Inicia consolidación de clasificación competitiva
                    Gross/Neto en el flujo oficial.

  197               Extiende consumo de clasificación competitiva en
                    resultados/leaderboards.

  198 Fase 2        Integra clasificación competitiva en Stroke Play
                    respetando Gross/Neto configurados.

  198 Fase 2A       Blinda funciones internas de Stroke Play relacionadas
                    con clasificación competitiva.

  199 Fase 1B       Agrega capitán explícito y roster provisional por
                    nombre/correo para A-Go-Go, con confirmación personal
                    y bloqueo de duplicidades antes de reservar plaza.

  200 Fase 1C       Implementa pago de equipo completo A-Go-Go mediante
                    una cobertura económica única: el capitán paga una
                    sola vez, los integrantes confirmados se convierten a
                    inscripción y los pendientes quedan cubiertos hasta
                    confirmar personalmente.

  201 Fase 2A       Permite reasignar de forma controlada y auditada una
                    inscripción A-Go-Go existente entre equipos después
                    del freeze, sin relajar el congelamiento general ni
                    modificar salidas ya validadas.

  202 Fase 2B       Implementa sustitución post-freeze de integrantes
                    A-Go-Go sin cambiar identidades históricas: el
                    saliente conserva su inscripción, el reemplazo
                    confirma personalmente y recibe una nueva inscripción
                    sin cobro adicional, con cobertura de equipo cuando
                    aplica.

  203 Fase 3A       Crea el hándicap competitivo de equipo A-Go-Go
                    separado de snapshots individuales, con configuración
                    Gross-only/promedio porcentual/tabla por suma/WHS
                    Scramble, versiones por ronda y evidencia auditable
                    de cada integrante.

  204 Fase 3B       Añade vigencia automática al HCP competitivo de
                    equipo: cambios de composición, Handicap Index, tee o
                    configuración marcan la versión activa como obsoleta;
                    expone estado MISSING/STALE/CURRENT y permite
                    recálculo masivo por ronda.

  205 Fase 4A       Habilita formalmente salidas Shotgun A-Go-Go por
                    equipo: registra el motor team_stroke, construye
                    contrato común v2 con unitType=team, valida
                    asignación única/categoría y exige HCP competitivo
                    CURRENT; la emisión de tarjeta se mantiene
                    deshabilitada hasta Fase 5.

  206 Fase 4B       Permite reacomodar un equipo A-Go-Go Shotgun después
                    de validar salidas sin editar el snapshot histórico:
                    el movimiento es localizado y atómico, la validación
                    anterior queda histórica y se crea una nueva versión
                    formal; se bloquea si ya existen tarjetas emitidas.

  207 Fase 4C       Permite reasignaciones y sustituciones de integrantes
                    A-Go-Go después de validar salidas: reutiliza los
                    flujos 201/202, recalcula HCP de equipos afectados y
                    genera nuevas versiones formales de las rondas
                    validadas de forma atómica; bloquea cambios si ya hay
                    tarjetas emitidas.

  208 Fase 5        Habilita tarjeta oficial A-Go-Go por equipo sobre
                    tournament_score_cards: preview y emisión TEAM,
                    snapshot imprimible con integrantes y versión exacta
                    de HCP validado, firmas requeridas y consulta rápida
                    de todas las tarjetas del mismo grupo; la captura por
                    hoyo queda para Fase 6.

  209 Fase 6        Habilita captura A-Go-Go sobre la infraestructura
                    común: inicializa sesiones y un score por
                    equipo/hoyo, asigna marcador de otro equipo, permite
                    confirmar/disputar a integrantes del equipo,
                    reutiliza captura física y conciliación y blinda que
                    team_stroke nunca admita PICKUP.

  210 Fase 7        Construye el resultado oficial A-Go-Go por equipo
                    reutilizando la evidencia universal de
                    física/conciliación: exige todos los hoyos SCORE y
                    ambas firmas, toma el HCP congelado en la tarjeta,
                    calcula Gross y Net y consume los snapshots comunes
                    de clasificación Gross/Neto.

  211 Fase 8        Construye el leaderboard A-Go-Go de ronda por
                    equipos: consume resultados oficiales, ordena
                    Gross/Neto ascendente según clasificación congelada,
                    integra outcomes terminales, detecta empates
                    pendientes y extiende el dispatcher operativo común
                    declarando TEAM como unidad competitiva.

  212 Fase 9        Implementa desempates A-Go-Go por equipo reutilizando
                    reglas, métodos, evaluador y tablas comunes: soporta
                    secuencias distintas para Gross/Neto, distribuye el
                    Team Playing Handicap por Stroke Index para countback
                    Neto, permite resolución manual por score_card_id y
                    aplica finalRank al leaderboard.

  213 Fase 10       Integra A-Go-Go al cierre competitivo, publicación y
                    finalización comunes: extiende los gates de
                    resultados y desempates para TEAM/team_stroke,
                    preserva Stroke/Stableford y reutiliza sin tablas
                    paralelas los cierres por categoría/ronda,
                    publicaciones y sello final del torneo.

  214 Fase 11A      Completa la experiencia digital A-Go-Go para
                    integrantes TEAM: visibilidad de tarjeta, apertura
                    por QR, detalle/panel/mis rondas,
                    confirmación/disputa por cualquier integrante y
                    cambio administrativo de marker entre equipos,
                    preservando el flujo individual existente.

  215 Fase 11B1     Permite reasignaciones y sustituciones de integrantes
                    después de emitir tarjetas A-Go-Go conservando el
                    mismo score_card_id y folio: revalida salidas,
                    recalcula HCP TEAM, actualiza el snapshot vigente con
                    historial de revisiones y refresca markers afectados;
                    además corrige los assignment_source TEAM.

  216 Fase 11B2     Permite reacomodar un TEAM entre grupos/hoyos Shotgun
                    después de emitir tarjetas, sólo antes del primer
                    score en los grupos afectados: conserva score_card_id
                    y emisión, crea nueva validación, sincroniza sesión
                    de captura, recalcula la secuencia de la tarjeta
                    movida y reconstruye únicamente los markers de
                    origen/destino.

  217 Fase L2       Completa el contrato de configuración HCP TEAM para
                    frontend: lectura segura de método/porcentaje/rangos,
                    reemplazo atómico de rangos y limpieza de rangos al
                    abandonar el método por tabla, sin abrir SELECT
                    directo a las tablas.

  218               Adapta el congelamiento común a A-Go-Go/team_stroke:
                    Handicap Allowance individual deja de ser requisito,
                    el snapshot de ronda admite "no aplica" y no se
                    fabrican Playing Handicaps individuales; Stroke Play
                    y Stableford conservan su contrato.

  219               Corrige las operaciones A-Go-Go post-freeze para
                    localizar el congelamiento vigente por `frozen_at` en
                    lugar de la columna inexistente `created_at`, sin
                    cambiar contratos ni reglas funcionales.

  220               Corrige la clasificación competitiva por categoría
                    para registrar `created_by` con `admin_users.id` en
                    lugar de `auth.uid()`, eliminando la violación de FK
                    al guardar Gross/Neto/Both.

  221               Corrige el trigger común de PICKUP para separar las
                    ramas digital y física por tabla, evitando
                    referencias a columnas inexistentes sin relajar el
                    bloqueo de PICKUP en A-Go-Go.

  222               Hace opcional
                    `tournament_team_roster_slots.invited_by_player_id`
                    para permitir sustituciones administrativas A-Go-Go
                    en equipos sin capitán, preservando la autoría
                    administrativa existente.

  223               Agrega pago grupal parcial de 1--N plazas en torneos
                    por equipos reutilizando roster y coberturas
                    económicas, permite múltiples coberturas parciales
                    por equipo y conserva intactos el pago individual y
                    el pago de equipo completo.

  224               Encapsula los helpers internos SECURITY DEFINER del
                    pago grupal parcial, retirando ejecución directa a
                    `anon` y `authenticated` sin cambiar la lógica ni los
                    RPC públicos de la Migración 223.

  225               Permite invitar a un jugador ya inscrito y pagado que
                    aún está sin equipo; al aceptar, reutiliza su misma
                    inscripción y la incorpora al equipo sin segundo
                    cobro ni inscripción duplicada.

  226               Crea de forma atómica un equipo nuevo de inscripción
                    grupal sin capitán obligatorio y su plaza inicial
                    "TÚ" como miembro confirmado, sin crear todavía
                    inscripción ni pago.

  227               Permite al iniciador de una inscripción grupal
                    agregar plazas provisionales de terceros sin capitán
                    obligatorio, enlazando jugadores existentes cuando
                    corresponde y dejando personas nuevas pendientes de
                    confirmación, sin crear inscripción ni pago.

  228               Retira el permiso de ejecución del rol `anon` sobre
                    los tres RPC de pago grupal, preservando
                    `authenticated` y `service_role`, sin modificar
                    lógica, firmas, tablas ni datos.

  229               Corrige la resolución automática de categoría única
                    al crear equipos, eliminando el uso incompatible de
                    `min(uuid)` sin cambiar las reglas para torneos sin
                    categoría, con categoría única o multicategoría.

  230               Permite configurar desempates Gross y Neto
                    simultáneamente para el mismo
                    torneo/categoría/alcance, aislando el reemplazo por
                    tipo de resultado y cerrando la ejecución anónima de
                    la RPC de configuración.

  231               Impide congelar A-Go-Go/team_stroke con clasificación
                    Neto sin una configuración HCP TEAM válida; rechaza
                    GROSS_ONLY para Neto y exige rangos cuando se usa
                    ASSIGNED_TABLE_SUM_HI, preservando Gross-only y los
                    motores Stroke/Stableford.

  232               Agrega una reparación excepcional, atómica y
                    auditable para freezes históricos A-Go-Go/team_stroke
                    con Neto creados sin HCP TEAM antes de la 231; sólo
                    opera si no existe ninguna evidencia competitiva y
                    recalcula las versiones TEAM sin modificar el freeze
                    ni sus snapshots.

  233               Convierte `estatus=cancelado` en estado operativo de
                    sólo lectura: refuerza guards comunes y bloquea
                    mutaciones de configuración, inscripción, equipos,
                    salidas, tarjetas y captura competitiva sin alterar
                    `activo`, `estado_servicio`, pagos, freezes,
                    snapshots ni históricos.

  234               Refuerza el congelamiento A-Go-Go con Neto exigiendo
                    HCP TEAM CURRENT para cada equipo activo en cada
                    ronda `team_stroke`; bloquea `MISSING`/`STALE` antes
                    del freeze sin impedir recálculos ni versionado
                    posteriores.

  235               Incorpora `ROUND_GROUPS` al Asistente Operativo para
                    rondas Shotgun, distinguiendo PLAYER/TEAM y exigiendo
                    conformación completa antes de habilitar Salidas;
                    preserva sin cambios el flujo no-Shotgun.

  236               Corrige el helper `ROUND_GROUPS` para tratar
                    `formato_salida = NULL` como no-Shotgun mediante
                    comparación NULL-safe, evitando falsos bloqueos en
                    rondas históricas Stableford sin alterar el flujo
                    Shotgun.

  237               Corrige la capacidad Shotgun por equipos para medir
                    jugadores físicos activos ---no cantidad de
                    equipos--- y evita que `ROUND_GROUPS` quede COMPLETE
                    cuando existe sobrecupo físico; preserva individual,
                    no-Shotgun y el payload existente.

  238               Enriquece la previsualización de tarjetas A-Go-Go
                    TEAM con contexto congelado de torneo/ronda/campo,
                    integrantes y marcas por jugador, PAR/HCP de hoyo y
                    yardajes por tee, sin inventar una tee o distancia
                    única del equipo ni alterar emisión/scoring.

  239               Corrige el nombre de la marca en el preview A-Go-Go
                    TEAM usando como fallback el snapshot histórico del
                    mismo freeze/inscripción/jugador/tee cuando el
                    snapshot específico de ronda viene vacío; no usa
                    catálogo vivo ni fabrica color histórico.

  240               Extiende el payload oficial común de tarjetas con
                    contrato A-Go-Go TEAM basado en la tarjeta/snapshot
                    oficial vigente, integrantes, HCP TEAM, salida y
                    yardajes por tee; preserva PLAYER y excluye QR de la
                    rama TEAM.

  241               Agrega materialización administrativa de marcas de
                    salida faltantes para torneos de categoría única
                    antes del freeze, reutilizando prioridad Damas→Rojas,
                    Senior→Doradas y franjas por hándicap, sin
                    sobrescribir marcas ya asignadas ni relajar el
                    congelamiento.

  242               Corrige vigencia de HCP TEAM ante cambios de marca de
                    salida: `marca_salida_id` ahora invalida la versión
                    TEAM y se reparan de forma controlada `tee_id`
                    faltantes en versiones activas ya vinculadas a
                    validaciones TEAM vigentes usando el snapshot
                    congelado, sin recalcular ni alterar versiones
                    superseded.

  243               Permite automarcado A-Go-Go TEAM únicamente cuando un
                    equipo juega solo en su grupo; para grupos con 2+
                    equipos conserva marcado circular y exige que
                    cualquier marcador administrativo pertenezca al mismo
                    grupo, manteniendo cambios localizados por secuencia
                    y sin afectar PLAYER.

  244               Alinea el contrato HCP TEAM de A-Go-Go: lo exige
                    también en Gross-only, agrega su estado al Asistente
                    Operativo antes de grupos/salidas y habilita una
                    reparación auditada GROSS_ONLY para freezes
                    históricos sin HCP TEAM que aún no tienen validación
                    ni tarjetas.

  245               Hace explícita la inicialización de captura A-Go-Go
                    TEAM en el Asistente Operativo: tras emitir tarjetas
                    muestra Iniciar captura, detecta estados
                    parciales/inconsistentes y sólo después permite pasar
                    a revisar captura y conciliación, sin alterar Stroke
                    Play ni Stableford.

  246               Homologa A-Go-Go con Stroke Play/Stableford haciendo
                    atómica la emisión + inicialización digital,
                    generaliza el diagnóstico de inicialización en el
                    Asistente y bloquea la captura física si la
                    estructura digital de la ronda no está íntegra,
                    preservando NRQ cuando la sesión existe pero no fue
                    usada.

  247               Enriquece el payload oficial de tarjetas A-Go-Go TEAM
                    con quién marca a cada equipo y qué jugador propio
                    marca al oponente, reutilizando las asignaciones
                    activas sin alterar captura, scoring ni el contrato
                    PLAYER.

  248               Blinda la revisión digital A-Go-Go TEAM: una disputa
                    activa no puede ser sobrescrita por el marcador y la
                    autocaptura `self_team` no admite confirmación ni
                    disputa contra el propio equipo.

  249               Ordena el cierre formal A-Go-Go: una ronda sólo queda
                    lista para cierre después de cerrar formalmente todas
                    sus categorías y el Asistente prioriza ese paso.

  250               Completa el reporte congelado de cierre por categoría
                    exponiendo número y fecha de ronda desde el propio
                    cierre formal, sin recalcular resultados ni consultar
                    leaderboard vivo.

  251               Agrega reporte operativo A-Go-Go por categoría con
                    todos los scores de tarjeta física por hoyo en una
                    sola fila por equipo, ordenado por ranking Gross/Neto
                    y disponible sin depender del cierre de categoría.

  252               Corrige el countback por tarjeta para usar los hoyos
                    reglamentarios y reordena el leaderboard A-Go-Go
                    después de aplicar finalRank de desempate.

  253               Refuerza la capacidad de equipos en asignaciones y
                    reasignaciones: valida el cupo real según
                    `jugadores_por_equipo`, cuenta ocupación activa
                    incluyendo roster pendiente/confirmado y bloquea
                    sobrecupos de forma transaccional sin impedir
                    movimientos que no aumentan ocupación.

  254               Formaliza las franjas de hándicap como prerrequisito
                    de configuración: agrega un validador global
                    independiente del orden de captura, detecta rangos
                    invertidos, huecos, traslapes y extremos abiertos
                    inválidos, y lo integra a la
                    confirmación/configuración operativa sin exigir un
                    límite inferior universal.

  255               Corrige la seguridad del validador de franjas de
                    hándicap retirando `EXECUTE` a `anon` y conservándolo
                    únicamente para roles autorizados, sin cambiar su
                    lógica ni sus resultados.

  256               Establece el inicio formal del torneo como frontera
                    competitiva: agrega estado de preparación para
                    iniciar, incorpora `START_TOURNAMENT` al Asistente y
                    bloquea scores competitivos, captura física y
                    conciliación antes de que el torneo esté `en_curso`,
                    permitiendo sólo la inicialización técnica previa
                    necesaria.

  257               Hace del campo de golf la fuente de verdad del club
                    del torneo y elimina `duracion_dias`: el club se
                    deriva automáticamente del campo seleccionado, la
                    configuración mínima exige campo válido y se preserva
                    el provisionamiento comercial sin alterar el campo
                    específico de cada ronda.

  258               Impide congelar un torneo si alguna ronda activa no
                    tiene modalidad de salida definida o al menos un
                    turno activo; integra estas validaciones al preview
                    de congelamiento sin modificar los datos
                    competitivos.

  259               Completa el contrato de
                    `obtener_estado_inicio_torneo_256` después de iniciar
                    o finalizar el torneo, devolviendo siempre todos los
                    campos de preparación y evitando falsos avisos de
                    frontend por respuestas parciales.

  260               Corrige el orden del Asistente para colocar
                    `START_TOURNAMENT` inmediatamente antes de la primera
                    captura competitiva, preservando dependencias
                    previas, modalidades Shotgun/Tee Times soportadas y
                    el flujo específico de A-Go-Go TEAM.

  261               Convierte la configuración de desempates en requisito
                    formal antes de confirmar la configuración del
                    torneo: valida la secuencia R&A oficial por tipo de
                    resultado, normaliza la configuración global del
                    torneo y agrega `TIEBREAK_CONFIGURATION` al Asistente
                    antes de `CONFIGURATION_CONFIRMATION`.

  262               Agrega compatibilidad temporal para torneos cuya
                    configuración ya había sido confirmada antes del
                    nuevo contrato de desempates: el Asistente considera
                    cumplido ese paso por antecedente de
                    `configuracion_finalizada_at`, sin relajar la
                    validación estricta para torneos nuevos ni reescribir
                    históricos.

  263               Incorpora `ROUND_CONFIGURATION` como paso explícito
                    del Asistente antes de congelar: valida número de
                    rondas, fecha, campo, formato competitivo efectivo,
                    Handicap Allowance, modalidad de salida, turno activo
                    y existencia de un motor de salida soportado; los
                    torneos ya congelados quedan reconocidos como
                    históricos válidos.

  264               Separa en el Asistente la operación que antes
                    aparecía como "Captura y conciliación" en dos pasos
                    reales: `ROUND_PHYSICAL_CAPTURE` y
                    `ROUND_RECONCILIATION`; distingue tarjetas físicas
                    pendientes, conciliación requerida y casos NRQ,
                    reutilizando la infraestructura común de Stroke Play,
                    Stableford y A-Go-Go.

  265               Formaliza el cierre competitivo común de ronda en
                    cuatro etapas: Resultados → Cierre de categorías →
                    Publicación de resultados → Cierre de ronda; exige
                    backend que todas las categorías estén cerradas y
                    publicadas antes del cierre final y conserva como
                    válidos los cierres históricos ya formalizados.

  266               Endurece las dependencias del Asistente Operativo:
                    elimina esperas hacia el paso obsoleto
                    `ROUND_SCORING`, difiere la evaluación competitiva
                    profunda hasta completar conciliación, normaliza
                    `START_TOURNAMENT` cuando sólo espera prerrequisitos
                    normales y evita bloqueos/crashes prematuros sin
                    modificar datos ni reglas competitivas.

  267               Corrige el validador estructural de Rondas para
                    respetar que A-Go-Go TEAM (`equipo` + `team_stroke`)
                    no utiliza Handicap Allowance individual: permite
                    `NULL` en ese motor, conserva la exigencia 0--100
                    para Stroke Play/Stableford y alinea el Asistente con
                    el contrato de congelamiento establecido en la
                    Migración 218.

  268               Corrige la secuencia del Asistente A-Go-Go colocando
                    HCP TEAM antes del congelamiento: HCP TEAM espera
                    inscripciones cerradas y Rondas completas, el
                    congelamiento espera HCP TEAM CURRENT y Armar grupos
                    permanece después del freeze, eliminando la
                    dependencia circular sin cambiar el motor de
                    congelamiento ni el cálculo competitivo.

  269               Habilita la corrección controlada de HCP declarado en
                    A-Go-Go TEAM después del congelamiento y antes de
                    iniciar el torneo: conserva los snapshots históricos,
                    invalida/recalcula HCP TEAM, revalida salidas cuando
                    corresponde, versiona tarjetas ya emitidas sin
                    cambiar su `score_card_id` y devuelve las tarjetas
                    afectadas para reimpresión.

  270               Corrige el flujo HCP post-emisión de la 269
                    activando, sólo cuando ya existen tarjetas oficiales,
                    el guard transaccional
                    `app.revisar_tarjeta_team_post_emision`; permite la
                    reapertura auditada, revalidación y revisión 215 sin
                    debilitar el trigger protector ni alterar snapshots o
                    tarjetas históricas.

  271               Habilita sustitución administrativa directa de
                    integrantes A-Go-Go después del freeze y antes de
                    iniciar el torneo: reutiliza o crea al jugador en
                    catálogo, genera una nueva inscripción sin cobro
                    conservando cobertura y cadena histórica, fija la
                    marca de salida, recalcula HCP TEAM, revalida salidas
                    y versiona tarjetas emitidas cuando corresponde, sin
                    depender de capitán ni confirmación del sustituto.

  272               Corrige la seguridad de las funciones de sustitución
                    administrativa 271: revoca explícitamente EXECUTE a
                    anon y conserva acceso únicamente para authenticated
                    y service_role; no modifica lógica ni datos
                    competitivos.

  273               Corrige el guard de marcadores TEAM para
                    sustituciones post-emisión: mantiene la validación
                    estricta de pertenencia al snapshot vigente para
                    asignaciones activas, pero permite cerrar como ended
                    una asignación histórica del jugador saliente sin
                    reescribir evidencia previa.

  274               Agrega un detector de sólo lectura para la
                    composición A-Go-Go antes del inicio: identifica
                    equipos activos con un solo integrante, jugadores
                    sueltos, equipos vacíos e inscripciones activas sin
                    equipo, fija mínimo competitivo de 2 y expone un
                    estado agregado sin modificar HCP TEAM, salidas,
                    tarjetas ni resultados.

  275               Integra el detector 274 con START_TOURNAMENT: el
                    estado de inicio expone la composición A-Go-Go y
                    iniciar_torneo bloquea desde backend cualquier inicio
                    con equipos incompletos o jugadores activos sin
                    equipo; no resuelve ni modifica composiciones.

  276               Habilita la baja administrativa auditada de un
                    integrante A-Go-Go después del Freeze y antes de
                    START_TOURNAMENT; inactiva su inscripción, cancela su
                    slot, deja HCP TEAM obsoleto mediante el trigger
                    existente y reabre salidas validadas, manteniendo la
                    composición y tarjetas pendientes de regularización
                    antes del inicio.

  277               Corrige la baja administrativa 276 para preservar
                    intactas las salidas validadas y las tarjetas ya
                    emitidas mientras el equipo incompleto sigue
                    pendiente de resolución; la baja sólo actualiza
                    composición/roster/auditoría y deja START_TOURNAMENT
                    bloqueado por 274--275 hasta que el organizador
                    decida la resolución.

  278               Amplía el detector 274 para controlar globalmente la
                    composición A-Go-Go: detecta equipos excepción de
                    tamaño normal +1, permite como máximo uno por torneo,
                    detecta sobrecupos inválidos y vuelve a marcar la
                    composición como pendiente si coexisten un equipo
                    excepción y cualquier jugador suelto.
                    START_TOURNAMENT hereda el bloqueo mediante
                    compositionReady. No mueve jugadores, salidas ni
                    tarjetas.

  279               Reequilibrio A-Go-Go 3+1 → 2+2 post-Freeze/pre-START:
                    el administrador elige un integrante del único equipo
                    excepción de 3 y lo mueve al equipo incompleto de 1.
                    Conserva ambos equipos y sus salidas físicas,
                    recalcula HCP TEAM, renueva la validación lógica y
                    revisa tarjetas/markers si ya fueron emitidos. Sólo
                    las tarjetas de los dos equipos afectados se
                    devuelven para reimpresión material. No cambia
                    categorías y START_TOURNAMENT sigue dependiendo del
                    detector global 278.

  280               A-Go-Go: elimina las firmas de jugador/equipo y
                    marcador como requisito competitivo. Resultado
                    oficial y leaderboard pasan a depender de tarjeta
                    física CAPTURED + conciliación COMPLETED + score
                    válido; las firmas pueden conservarse como datos
                    históricos/informativos, pero no participan en ningún
                    STOP competitivo. La primera versión preparada de 280
                    abortó sin aplicar cambios; se sustituyó por la
                    versión corregida. Corrige el caso CENIR/2026 sin
                    alterar sus datos.

  281               A-Go-Go: permite incorporar, después del Freeze y
                    antes de START_TOURNAMENT y de la emisión oficial de
                    tarjetas, al único jugador suelto de un equipo
                    incompleto dentro de otro equipo normal completo,
                    creando la única excepción +1 permitida. Conserva
                    histórico el equipo origen, recalcula HCP TEAM del
                    destino y renueva la validación lógica de salidas
                    cuando corresponde.

  282               Corrige la RPC 281 para permitir de forma controlada
                    el movimiento que crea la excepción +1 aun cuando el
                    equipo destino ya está en su cupo normal. Usa
                    únicamente la válvula oficial del trigger de cupo
                    durante ese UPDATE y mantiene intacta la protección
                    global de capacidad.

  283               Corrige en la RPC 281 la relación usada para
                    localizar grupos vacíos: enlaza grupo → turno → ronda
                    → torneo, evitando consultar un tournament_id
                    inexistente en tournament_round_shifts. No cambia la
                    regla competitiva de la excepción +1.

  284               A-Go-Go: incorpora el retiro competitivo auditado de
                    un equipo que quedó incompleto con exactamente un
                    integrante activo, después del Freeze, antes de
                    START_TOURNAMENT y antes de emitir tarjetas
                    oficiales. Conserva equipo, jugador e HCP como
                    historia, los retira de la competencia oficial y
                    actualiza sus asignaciones lógicas de salida.

  285               Corrige la reapertura de validaciones de salida
                    dentro del retiro competitivo 284: sustituye la
                    transición inválida validated → superseded por el
                    flujo autorizado validated → reopened, registrando
                    fecha, administrador y motivo, y conserva la
                    revalidación formal posterior sin debilitar el
                    trigger de protección. Amplía el CHECK de auditoría
                    tournament_team_composition_changes.change_type para
                    admitir team_competitive_withdrawal, requerido por el
                    retiro competitivo de equipos A-Go-Go de la 284/285.
                    Conserva sin cambios todos los valores históricos
                    previamente permitidos y no modifica datos, permisos
                    ni la lógica de la RPC de retiro.

  287               Crea el catálogo comercial de tarifas de uso de
                    plataforma, con modalidad por día o por torneo,
                    importe, moneda, vigencia, estado y una única tarifa
                    default activa; su mantenimiento queda reservado al
                    Superadmin.

  288               Crea asignaciones de tarifa especial por correo de
                    organizador, con vigencia, estado y protección contra
                    traslapes activos; su mantenimiento queda reservado
                    al Superadmin.

  289               Crea la configuración comercial global de plataforma,
                    separada de parámetros deportivos, con porcentaje de
                    IVA configurable y correo administrativo para
                    notificaciones comerciales.

  290               Crea la contratación comercial previa al torneo y una
                    RPC segura que resuelve tarifa especial/default,
                    calcula días, subtotal, IVA y total en backend y
                    congela ese snapshot económico antes del pago.

  291               Crea intentos de pago propios para contrataciones de
                    plataforma, separados de pagos de jugadores, copiando
                    monto y moneda del snapshot contractual y permitiendo
                    múltiples intentos con referencias del proveedor.

  292               Finaliza en backend una contratación con pago
                    aprobado de forma atómica e idempotente: confirma el
                    intento, marca el contrato pagado, crea el torneo
                    activo y asigna al organizador como administrador del
                    torneo.

  293               Agrega un simulador temporal de resultado de pago de
                    plataforma, usable por el organizador sobre sus
                    propias contrataciones, con escenarios APROBADO y
                    RECHAZADO y reutilizando la finalización definitiva
                    de la 292.

  294               Separa la vigencia comercial del torneo de sus fechas
                    y estados deportivos, registrando el periodo
                    operativo de cada torneo contratado y exponiendo
                    helpers para identificar acceso vigente, vencido o
                    legacy.

  295               Aplica en backend el modo sólo lectura a torneos
                    contratados cuya vigencia comercial terminó,
                    bloqueando mutaciones en el mismo perímetro operativo
                    protegido para torneos cancelados y preservando los
                    torneos legacy.

  296               Habilita el autorregistro backend de organizadores
                    después de verificar el correo con Supabase Auth,
                    creando o vinculando admin_users sin asignar todavía
                    permisos sobre ningún torneo.

  297               Crea una cola/auditoría idempotente de notificaciones
                    comerciales cuando un pago genera un torneo, usando
                    el correo administrativo configurable sin hacer
                    depender la creación del torneo del envío externo de
                    email.

  298               Adapta la confirmación y reapertura de configuración
                    a torneos de autoservicio ya activos, conservando la
                    confirmación explícita antes de abrir inscripciones y
                    limitándola al estado deportivo EN PLANIFICACIÓN.

  299               Elimina la confirmación manual como requisito del
                    flujo de autoservicio: al abrir inscripciones valida
                    en vivo configuración y desempates, y ajusta el
                    Asistente Operativo sin alterar el flujo histórico.

  300               Retira el flujo comercial histórico de
                    provisionamiento, confirmación manual de pago y
                    liberación; conserva los datos históricos y
                    simplifica la protección de estado de servicio sin
                    alterar el autoservicio ni la operación deportiva.

  301               Crea el catálogo transversal de Premios Especiales
                    del Torneo con cinco premios estándar protegidos y
                    premios personalizados por organizador, definiendo
                    tipo de valor, unidad sugerida y criterio de
                    comparación sin vincularlo al scoring ni al ciclo
                    competitivo.

  302               Configura Premios Especiales por torneo, ronda y
                    hoyo, guardando snapshots del catálogo y reglas
                    operativas como unidad, referencia, fairway, green y
                    golpe evaluado, sin integrarlos al scoring, freezes
                    ni ciclo competitivo.

  303               Crea estaciones operativas de Premios Especiales por
                    torneo, ronda y hoyo, registra un responsable externo
                    sin exigir cuenta administrativa y permite que varios
                    premios compartan la misma estación, manteniendo la
                    consistencia premio-estación y el aislamiento
                    deportivo.

  304               Incorpora acceso QR independiente y seguro por
                    estación de Premios Especiales, con token aleatorio
                    propio, generación/rotación y desactivación
                    controladas, además de una consulta pública mínima
                    por bearer token sin reutilizar QR de jugadores ni
                    tarjetas.

  305               Incorpora el roster operativo por ronda para Premios
                    Especiales, prefiriendo la última validación vigente
                    de salidas y expandiendo equipos a sus jugadores;
                    agrega captura móvil por QR con valor, testigo,
                    corrección e invalidación auditadas sin borrar el
                    historial.

  306               Agrega el **REPORTE PROVISIONAL EN LÍNEA** de Premios
                    Especiales para organizador/superadmin, agrupado por
                    ronda y hoyo, con candidatos válidos ordenados según
                    MENOR_ES_MEJOR, MAYOR_ES_MEJOR o SOLO_REGISTRO,
                    mostrando inválidos e historial sin adjudicar
                    ganador.

  307               Incorpora mensajería bidireccional append-only entre
                    el responsable de una estación de Premios Especiales
                    y el organizador/superadmin, usando QR para el
                    responsable y autenticación administrativa para el
                    organizador, con contexto opcional de premio y sin
                    edición ni borrado.

  308               Implementa la adjudicación oficial y explícita de
                    Premios Especiales mediante versiones inmutables por
                    premio, posiciones asociadas a candidatos válidos,
                    soporte para empates, snapshots de
                    jugador/valor/unidad y anulación con motivo sin
                    borrar el histórico.

  309               Convierte el catálogo global de Premios Especiales en
                    administrable por Superadmin, permitiendo mantener
                    los premios estándar sin borrarlos ni desactivarlos e
                    incorporando defaults operativos de referencia,
                    fairway, green y golpe evaluado para futuras
                    configuraciones de torneo.

  310               Corrige la configuración de Premios Especiales por
                    torneo para que nombre, tipo de valor y criterio se
                    capturen del catálogo únicamente al crear la
                    asociación y permanezcan como snapshots inmutables en
                    ediciones posteriores. Permite además editar datos
                    operativos históricos aunque el premio de catálogo
                    haya sido desactivado después.

  311               Agrega una consulta pública controlada por QR para
                    que el responsable de una estación de Premios
                    Especiales vea desde cualquier dispositivo todos los
                    registros de esa estación y su historial, sin abrir
                    acceso directo a las tablas operativas.

  312               Corrige el ranking del REPORTE PROVISIONAL EN LÍNEA
                    de Premios Especiales: los empates se determinan
                    únicamente por el valor competitivo, por lo que
                    valores idénticos comparten posición; fecha e
                    identificador quedan sólo como orden visual
                    determinista y SOLO_REGISTRO no recibe posición
                    competitiva.

  313               Corrige la generación/rotación del QR de estaciones
                    de Premios Especiales calificando explícitamente
                    extensions.gen_random_bytes(32), ya que pgcrypto está
                    instalado en el esquema extensions y la RPC 304
                    conserva un search_path restringido a public y
                    pg_temp.

  314               Formaliza un ciclo operativo obligatorio por ronda
                    (PENDIENTE -\> EN JUEGO -\> FINALIZADA), incluso en
                    torneos de una sola ronda; exige inicio manual antes
                    de captura competitiva, reutiliza el cierre formal
                    existente como finalización de ronda, impide iniciar
                    una ronda posterior mientras la anterior siga
                    abierta, incorpora el estado al Asistente y permite
                    reprogramar la fecha sólo mientras la ronda esté
                    pendiente, respetando la fecha de inicio del torneo y
                    la última ronda finalizada.

  315               Registra Best Ball como motor operativo reservado en
                    el registro de inicio, inicialmente inactivo, sin
                    alterar los motores Stroke, Stableford ni A-Go-Go.

  316               Crea el snapshot oficial Best Ball por tarjeta TEAM y
                    sus integrantes, vinculando a cada jugador con su
                    snapshot individual de hándicap de la ronda.

  317               Incorpora validación, contrato de salida y emisión
                    oficial de tarjetas TEAM para Best Ball mediante
                    dispatchers explícitos y aislados.

  318               Inicializa la captura digital Best Ball por
                    integrante y hoyo en tablas propias, manteniendo la
                    sesión común de tarjeta y haciendo atómica emisión +
                    inicialización.

  319               Integra marcadores TEAM Best Ball con asignación
                    circular o autocaptura para equipo aislado, y hace
                    atómica la emisión + captura + marcadores.

  320               Implementa captura digital Best Ball por
                    jugador/hoyo, incluyendo SCORE, PICKUP, confirmación
                    y disputa, y bloquea captura competitiva fuera de
                    ronda EN JUEGO.

  321               Calcula en tiempo real Best Gross y Best Net por hoyo
                    desde los scores individuales y el Playing Handicap
                    congelado de cada integrante.

  322               Expone la tarjeta digital Best Ball y el payload
                    administrativo TEAM, mostrando integrantes, scores,
                    Best Gross/Net y relaciones de marcador.

  323               Incorpora recepción y captura de tarjeta física Best
                    Ball por integrante/hoyo en evidencia propia,
                    reutilizando el contenedor común de recepción.

  324               Implementa conciliación Best Ball por jugador/hoyo
                    entre evidencia digital y física, con resoluciones y
                    eventos propios sin contaminar las tablas comunes.

  325               Construye el resultado oficial TEAM Best Ball
                    Gross/Net desde evidencia individual conciliada, sin
                    persistir un score TEAM por hoyo ni utilizar HCP
                    TEAM.

  326               Incorpora leaderboard Best Ball por ronda y
                    categoría, con clasificaciones Gross/Net, posiciones
                    TEAM y empates preservados, consumiendo sólo
                    resultado oficial.

  327               Integra desempates Best Ball Gross/Net TEAM
                    reutilizando las reglas y resoluciones comunes, con
                    soporte de resolución manual sin recalcular scores.

  328               Integra Best Ball al cierre y publicación competitiva
                    común por categoría y ronda, incluyendo outcomes
                    terminales y estado de formalización.

  329               Permite revisar la composición Best Ball después de
                    emitir tarjetas sólo mientras la ronda esté
                    PENDIENTE; conserva la tarjeta, reconstruye evidencia
                    PENDING y marcadores, y registra auditoría propia sin
                    HCP TEAM.

  330               Bloquea permanentemente el campo del torneo desde la
                    primera inscripción mediante un latch persistente,
                    conservando la asignación automática de marcas de
                    salida. El bloqueo permanece aunque posteriormente se
                    elimine la inscripción que lo originó; el backfill
                    excluye torneos cancelados históricos.

  331               Establece el campo del torneo como única fuente de
                    verdad para todas sus rondas: toda ronda nueva o
                    reactivada hereda automáticamente `campo_golf_id` del
                    torneo y el backend impide que una ronda conserve o
                    reciba un campo distinto, preservando históricos
                    cancelados y la firma existente del RPC de rondas.

  332               Incorpora la Fase 1 del workflow operativo
                    materializado como infraestructura paralela y
                    reconstruible para torneos y rondas, alineada con el
                    autoservicio vigente: en torneos pagados la
                    configuración se considera lista por validación real
                    al abrir inscripciones, sin exigir el antiguo hito
                    manual de finalizar configuración. Materializa además
                    inscripciones, Freeze, inicio y finalización del
                    torneo y, por ronda, configuración, grupos, salidas,
                    tarjetas, inicialización de captura, lifecycle,
                    cierre competitivo y corte cuando aplica; conserva
                    compatibilidad con torneos legacy y auditoría de
                    transiciones desde la evidencia real existente.

  333               Alinea el workflow operativo materializado con el
                    autoservicio vigente: los torneos con contratación
                    PAGADA ya no dependen del hito histórico
                    configuracion_finalizada_at. Mientras permanecen en
                    planificación, CONFIGURATION refleja la validación
                    mínima real y la configuración de desempates exigidas
                    por abrir_inscripciones_torneo; si el torneo ya abrió
                    inscripciones o avanzó, CONFIGURATION se materializa
                    como COMPLETE. Conserva sin cambios el comportamiento
                    legacy y el resto de la proyección deportiva de la
                    332.

  334               Repara una recursión accidental detectada durante el
                    diagnóstico del nuevo workflow operativo: el alias
                    histórico pre-Best Ball del estado de cierre
                    competitivo regresaba a la función pública y
                    provocaba stack depth limit exceeded en modalidades
                    no Best Ball. El alias pre328 vuelve a delegar en la
                    cadena histórica pre249 → pre213, conservando intacto
                    el tratamiento específico de Best Ball y sin
                    reconstruir torneos ni modificar datos deportivos.

  335               Amplía el workflow operativo materializado sin
                    sustituir todavía al Asistente público. Incorpora
                    como proyección explícita las franjas de hándicap,
                    configuración de desempates, HCP TEAM cuando aplica,
                    captura física, conciliación, resultados, cierre por
                    categoría y publicación. Conserva las fuentes de
                    verdad deportivas existentes y difiere las consultas
                    profundas de resultados/formalización hasta que la
                    conciliación esté completa. No realiza reconstrucción
                    masiva: la nueva proyección se materializa únicamente
                    al reconciliar un torneo.
  -----------------------------------------------------------------------

## Pendientes

### Premios especiales del torneo

-   Integrar la adjudicación oficial de Premios Especiales en frontend,
    usando las RPC de la Migración 308, manteniendo selección explícita,
    empates, versiones históricas y anulación sin borrar adjudicaciones.
-   Evaluar posteriormente publicación/consulta para jugadores y
    mecanismos de notificación, sin mezclar estos premios con
    leaderboards deportivos.

### A-Go-Go / Scramble

-   Continuar la verificación E2E del flujo pre-inicio de composición
    A-Go-Go ya implementado: baja administrativa, resolución de equipos
    incompletos, excepción +1, reequilibrio 3+1 → 2+2 y retiro
    competitivo.
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
-   Best Ball queda implementado en backend hasta la Migración 329 como
    motor separado; las Migraciones 343, 344 y 346 completan piezas de
    previsualización, captura física y sustitución administrativa
    post-emisión. Queda pendiente completar su integración UI/E2E.
    Shamble permanece como motor futuro separado.

### Best Ball

-   Completar en frontend la integración del motor Best Ball
    implementado en backend desde las Migraciones 315--329 y su
    previsualización de tarjetas de la Migración 343, reutilizando
    infraestructura común sólo donde corresponda.
-   Ejecutar prueba E2E completa: configuración, equipos, emisión,
    marcadores, tarjeta digital, captura física, conciliación,
    resultados, desempates, cierre/publicación y revisiones post-emisión
    antes del inicio.
-   No permitir cambios de composición una vez que la ronda esté EN
    JUEGO.

### Generales

-   Retirar del frontend administrativo los controles y textos del flujo
    histórico de provisionamiento/liberación, dejando el autoservicio
    como flujo normal.
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
-   Continuar la prueba E2E del autoservicio comercial desde pago hasta
    apertura de inscripciones y operación completa del torneo,
    verificando que el Asistente Operativo sea congruente en cada etapa.
-   Mantener pendientes los ajustes del motor de salidas que todavía
    requieran acomodación manual, balanceo o validación integral antes
    de tarjetas.

## Regla de mantenimiento

A partir de la siguiente migración, agregar **una sola entrada breve por
migración** y actualizar **Pendientes** cuando corresponda. No incluir
nombres de archivos SQL ni documentación exhaustiva del código en este
README.

## Migración 336 --- Reparar recursión histórica del leaderboard operativo pre328

**Objetivo.** Corregir la recursión accidental del alias histórico
`_obtener_leaderboard_operativo_ronda_pre328(uuid)`. El fallback de
`obtener_leaderboard_operativo_ronda(uuid)` llegaba a `pre328` y
`pre328` regresaba a la misma función pública.

**Cambio.** `pre328` delega ahora en
`_obtener_leaderboard_operativo_ronda_pre211(uuid)`, identificado en
Supabase como su verdadero antecedente previo a Best Ball.

**Cadena resultante.** La RPC pública conserva Best Ball mediante
`obtener_leaderboard_best_ball_ronda_328(uuid)` y para el resto utiliza
`pre328 → pre211`.

**Seguridad y alcance.** Se conservan intactos `auth.uid()` y
`puede_administrar_congelamiento_torneo()` de `pre211`. No se modifican
datos, motores deportivos, workflow materializado, Asistente operativo
ni RPC públicas; tampoco se reconstruyen torneos.

**Verificación.** Se comprueba la cadena `pública → pre328 → pre211`,
ausencia de retorno recursivo desde `pre328`, conservación de Best Ball,
conservación de controles de seguridad y ausencia de escrituras. Los
totales del workflow deben permanecer invariantes.

**Estado confirmado posteriormente:** ejecutada y verificada en
Supabase.

## Migración 337 --- Workflow con evidencia persistida y secuencias corregidas

**Objetivo.** Separar definitivamente la orientación del Asistente de la
validación deportiva. La reconstrucción materializada del workflow deja
de invocar los motores profundos de resultados, leaderboard y desempates
para decidir el avance operativo.

**Cambio.** Se incorpora `reconstruir_workflow_extendido_337(uuid)`.
Parte de la proyección base 332/333, conserva las validaciones livianas
de franjas, desempates configurados, HCP TEAM, captura física y
conciliación, y obtiene los estados posteriores a conciliación mediante
evidencia ya persistida en cierres de categoría, publicaciones y cierre
competitivo de ronda.

**Frontera deportiva.** Al completar conciliación, `ROUND_RESULTS` queda
`AVAILABLE`. El workflow no declara por sí mismo que los resultados o
desempates estén competitivamente resueltos. Las RPC deportivas
existentes siguen siendo la autoridad que permite o rechaza los cierres.

**Secuencias.** Se corrigen las fórmulas introducidas en 335. Para la
ronda 1: HCP TEAM 205, captura física 252, conciliación 254, resultados
256, cierre de categorías 258, publicación 259 y cierre competitivo 260.

**Seguridad y alcance.** `reconciliar_workflow_torneo_332(uuid)`
conserva `auth.uid()` y `puede_administrar_congelamiento_torneo()` y
delega a 337. No se modifican motores deportivos ni sus permisos, no se
alteran datos deportivos y no se reconstruye ningún torneo
automáticamente.

**Estado confirmado:** ejecutada y verificada en Supabase. POLLA
MALANQUIN SEPTIEMBRE quedó con 19 nodos y evidencia persistida; la
reconstrucción 337 devolvió `ok=true` sin recursión ni timeout.

## Migración 338 --- Cutover del Asistente al workflow materializado

**Objetivo.** Retirar al RPC público del Asistente Operativo de la
cadena histórica `v22 → ... → core` y convertir el workflow
materializado 337 en su fuente operativa.

**Cambio.** Se incorpora `_adaptar_asistente_workflow_338(uuid)`. El
adaptador reconcilia la proyección mediante
`reconciliar_workflow_torneo_332(uuid)`, lee `tournament_workflow_nodes`
y genera el contrato JSON esperado por la interfaz: `stage`, `status`,
`actor`, `progress`, `summary`, `nextAction`, `blockers`, `warnings`,
`steps` y `rounds`. `obtener_asistente_operativo_torneo(uuid)` pasa a
delegar exclusivamente en este adaptador.

**Compatibilidad.** Cada paso conserva `workflowStatus` con la semántica
337 (`COMPLETE`, `AVAILABLE`, `IN_PROGRESS`, `BLOCKED`) y expone
`status` compatible con la interfaz histórica (`COMPLETE`, `PENDING`,
`BLOCKED`). No se crean nuevas acciones deportivas; las acciones del
Asistente sólo navegan a los flujos existentes.

**Siguiente acción.** Se prioriza el primer nodo `AVAILABLE` por
secuencia; si no existe, el primer `IN_PROGRESS` y finalmente el primer
`BLOCKED`. Esto permite que una ronda siga `IN_PROGRESS` sin ocultar
`ROUND_RESULTS` cuando los resultados ya están disponibles. Para POLLA
MALANQUIN SEPTIEMBRE, el estado 337 actual debe orientar a
`ROUND_RESULTS`.

**Seguridad y alcance.** Se conservan autenticación y permisos. La
reconciliación sólo actualiza la proyección workflow. No se modifican
Stroke Play, Stableford, A-Go-Go, Best Ball, tarjetas, resultados,
desempates ni cierres deportivos. No se hace backfill masivo ni se
hardcodea POLLA en la función; POLLA se utiliza únicamente como caso
canónico de verificación.

**Estado al documentar:** preparada para ejecución manual. No se
considera ejecutada ni verificada hasta comprobarla posteriormente en
Supabase.

------------------------------------------------------------------------

## Migración 339 --- Inscripción confirmada con pago pendiente / pago el día del evento

**Objetivo.** Separar formalmente la condición de estar inscrito de la
condición de haber pagado, para torneos que excepcionalmente permiten
liquidar la inscripción el día del evento, sin utilizar pre-reservas y
sin alterar los motores deportivos.

**Cambios de base de datos.** -
`tournaments.permitir_pago_dia_evento boolean NOT NULL DEFAULT false`:
opt-in por torneo; ningún torneo histórico queda habilitado
automáticamente. - `tournament_registrations.estado_pago`: `PENDIENTE` /
`PAGADO`, con `PAGADO` como default para conservar el comportamiento
histórico. - Las inscripciones existentes se clasifican como `PAGADO`
mediante `DEFAULT 'PAGADO'` al crear la columna, **sin ejecutar
UPDATE/backfill sobre `tournament_registrations`**. - Los torneos
cancelados y vencidos quedan estrictamente en sólo lectura: la migración
no intenta mutar sus inscripciones y por tanto no dispara los guards
operativos existentes. - `monto_pagado`, `fecha_pago`, `medio_pago` y
`referencia_pago` pasan a admitir `NULL`, pero una restricción 339
obliga a que los cuatro sean `NULL` cuando el estado sea `PENDIENTE` y
los cuatro estén completos cuando sea `PAGADO`. -
`inscribir_pago_dia_evento_339(uuid,uuid)`: RPC autenticada para
jugador. Sólo funciona con torneo activo, inscripciones abiertas y
`permitir_pago_dia_evento=true`; crea una `tournament_registration`
activa real con pago pendiente. Las validaciones existentes de perfil,
duplicados, cupos, categoría, marca y Freeze siguen siendo autoridad
mediante los triggers actuales. -
`registrar_pago_inscripcion_339(uuid,numeric,medio_pago_torneo,text)`:
RPC administrativa para Superadmin/organizador/admin del club. Registra
el cobro real y cambia `PENDIENTE → PAGADO`. No modifica jugador,
categoría, marca, equipo ni estado competitivo.

**Decisiones de arquitectura.** - `pago_dia_evento` no se representa
como `efectivo`; el medio real se registra al cobrar. - No se utiliza
`tournament_pre_reservations`: el jugador ya está confirmado dentro del
torneo. - No se toca Stroke Play, Stableford, A-Go-Go, Best Ball,
Freeze, grupos, salidas, tarjetas, captura, conciliación, resultados,
desempates, cierre de ronda ni workflow. - El control completo de
check-in/no-show queda fuera de esta migración. - La habilitación para
POLLA MALANQUIN SEPTIEMBRE se hará explícitamente después de verificar
la migración; 339 no la activa automáticamente.

**Archivos.** - `339_inscripcion_confirmada_pago_pendiente.sql` -
`339_verificacion_inscripcion_confirmada_pago_pendiente.sql` -
`README_TEE_CENTRAL_HASTA_339_COMPLETO.md`

------------------------------------------------------------------------

## Migración 340 --- Warning no bloqueante del Asistente por pagos pendientes

**Objetivo.** Mantener visible en el Asistente Operativo un aviso
administrativo mientras exista al menos una inscripción activa con
`estado_pago = 'PENDIENTE'`, sin convertir el pago en requisito del
workflow deportivo.

**Cambios.** - Se agrega
`_adaptar_asistente_pagos_pendientes_340(uuid)`, que toma como base
íntegra `_adaptar_asistente_workflow_338(uuid)`. - El RPC público
`obtener_asistente_operativo_torneo(uuid)` pasa a utilizar el adaptador
340. - Si existen pagos pendientes activos, `warnings` incorpora
`PENDING_PAYMENTS`, con cantidad de jugadores, `severity=WARNING` y
`blocking=false`. - `summary.warnings` refleja la cantidad de warnings
devueltos. - Si no quedan pagos pendientes, el warning desaparece
automáticamente. - `schemaVersion` pasa a 340; `assistantSource` y el
workflow materializado 337 se conservan.

**Regla de no bloqueo.** El warning no modifica `blockers`,
`nextAction`, nodos, secuencias ni estados del workflow. No bloquea
Freeze, grupos, salidas, tarjetas, inicio de ronda, captura,
conciliación, resultados, cierres ni finalización.

**Archivos.** - `340_warning_asistente_pagos_pendientes.sql` -
`340_verificacion_warning_asistente_pagos_pendientes.sql` -
`README_TEE_CENTRAL_HASTA_340_COMPLETO.md`

------------------------------------------------------------------------

## Migración 341 --- Estructura completa de rondas antes de Freeze y acción del Asistente

**Objetivo.** Mantener intacta la protección de Freeze y hacer explícita
la regla operativa de que todas las rondas declaradas por
`numero_rondas` deben existir y estar activas antes de congelar el
torneo. Las rondas se siguen creando o reactivando una por una desde la
pestaña **Rondas**; no se generan automáticamente al crear el torneo.

**Regla estructural.** `numero_rondas` continúa siendo la declaración y
el máximo absoluto del torneo. Antes de Freeze pueden faltar rondas
mientras el torneo se encuentra en configuración. Al llegar al punto en
que el torneo debe congelarse, el workflow exige que estén creadas y
activas todas las rondas `1..numero_rondas`. Si falta alguna, Freeze
queda bloqueado por `ROUND_STRUCTURE`. Después de Freeze continúa
prohibido crear o reactivar rondas; la función
`crear_o_reactivar_siguiente_ronda(...)` no se modifica.

**Workflow.** Se agrega `reconstruir_workflow_extendido_341(uuid)`, que
conserva íntegramente 337 y materializa el nodo de torneo
`ROUND_STRUCTURE` con secuencia 25, entre `REGISTRATIONS` y `FREEZE`. El
nodo registra como evidencia el número de rondas declaradas, activas,
faltantes y si existe Freeze. `reconciliar_workflow_torneo_332(uuid)`
pasa a delegar en 341.

**Asistente.** Se agrega `_adaptar_asistente_rondas_341(uuid)`, que toma
como base `_adaptar_asistente_pagos_pendientes_340(uuid)` para no perder
el warning no bloqueante `PENDING_PAYMENTS`. Cuando
`ROUND_STRUCTURE=AVAILABLE`, el `nextAction` pasa a **Crear ronda N** y
dirige a `rondas`, donde N es la primera ronda declarada que todavía no
está activa. Una vez creada, la reconciliación recalcula la siguiente
faltante; cuando ya existen todas las rondas, `ROUND_STRUCTURE` queda
`COMPLETE` y Freeze puede continuar según sus demás requisitos.

**Freeze sin cambios.** 341 no abre excepciones al congelamiento, no
permite crear/reactivar rondas después de Freeze y no modifica la
semántica de `tournament_condition_freezes`. La reprogramación de fecha
existente permanece separada bajo las reglas ya implementadas. La hora
de ronda se revisará en una fase específica antes de modificarla.

**Fuera de alcance.** No se modifican cortes posteriores a una ronda,
Stroke Play, Stableford, A-Go-Go, Best Ball, HCP TEAM, grupos, salidas,
tarjetas, captura, conciliación, resultados, desempates, cierres
competitivos ni finalización. Los cortes multirronda continúan
pendientes de prueba E2E y se abordarán posteriormente.

**Frontend posterior.** Después de verificar 341 en Supabase, Lovable
deberá retirar **Generar rondas** de Información/configuración del
torneo y conservar la creación individual exclusivamente en **Rondas**.
Esa modificación frontend no forma parte del SQL 341.

**Archivos.** - `341_rondas_completas_antes_freeze_asistente.sql` -
`341_verificacion_rondas_completas_antes_freeze_asistente.sql` -
`README_TEE_CENTRAL_HASTA_341_COMPLETO.md`

**Estado al documentar:** preparada para ejecución manual. No se
considera ejecutada ni verificada hasta comprobarla posteriormente en
Supabase.

------------------------------------------------------------------------

## Migración 342 --- Corrección RPC de inscripción con pago el día del evento

**Origen del hallazgo.** La primera prueba funcional del flujo **Pago el
día del evento** devolvió `column tc.activo does not exist`. El
diagnóstico directo en PROD confirmó que `tournament_categories` no
tiene ni ha definido una columna `activo`, mientras que
`inscribir_pago_dia_evento_339(uuid,uuid)` la referenciaba.

**Corrección.** Se reemplaza únicamente la definición de
`inscribir_pago_dia_evento_339(uuid,uuid)`. La categoría se valida por
su asociación real: `tc.id = p_tournament_category_id` y
`tc.tournament_id = p_tournament_id`. No se inventa una bandera de
actividad inexistente.

Se conserva el resto del contrato 339: autenticación de jugador, torneo
activo, inscripciones abiertas, opción de pago en evento habilitada e
inserción con `estado_pago='PENDIENTE'` y datos de pago nulos. Las
reglas existentes de `tournament_registrations` continúan siendo
autoridad para las validaciones deportivas aplicables.

**Fuera de alcance.** No modifica tablas, Freeze, workflow 341,
Asistente, pagos pendientes 340, rondas, calendario, cortes ni motores
deportivos.

**Archivos.** - `342_fix_pago_evento_categoria_sin_activo.sql` -
`342_verificacion_fix_pago_evento_categoria_sin_activo.sql` -
`README_TEE_CENTRAL_HASTA_342_COMPLETO.md`

**Estado al documentar:** preparada para ejecución manual; pendiente de
verificación en PROD y de repetir la prueba funcional desde la interfaz.

------------------------------------------------------------------------

## Migración 343 --- Previsualización de tarjetas Best Ball

**Objetivo.** Permitir que el organizador revise correctamente las
tarjetas Best Ball antes de emitirlas, sin tratarlas como tarjetas
A-Go-Go.

**Qué hace.** Incorpora una previsualización propia para Best Ball por
equipos, mostrando el equipo, sus integrantes, sus hándicaps
individuales congelados, la salida y los hoyos de la ronda. Best Ball
continúa sin HCP TEAM. La emisión oficial conserva el flujo atómico ya
existente de tarjetas, captura digital y marcadores. Stroke Play,
Stableford y A-Go-Go mantienen sus previsualizaciones actuales.

**Estado al documentar:** ejecutada manualmente y verificada en PROD.

------------------------------------------------------------------------

## Migración 344 --- Lectura y progreso de captura física Best Ball

**Objetivo.** Completar la información necesaria para capturar una
tarjeta física Best Ball sin depender de los resultados de la tarjeta
digital.

**Qué hace.** La captura física Best Ball entrega el equipo, sus
integrantes y todos los hoyos necesarios para transcribir SCORE o PICKUP
por jugador. También corrige el progreso administrativo para contar los
resultados individuales esperados y capturados en Best Ball. Stroke
Play, Stableford y A-Go-Go conservan su comportamiento actual.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `total_a_pagar` en las 10 inscripciones pendientes de `POLLA
SEPTIEMBRE, 24`, todas por $1,000.00, con total esperado de $10,000.00;
la RPC `obtener_control_cobranza_pendiente_352(uuid)` quedó presente y
con `authenticated_execute=true`, `anon_execute=false` y
`public_execute=false`.

------------------------------------------------------------------------

## Migración 345 --- Notas opcionales al cerrar ronda

**Objetivo.** Permitir cerrar una ronda sin capturar notas de cierre.

**Qué hace.** Hace opcionales las notas de cierre sin modificar las
validaciones ni el proceso competitivo de cierre de ronda.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `total_a_pagar` en las 10 inscripciones pendientes de `POLLA
SEPTIEMBRE, 24`, todas por $1,000.00, con total esperado de $10,000.00;
la RPC `obtener_control_cobranza_pendiente_352(uuid)` quedó presente y
con `authenticated_execute=true`, `anon_execute=false` y
`public_execute=false`.

------------------------------------------------------------------------

## Migración 346 --- Sustitución administrativa Best Ball post-emisión

**Objetivo.** Permitir sustituir de forma controlada a un integrante
Best Ball después del Freeze y antes de iniciar la ronda, incluso cuando
las tarjetas ya fueron emitidas.

**Qué hace.** Realiza la sustitución de forma atómica y auditada,
conserva el equipo y las tarjetas existentes, crea la nueva inscripción
y los snapshots individuales necesarios del sustituto y, cuando
corresponde, revisa las tarjetas Best Ball mediante el mecanismo de la
Migración 329. No utiliza HCP TEAM ni modifica o revalida las salidas.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `total_a_pagar` en las 10 inscripciones pendientes de `POLLA
SEPTIEMBRE, 24`, todas por $1,000.00, con total esperado de $10,000.00;
la RPC `obtener_control_cobranza_pendiente_352(uuid)` quedó presente y
con `authenticated_execute=true`, `anon_execute=false` y
`public_execute=false`.

------------------------------------------------------------------------

## Migración 347 --- Endurecimiento de permisos de sustitución Best Ball

**Objetivo.** Cerrar el acceso anónimo a la sustitución administrativa
Best Ball incorporada en la Migración 346.

**Qué hace.** Retira `EXECUTE` a `anon` sobre la RPC de sustitución Best
Ball y conserva el acceso para usuarios autenticados y `service_role`.
No modifica la lógica de sustitución, datos, snapshots, tarjetas,
salidas ni motores deportivos.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `total_a_pagar` en las 10 inscripciones pendientes de `POLLA
SEPTIEMBRE, 24`, todas por $1,000.00, con total esperado de $10,000.00;
la RPC `obtener_control_cobranza_pendiente_352(uuid)` quedó presente y
con `authenticated_execute=true`, `anon_execute=false` y
`public_execute=false`.

------------------------------------------------------------------------

## Migración 348 --- Porcentaje de hándicap configurable a nivel torneo

**Objetivo.** Recuperar la configuración del porcentaje de hándicap a
nivel torneo sin perder los defaults definidos por modalidad ni los
overrides específicos de cada ronda.

**Qué hace.** Agrega al torneo un Handicap Allowance opcional y
establece la jerarquía efectiva
`override de ronda → porcentaje del torneo → default de la modalidad`.
Actualiza la vista y las funciones de configuración/congelamiento que
resolvían directamente el porcentaje efectivo. Los torneos existentes
conservan su comportamiento mientras el nuevo valor permanezca vacío; no
modifica automáticamente datos de torneos existentes.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `total_a_pagar` en las 10 inscripciones pendientes de `POLLA
SEPTIEMBRE, 24`, todas por $1,000.00, con total esperado de $10,000.00;
la RPC `obtener_control_cobranza_pendiente_352(uuid)` quedó presente y
con `authenticated_execute=true`, `anon_execute=false` y
`public_execute=false`.

------------------------------------------------------------------------

## Migración 349 --- HCP competitivo específico del jugador por torneo

**Objetivo.** Permitir que el organizador establezca, antes del Freeze,
un HCP competitivo aplicable únicamente al torneo, sin modificar el HCP
general del perfil del jugador.

**Qué hace.** Guarda el ajuste en la inscripción con motivo,
administrador y fecha, mantiene auditoría histórica y utiliza el HCP del
torneo para elegibilidad de categoría y para el snapshot de Handicap
Index del Freeze. La categoría actual sólo puede conservarse si continúa
siendo elegible con el HCP ajustado; si deja de serlo, la operación
exige una categoría elegible y, al cambiarla, sincroniza la marca de
salida estándar activa del campo. No permite ajustes después del Freeze
y no modifica el perfil del jugador ni los motores de resultados.

## **Estado al documentar:** ejecutada manualmente y verificada en PROD.

## Migración 350 --- Previsualización de categorías para HCP propuesto

**Objetivo.** Permitir que el organizador conozca, antes de persistir un
ajuste de HCP torneo, qué categorías son elegibles para el nuevo HCP y
qué marca de salida estándar activa correspondería a cada una.

**Qué hace.** Centraliza la regla existente de elegibilidad de categoría
en un helper parametrizado por HCP y agrega una RPC de previsualización
sin persistencia. La RPC recibe la inscripción y el HCP propuesto,
conserva las reglas vigentes de categoría natural o superior, género y
edad, informa si la categoría actual continúa siendo elegible y devuelve
las categorías válidas junto con la marca estándar activa del campo. No
modifica la inscripción, el perfil, la categoría ni la marca; el ajuste
definitivo continúa realizándose de forma atómica mediante la RPC de la
Migración 349.

**Estado al documentar:** ejecutada manualmente y verificada en PROD; se
detectó permiso EXECUTE heredado para `anon`, corregido por la Migración
351.

------------------------------------------------------------------------

## Migración 351 --- Cierre de permiso anon en previsualización HCP

**Objetivo.** Cerrar el permiso formal `EXECUTE` del rol `anon` sobre
`previsualizar_categorias_hcp_torneo_350(uuid,numeric)`, detectado
durante la verificación de PROD posterior a la Migración 350.

**Qué hace.** Revoca `EXECUTE` de `PUBLIC` y `anon` y conserva
explícitamente `EXECUTE` para `authenticated`. No modifica datos, lógica
de HCP, categorías, marcas de salida ni las funciones implementadas por
las Migraciones 349 y 350.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `authenticated_execute=true`, `anon_execute=false`,
`public_execute=false`; las RPC 349 y 350 permanecieron operativas y no
quedaron overrides incompletos.

------------------------------------------------------------------------

## Migración 352 --- Total a pagar por inscripción y control de cobranza

**Objetivo.** Separar formalmente la obligación económica de una
inscripción del dinero efectivamente recibido y habilitar una fuente
única para el control de cobranza de jugadores pendientes de pago, sin
introducir todavía pagos parciales ni una cuenta corriente completa.

**Qué hace.** Agrega `total_a_pagar` a `tournament_registrations` como
importe congelado de la inscripción y conserva `monto_pagado`
exclusivamente como el importe efectivamente recibido. Para las nuevas
inscripciones individuales con pago el día del evento,
`inscribir_pago_dia_evento_339` congela la tarifa aplicable al momento
de inscribirse: Early Bird cuando esté configurado y vigente; en otro
caso, la tarifa individual. `registrar_pago_inscripcion_339` mantiene el
flujo de pago único y, cuando existe `total_a_pagar`, exige que el pago
liquide exactamente ese total; las inscripciones históricas sin total
conservan el comportamiento legacy.

La migración incorpora además
`obtener_control_cobranza_pendiente_352(uuid)`, RPC read-only autorizada
para Superadmin, organizador del torneo y administrador del club.
Devuelve encabezado del torneo, campo, moneda, tarifas de referencia,
cantidad de pendientes, total esperado, medios de pago y jugadores
pendientes ordenables alfabéticamente, como fuente común para pantalla
online, reporte formal y exportación a hoja de cálculo.

Como backfill operativo controlado, la migración localiza por nombre
`POLLA SEPTIEMBRE, 24`, exige que exista exactamente una vez y valida
antes de actualizar que su tarifa individual sea \$1,000.00, sin tarifa
de equipo ni Early Bird. Sólo entonces asigna `total_a_pagar = 1000.00`
a sus inscripciones activas con `estado_pago='PENDIENTE'` que aún no
tengan total. Si la configuración económica no coincide, la transacción
falla y hace rollback.

**Alcance deliberado.** Esta fase admite un solo pago liquidatorio. No
crea movimientos, cargos, abonos, pagos parciales ni cálculo de saldo.
Esa evolución se diseñará posteriormente como cuenta corriente sin
cambiar el significado establecido aquí para `total_a_pagar` y
`monto_pagado`.

**Estado al documentar:** ejecutada manualmente y verificada en PROD. Se
confirmó `total_a_pagar` en las 10 inscripciones pendientes de `POLLA
SEPTIEMBRE, 24`, todas por $1,000.00, con total esperado de $10,000.00;
la RPC `obtener_control_cobranza_pendiente_352(uuid)` quedó presente y
con `authenticated_execute=true`, `anon_execute=false` y
`public_execute=false`.

------------------------------------------------------------------------

## Migración 353 --- Corrección del generador de folio de inscripción

**Objetivo.** Evitar errores de llave duplicada al crear una inscripción
cuando existen huecos históricos en la numeración de folios de un torneo.

**Diagnóstico que la origina.** Al intentar inscribir a Manuel Romo Garay
en `POLLA SEPTIEMBRE, 24`, PostgreSQL rechazó la operación por la
restricción `tournament_registrations_folio_unico`. El torneo tenía 10
inscripciones pero sus folios llegaban hasta `INS-0011`, porque faltaba
`INS-0004`. La función `generar_folio_inscripcion()` calculaba el siguiente
folio mediante `count(*) + 1`; por ello obtuvo 11 e intentó generar de
nuevo `INS-0011`.

**Qué hace.** Reemplaza únicamente `generar_folio_inscripcion()` para
conservar el bloqueo `FOR UPDATE` sobre el torneo y calcular el siguiente
folio como el máximo componente numérico de los folios válidos
`INS-NNNN` existentes para ese torneo, más uno. De esta manera no reutiliza
huecos históricos y, para el estado diagnosticado de `POLLA SEPTIEMBRE,
24`, el siguiente folio corresponde a `INS-0012`.

**Alcance.** No modifica folios existentes, no inserta la inscripción de
Manuel manualmente, no cambia reglas de inscripción, pagos, categorías,
HCP ni motores deportivos. La restricción UNIQUE
`(tournament_id, folio)` permanece como protección final. La generación
continúa serializada por torneo para evitar colisiones entre inscripciones
concurrentes.

**Estado al documentar:** preparada para ejecución manual; pendiente de
verificación en PROD.

