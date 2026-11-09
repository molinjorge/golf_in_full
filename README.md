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
  -----------------------------------------------------------------------

## MIGRACIÓN 388 --- PREPARADA --- HCP INMUTABLE EN RESULTADOS PUBLICADOS DESDE POLLA SEPTIEMBRE, 24

**Estado:** PREPARADA --- pendiente de ejecución manual y verificación
en PROD.

**Objetivo:** hacer que el HCP utilizado realmente en una ronda
individual forme parte del resultado oficial congelado y publicado, para
que la APP de jugadores pueda mostrar resultados Gross/Neto junto con el
HCP histórico correcto sin consultar el HCP actual del catálogo.

**Alcance acordado:** la única publicación ya existente que se corrige
es `POLLA SEPTIEMBRE, 24`, torneo
`0d9ea628-10a1-4214-a078-e73bb5f59313`, Ronda 1
`42a4aa4d-75d8-4d35-8301-cb20091afaaa`. No se corrigen torneos
anteriores. A partir de esta migración, todos los nuevos cierres
competitivos individuales materializan automáticamente el HCP congelado.

**Diagnóstico confirmado en PROD:**
`cerrar_categoria_competitiva_ronda(...)` congela `leaderboardCategory`
dentro de `closure_snapshot`; `publicar_resultados_categoria_ronda(...)`
copia exactamente ese cierre dentro de `publication_snapshot` sin
recalcular; y `obtener_resultados_publicados_categoria_ronda(...)`
devuelve posteriormente ese snapshot publicado. Los jugadores publicados
contienen actualmente identidad, estado competitivo y métricas
Gross/Neto, pero no `playingHandicap` ni `courseHandicap`.

**Caso de control:** en `POLLA SEPTIEMBRE, 24` existen 48 participantes
en la publicación oficial y los 48 tienen correspondencia exacta por
ronda + jugador con `tournament_round_handicap_snapshots`; no existen
faltantes. El HCP competitivo que debe mostrarse en la APP es
`playing_handicap`; `course_handicap` se conserva adicionalmente como
evidencia histórica.

**Qué crea:** `_materializar_hcp_leaderboard_388(uuid,jsonb)`, helper
interno que toma un `leaderboardCategory` individual y agrega a cada
elemento de `players[]` los campos `playingHandicap` y `courseHandicap`
obtenidos exclusivamente de `tournament_round_handicap_snapshots`. Si
algún participante con `playerId` no tiene correspondencia congelada en
la ronda, la operación falla en lugar de fabricar o consultar un HCP
actual.

**Persistencia futura:** crea el trigger
`trg_materializar_hcp_cierre_388` sobre
`tournament_round_category_competitive_closures`. Antes de insertar un
cierre cuya `participationType` sea `individual`, el trigger enriquece
el `leaderboardCategory` del `closure_snapshot`. La publicación
posterior continúa copiando exactamente el cierre formal, por lo que el
HCP queda integrado al resultado inmutable sin cambiar el contrato de
publicación ni agregar una segunda fuente de datos a la APP.

**Corrección única de POLLA SEPTIEMBRE, 24:** dentro de la misma
transacción, la migración enriquece el `closure_snapshot` ya existente
de la Ronda 1 y sustituye exclusivamente el `closureSnapshot` contenido
en su publicación oficial por esa misma versión enriquecida. Exige
encontrar el cierre individual y exactamente una publicación
`PUBLISHED`; cualquier inconsistencia provoca rollback.

**Qué no modifica:** no recalcula Gross, Neto, posiciones, desempates,
estados competitivos ni outcomes; no cambia HCP del catálogo,
inscripciones ni snapshots congelados; no toca torneos anteriores a
`POLLA SEPTIEMBRE, 24`; no hace backfill general; no modifica resultados
TEAM; no cambia Stroke Play, Stableford, A-Go-Go o Best Ball; no
modifica Freeze, salidas, tarjetas, captura, conciliación ni cierre de
ronda.

**Regla para la APP de jugadores:** el HCP mostrado en resultados
publicados debe provenir de
`results.leaderboardCategory.players[].playingHandicap` entregado por
`obtener_resultados_publicados_categoria_ronda(...)`. La APP no debe
consultar `players`, inscripciones ni ningún HCP vigente para
reconstruir resultados históricos. `courseHandicap` queda disponible en
el snapshot como respaldo, aunque la columna visible HCP utilice
`playingHandicap`.

**Atomicidad:** helper, trigger y corrección de `POLLA SEPTIEMBRE, 24`
se aplican en una sola transacción. Si falta un snapshot HCP, el
cierre/publicación objetivo no es único o falla cualquier validación,
toda la migración hace rollback.

**Verificación prevista:** confirmar existencia del helper y trigger;
comprobar en `POLLA SEPTIEMBRE, 24` 48 publicados / 48 con
`playingHandicap` / 48 con `courseHandicap` / 0 faltantes; comprobar 0
diferencias contra `tournament_round_handicap_snapshots`; y verificar
que Gross/Neto permanecen sin cambio.

## MIGRACIÓN 389 --- PREPARADA --- CIERRE FORMAL DE CAPTURA POR RONDA

**Estado:** PREPARADA --- pendiente de ejecución manual y verificación en PROD.

**Objetivo:** separar explícitamente el fin de la captura del cierre competitivo. La ronda permanece con captura abierta mientras existan correcciones operativas; cuando todas las unidades están resueltas, un administrador autorizado puede ejecutar un cierre formal y auditable de captura.

**Qué hace:** crea `tournament_round_capture_events` como historial append-only `CLOSED/REOPENED`; agrega `obtener_estado_cierre_captura_ronda_389(...)` con resumen de tarjetas físicas capturadas, conciliaciones completadas, `NOT_REQUIRED`, outcomes `DNS/WD/DNF/DQ/NO_CARD`, unidades resueltas y pendientes; agrega RPC para cerrar y reabrir captura; y agrega un gate de base de datos que impide nuevos cierres competitivos de categoría mientras la captura de la ronda siga abierta.

**Reglas:** pagos pendientes no intervienen en el cierre deportivo; cerrar captura no cierra categorías ni ronda automáticamente; la reapertura exige motivo y queda bloqueada si ya existe una categoría cerrada formalmente. `POLLA SEPTIEMBRE, 24` conserva intactos sus cierres históricos y no recibe un cierre de captura retroactivo fabricado.

**Frontend/Asistente pendiente:** la siguiente fase debe consumir este contrato para mostrar permanentemente el bloque `ESTADO DE CAPTURA DE LA RONDA`, el botón visible `CERRAR CAPTURA`, bloquear edición después del cierre, habilitar `CERRAR CATEGORÍA` sólo después del cierre de captura y reflejar la misma secuencia en el Asistente Operativo.

## MIGRACIÓN 390 --- PREPARADA --- BLINDAJE DE BASE DE DATOS DESPUÉS DEL CIERRE DE CAPTURA

**Estado:** PREPARADA --- pendiente de ejecución manual y verificación en PROD.

**Objetivo:** convertir `CAPTURA CERRADA` en una frontera real de base de datos y no sólo de interfaz, impidiendo que jugadores, marcadores, administradores, enlaces directos o solicitudes ya abiertas modifiquen captura después del cierre formal.

**Qué hace:** agrega un guard transaccional sobre las tablas mutables de sesión de captura, scores digitales individual/A-Go-Go/Best Ball, recepción y scores físicos individual/Best Ball, conciliación, resoluciones de conciliación y outcomes. El guard serializa cada mutación contra el mismo registro de ronda que bloquea `cerrar_captura_ronda_389`, evitando carreras entre una acción en vuelo y el cierre. Si la última acción formal 389 es `CLOSED`, PostgreSQL rechaza la mutación con mensaje `CAPTURA CERRADA`.

**Consulta para jugador/marcador:** agrega `obtener_cierre_captura_score_card_390(uuid)`, que reutiliza `puede_ver_score_card_captura(...)` y entrega únicamente `captureClosed`, estado, ronda y fecha de cierre para que `/score/card` pueda mostrar modo lectura a participantes autorizados sin abrir la consulta administrativa de la Migración 389.

**Compatibilidad:** una ronda sin evento 389 se considera `OPEN`; por ello los torneos históricos, incluido `POLLA SEPTIEMBRE, 24`, no se reinterpretan ni reciben eventos artificiales. La reapertura formal 389 vuelve a permitir mutaciones siempre que sus propias reglas la autoricen.

**Qué no modifica:** pagos, premios, control de acceso, emisión de tarjetas, sustituciones, cierre de categoría, desempates, publicación, cierre de ronda, resultados históricos ni snapshots.

## Migración 391 — Blindaje de reapertura de captura con ronda cerrada

**Objetivo:** establecer explícitamente que el cierre competitivo de una ronda es un punto de no retorno para la captura.

**Qué hace:** actualiza `public.reabrir_captura_ronda_389` para rechazar la reapertura cuando exista un cierre competitivo `FINAL` en `tournament_round_competitive_closures`. Conserva además la protección existente que impide reabrir cuando ya existe al menos una categoría cerrada formalmente. No modifica resultados, pagos, desempates, publicaciones ni cierres existentes.


## Migración 392 — Estado competitivo de categoría respeta cierre de captura

**Estado:** EJECUTADA Y VERIFICADA ESTRUCTURALMENTE EN PROD.

**Objetivo:** impedir que una categoría se presente como `READY_TO_CLOSE` mientras la captura formal de la ronda continúe abierta.

**Qué hace:** extiende `obtener_estado_competitivo_categorias_ronda(...)` con `captureClosed`, `captureStatus`, `blockingReason` y `statusBeforeCaptureGate`. `CAPTURE_OPEN` tiene prioridad como bloqueo de cierre de categoría, sin alterar resultados ni el motor de desempates. Los desempates `RESOLVED_AUTOMATIC` continúan siendo silenciosos.

**Frontend:** UI-392A consume esos campos sin una segunda consulta a 389; `CERRAR CATEGORÍA` permanece visible pero deshabilitado con el mensaje `Primero debes cerrar la captura de la ronda.` mientras captura esté abierta.

## Migración 393 — Workflow formal de cierre de captura

**Estado:** EJECUTADA Y VERIFICADA ESTRUCTURALMENTE EN PROD.

**Objetivo:** incorporar `CIERRE DE CAPTURA` como fase formal del workflow materializado que alimenta al Asistente Operativo, manteniendo la posibilidad de consultar resultados provisionales mientras la captura siga abierta.

**Qué hace:** agrega/materializa el nodo de ronda `ROUND_CAPTURE_CLOSE` entre conciliación y cierre de categorías. El nodo queda `COMPLETE` cuando el último evento formal de captura es `CLOSED`, `AVAILABLE` cuando conciliación ya está completa y corresponde cerrar captura, y `BLOCKED` mientras la conciliación no esté completa. `ROUND_RESULTS` permanece independiente del cierre de captura para permitir visualización provisional. `ROUND_CATEGORY_CLOSURE` exige simultáneamente resultados completos y `ROUND_CAPTURE_CLOSE=COMPLETE`; si captura sigue abierta queda bloqueado explícitamente por `ROUND_CAPTURE_CLOSE`.

**Qué no modifica:** motores deportivos, Gross/Neto, desempates, pagos, publicaciones, cierres ya registrados, captura física, conciliación ni la RPC 389 de cierre/reapertura. Tampoco convierte resultados provisionales en dependientes del cierre formal de captura.

**Frontend/Asistente pendiente:** después de verificar 393, adaptar la presentación del Asistente para nombrar `ROUND_CAPTURE_CLOSE` como `Cierre de captura`, ofrecer la acción correspondiente cuando esté disponible y mantener pagos pendientes únicamente como warning no bloqueante.


## Migración 394 — Plantilla maestra de workflow y preferencias funcionales del torneo

**Estado:** EJECUTADA Y VERIFICADA EN PROD.

**Objetivo:** crear la capa declarativa maestra del ciclo operativo de TEE CENTRAL y registrar en Información general del torneo las decisiones `usar_tarjeta_digital` y `usar_estaciones_digitales_premios`, sin sustituir todavía el workflow materializado vigente ni alterar ninguna regla deportiva.

**Qué hace:** agrega a `tournaments` los dos indicadores funcionales; crea `workflow_master_templates` y `workflow_master_nodes`; registra la plantilla `TEE_CENTRAL_STANDARD` versión 1 con los 25 nodos aprobados; agrega `workflow_template_version` al torneo para fijar la versión aplicable; y publica `obtener_plantilla_workflow_394(uuid)` como consulta descriptiva de la plantilla correspondiente al torneo. La plantilla almacena orden, ámbito, textos, navegación, aplicabilidad y claves de evidencia, pero no SQL ejecutable ni reglas de autorización.

**Tarjeta digital:** `usar_tarjeta_digital=true` hace aplicables las fases descriptivas de captura digital/conciliación. No existe un cierre digital separado: `ROUND_CAPTURE_CLOSE` continúa siendo el único cierre formal de captura de scores y se sustenta en `tournament_round_capture_events`.

**Premios especiales:** `usar_estaciones_digitales_premios` sólo declara si se utilizarán estaciones digitales. No crea nodos deportivos, bloqueos ni requisitos de cierre/publicación. Los premios capturados podrán incorporarse a resultados por el módulo existente. El control de acceso no recibe un campo nuevo: se conserva `usar_control_acceso_qr`.

**Compatibilidad y seguridad:** no modifica `reconciliar_workflow_torneo_332`, `_adaptar_asistente_workflow_338`, las reconstrucciones 332–393, motores Stroke Play/Stableford/A-Go-Go/Best Ball, HCP, desempates, Freeze, inscripciones, salidas, tarjetas, captura, conciliación, resultados, cierres, publicaciones, pagos, acceso ni premios. `tournament_workflow_nodes` sigue siendo el estado materializado vigente. La 394 es fundacional y no cambia el comportamiento operativo del Asistente hasta una integración posterior expresamente aprobada.

**Estados terminales:** la plantilla registra como regla arquitectónica que FINALIZADO, CANCELADO y VENCIDO son no operativos para el Asistente; `VENCIDO` se determinará reutilizando `torneo_esta_vencido_295`, sin modificar el enum `estatus_torneo`. Esta migración no cambia el comportamiento actual del Asistente.

**Verificación prevista:** comprobar columnas nuevas y defaults; existencia/ACL/RLS de las tablas maestras; exactamente una plantilla activa versión 1; exactamente 25 nodos activos y secuencias únicas; ausencia de nodo de estaciones de premios; presencia de `START_TOURNAMENT` y `ROUND_CAPTURE_CLOSE`; y confirmar que las funciones operativas existentes conservan su definición.


## Migración 395 — Evaluador descriptivo del workflow maestro

**Estado:** EJECUTADA Y VERIFICADA EN PROD.

**Objetivo:** evaluar la plantilla maestra 394 contra evidencia operativa real para producir un estado descriptivo del ciclo y una propuesta de `nextAction`, sin sustituir todavía al Asistente vigente y sin participar en ninguna autorización o bloqueo.

**Qué hace:** agrega `obtener_workflow_evaluado_395(uuid)`, una RPC `STABLE` y de sólo lectura. Lee la plantilla versionada, las preferencias del torneo y evidencia existente de configuración, inscripciones, Freeze, HCP de equipos, grupos, salidas, emisión de tarjetas, inicio de ronda, captura física, conciliación, cierre único de captura, resultados, desempates excepcionales, cierres de categoría, publicación, cierre de ronda, corte y finalización. Expande los nodos de ronda para cada ronda activa y devuelve `COMPLETE`, `PENDING`, `NOT_APPLICABLE` o `INFORMATIONAL`.

**Asistente:** calcula descriptivamente el primer nodo accionable, aplicable y no completo como `nextAction`. Ese dato es únicamente una guía. La aplicación continúa siendo la única autoridad para decidir si una operación puede ejecutarse. La 395 no conecta todavía `_adaptar_asistente_workflow_338` con este evaluador.

**Captura digital:** `ROUND_DIGITAL_SCORING` permanece informativo. No tiene cierre independiente. `ROUND_CAPTURE_CLOSE`, sustentado por el cierre 389, sigue siendo el único cierre formal de la captura de scores física y digital.

**Premios:** `usar_estaciones_digitales_premios` se devuelve sólo como preferencia. No existe nodo de premios, no se evalúa como requisito y no puede impedir resultados, publicación, cierre de categoría, cierre de ronda ni finalización.

**Estados terminales:** FINALIZADO, CANCELADO y VENCIDO producen `assistantOperational=false` y `nextAction=null`; VENCIDO reutiliza `torneo_esta_vencido_295`.

**Qué no modifica:** `tournament_workflow_nodes`, reconstrucciones 332–393, Asistente 338, motores deportivos, reglas de HCP, desempates, inscripciones, Freeze, salidas, emisión, captura, conciliación, resultados, cierres, publicación, pagos, acceso o premios. No contiene `INSERT`, `UPDATE` ni `DELETE` operativos.


### Verificación posterior a la ejecución de la Migración 395

Se confirmó directamente en PROD la existencia de `public.obtener_workflow_evaluado_395(uuid)`. La función conserva `SECURITY INVOKER`, tiene `EXECUTE` para `authenticated` y `service_role`, no para `anon`, y referencia la plantilla maestra `workflow_master_nodes` sin depender de `tournament_workflow_nodes`. La plantilla `TEE_CENTRAL_STANDARD` versión 1 conserva sus 25 nodos.

La prueba desde el canal administrativo de diagnóstico devolvió `No autenticado` al no existir `auth.uid()` en ese contexto; este resultado es consistente con el contrato de seguridad de la RPC y no constituye un fallo funcional. La prueba del payload con identidad autenticada queda para la integración controlada del frontend/Asistente.


## MIGRACIÓN 396 — PREPARADA — ADAPTADOR DEL ASISTENTE A LA PLANTILLA MAESTRA

**Estado:** PREPARADA — pendiente de ejecución manual y verificación en PROD.

**Objetivo:** crear un contrato de Asistente Operativo que consuma exclusivamente el evaluador descriptivo 395 para seleccionar el siguiente paso, manteniendo a la aplicación como única autoridad sobre bloqueos, autorizaciones y operaciones deportivas.

**Qué crea:** `obtener_asistente_operativo_torneo_396(uuid)`. La RPC valida autenticación y permisos, consulta `obtener_workflow_evaluado_395(uuid)`, expone `nextAction`, nodos de torneo, rondas, preferencias y mensajes terminales, y conserva el warning administrativo no bloqueante de pagos pendientes.

**Qué no hace:** no sustituye todavía `obtener_asistente_operativo_torneo(uuid)`; no modifica `_adaptar_asistente_workflow_338`, 340, 341 ni los reconstructores 332–393; no escribe `tournament_workflow_nodes`; no ejecuta acciones; no cambia motores, reglas, procesos, autorizaciones, guards, bloqueos, Freeze, inscripciones, salidas, tarjetas, captura, conciliación, resultados, desempates, cierres, publicación, pagos ni finalización.

**Estrategia de despliegue:** esta fase instala la nueva RPC en paralelo. Primero se verifica su payload autenticado en la aplicación. Sólo después se cambiará el frontend del Asistente para consumirla. De esta forma existe rollback funcional inmediato: el contrato público actual permanece intacto durante la prueba.

**Regla de autoridad:** `authority=APPLICATION`, `assistantRole=GUIDE_ONLY`, `writesOperationalState=false`.


## MIGRACIÓN 397 — EVALUADOR NO ANTICIPA RESULTADOS SIN SNAPSHOT

**Objetivo:** corregir exclusivamente la capa descriptiva del evaluador 395 para que el Asistente pueda consultar torneos que todavía están en configuración y cuya ronda aún no tiene snapshot congelado de scoring.

**Qué hace:** antes de consultar evidencia competitiva de resultados, desempates, cierre de categorías y publicación, `obtener_workflow_evaluado_395(uuid)` comprueba si existe un `tournament_round_condition_snapshots` con `scoring_engine`. Si todavía no existe, esas evidencias futuras se consideran aún no disponibles y sus pasos permanecen descriptivamente pendientes. No se crea ni congela ningún snapshot.

**Qué no hace:** no modifica motores deportivos, reglas, procesos, autorizaciones, guards, bloqueos, Freeze, snapshots, inscripciones, salidas, tarjetas, captura, conciliación, desempates, resultados, cierres, publicación, pagos ni finalización. No escribe `tournament_workflow_nodes`.

**Causa corregida:** PRUEBA AUTOSERVICIO #3 devolvía HTTP 500 al consultar la RPC 396 porque el evaluador 395 pedía anticipadamente evidencia competitiva y una función deportiva respondía `La ronda no tiene snapshot congelado de scoring.` El torneo se encontraba correctamente en una fase anterior.


## MIGRACIÓN 398 — ASISTENTE 396 SIN CADENA LEGACY

**Objetivo:** eliminar de la nueva capa de guía la dependencia indirecta del Asistente anterior.

**Qué hace:** `obtener_asistente_operativo_torneo_396(uuid)` deja de llamar `_adaptar_asistente_pagos_pendientes_340`, porque esa función invoca `_adaptar_asistente_workflow_338` y éste ejecuta la reconciliación legacy. El warning `PENDING_PAYMENTS` se conserva mediante una consulta directa de solo lectura a las inscripciones activas con `estado_pago='PENDIENTE'`.

**Qué no hace:** no modifica motores, reglas deportivas, procesos, autorizaciones, bloqueos, snapshots, Freeze, salidas, tarjetas, captura, conciliación, resultados, cierres, publicación, pagos ni finalización. No modifica el significado ni el carácter no bloqueante del warning de pagos.


## MIGRACIÓN 399 — CORRECCIÓN DE EVIDENCIA DE CIERRE DE RONDA

**Objetivo:** corregir una referencia de columna exclusivamente descriptiva en el evaluador 395.

**Qué hace:** en la evidencia `ROUND_CLOSED`, sustituye la referencia inexistente `tournament_round_competitive_closures.status` por la columna real `competitive_status`. Conserva íntegramente la protección 397 para rondas sin snapshot.

**Qué no hace:** no modifica ningún cierre, estado deportivo, motor, regla, autorización, bloqueo ni dato operativo. Únicamente corrige cómo el Asistente lee evidencia ya existente.


## MIGRACIÓN 400 — CORRECCIÓN DE EVIDENCIA DE CORTES EN EL EVALUADOR

**Objetivo:** corregir de una vez las referencias del evaluador descriptivo 395 al esquema real del módulo de cortes.

**Qué hace:** elimina la referencia inexistente `tournament_cut_rules.tournament_id`; determina la aplicabilidad del corte mediante `despues_de_ronda_id`; y cuenta las decisiones desde `tournament_cut_player_statuses`, usando sus columnas reales `tournament_id`, `cut_after_round_id`, `tournament_registration_id` y `cut_status`.

**Qué no hace:** no modifica reglas de corte, resultados, motores deportivos, autorizaciones, bloqueos ni datos operativos. Sólo corrige la lectura descriptiva utilizada por el Asistente.


## MIGRACIÓN 401 — ORDEN CORRECTO DE `nextAction` EN EL WORKFLOW MAESTRO

**Objetivo:** hacer que el Asistente seleccione “Qué sigue” después de evaluar toda la evidencia, evitando que un nodo de torneo posterior —especialmente `TOURNAMENT_FINALIZATION`— se adelante a los pasos pendientes de una ronda.

**Qué hace:** conserva intacta la evaluación de evidencia y cambia únicamente la selección descriptiva de `nextAction`. Respeta los pasos iniciales del torneo (10–70), la preparación de la ronda, `START_TOURNAMENT` una sola vez en la secuencia 130, la operación/cierre de la ronda desde 140, el orden de rondas y finalmente `TOURNAMENT_FINALIZATION` 900.

**Qué no hace:** no modifica motores deportivos, reglas, autorizaciones, bloqueos, estados operativos, datos de torneo ni la plantilla maestra. El Asistente continúa siendo exclusivamente una guía.

## MIGRACIÓN 402 — GUARDADO ATÓMICO DE CUPOS Y CATEGORÍAS

**Objetivo:** impedir que un torneo quede con una configuración parcial o descuadrada entre el cupo total y los cupos de sus categorías.

**Qué hace:** crea `guardar_configuracion_cupos_categorias_402(uuid,jsonb,integer)`, una operación transaccional que recibe la configuración completa, exige al menos una categoría, cupos enteros mayores a cero y que la suma de cupos sea exactamente igual al cupo total del torneo. Permite cambiar en la misma operación el cupo general y su distribución, conserva los IDs de categorías existentes al actualizar y revierte toda la llamada ante cualquier error.

**Qué conserva:** no modifica los guards existentes de congelamiento, cancelación o vencimiento; tampoco cambia motores deportivos, reglas de inscripción, elegibilidad, resultados, autorizaciones ni bloqueos. Los guards actuales continúan siendo la autoridad para decidir cuándo la configuración puede editarse.

**Integración pendiente de frontend:** sustituir los guardados directos `DELETE/INSERT/UPDATE` de `tournament_categories` por esta RPC y enviar conjuntamente el cupo total cuando éste cambie.



## MIGRACIÓN 403 — BLINDAJE DEL CUPO TOTAL CONTRA DESCUADRE DE CATEGORÍAS

**Objetivo:** cerrar el camino alterno que permitía modificar directamente `tournaments.cupo_maximo` y dejarlo distinto de la suma de los cupos de categorías.

**Qué hace:** agrega un trigger `BEFORE UPDATE OF cupo_maximo` sobre `tournaments`. Si el torneo ya tiene categorías, rechaza un cambio aislado cuyo nuevo cupo total no coincida con la suma vigente de `tournament_categories.cupo_maximo`, o si existen categorías con cupo nulo/no positivo. Los cambios conjuntos de cupo total y distribución siguen realizándose mediante `guardar_configuracion_cupos_categorias_402`, en una sola transacción.

**Compatibilidad:** no corrige automáticamente inconsistencias preexistentes y no modifica motores deportivos, congelamiento, inscripción, resultados ni reglas competitivas. Conserva todos los guards existentes.

## MIGRACIÓN 404 — CUPOS DE CATEGORÍAS MENORES O IGUALES AL CUPO TOTAL

**Objetivo:** permitir que el cupo total del torneo sea mayor que la suma de los cupos distribuidos entre categorías, manteniendo como única condición inválida que las categorías comprometan más lugares que el cupo total.

**Qué hace:** ajusta las validaciones creadas por 402 y 403 para aplicar `SUM(cupos categorías) <= cupo total`. La RPC 402 continúa siendo atómica, mantiene cupos individuales enteros y mayores a cero y ahora devuelve también `sinAsignar`. El guard 403 permite aumentar el cupo total dejando lugares todavía sin distribuir y bloquea únicamente cuando el nuevo total queda por debajo de la suma ya asignada.

**Orden transaccional:** la RPC 402 actualiza la distribución de categorías antes de modificar el cupo total para que el guard 403 pueda validar correctamente reducciones conjuntas dentro de la misma transacción.

**Qué no cambia:** Freeze, cancelación, vencimiento, autorizaciones, inscripción, motores deportivos, hándicap, desempates, resultados y cierres competitivos permanecen intactos.

## MIGRACIÓN 405 — DATOS GENERALES COMO EVIDENCIA DEL PRIMER PASO DEL WORKFLOW

**Objetivo:** hacer que `CONFIGURATION / Configurar datos generales` se considere completo exclusivamente cuando los campos obligatorios de Datos generales tengan valores válidos guardados, sin depender de categorías, franjas de HCP, desempates ni estructura de rondas.

**Qué hace:** agrega `obtener_estado_datos_generales_torneo_405(uuid)`, función descriptiva que revisa Nombre, Campo de golf, Fecha inicio, Fecha fin, Cupo máximo, Número de rondas, Modalidad, Porcentaje de hándicap y Tarifa individual. La tarifa individual acepta cero para torneos gratuitos. Actualiza únicamente la evidencia usada por `TOURNAMENT_CONFIGURATION_COMPLETE` dentro de `obtener_workflow_evaluado_395`.

**Separación de responsabilidades:** categorías, franjas de hándicap, desempates y estructura de rondas conservan sus propios nodos del workflow. La migración no cambia la autoridad de la aplicación ni ninguna autorización o bloqueo operativo.

**No modifica:** motores deportivos, Freeze, inscripciones, apertura/cierre de inscripciones, reglas competitivas, resultados, desempates, cierres, pagos ni acciones operativas.

## MIGRACIÓN 406 — EVIDENCIA DE CONFIGURACIÓN DE DESEMPATES

**Objetivo:** hacer que `TIEBREAK_CONFIGURATION / Configurar desempates` se considere completo a partir de la configuración activa realmente guardada en `tournament_tiebreak_rules`, en lugar de depender del indicador agregado `tiebreakReady` usado por la lógica de apertura de inscripciones.

**Qué hace:** agrega `obtener_estado_configuracion_desempates_406(uuid)`, función exclusivamente descriptiva que cuenta reglas activas Gross y Neto. Para la configuración global actual, el nodo queda completo cuando existe al menos una regla activa para Gross y al menos una para Neto. Actualiza únicamente la evidencia utilizada por `TIEBREAK_CONFIGURATION_COMPLETE` en `obtener_workflow_evaluado_395`.

**Caso verificado antes de migrar:** PRUEBA AUTOSERVICIO #3 tiene cuatro reglas activas Gross y cuatro Neto, todas con alcance global `todos`, por lo que debe reconocerse como configuración guardada.

**No modifica:** motor de desempates, métodos, secuencias guardadas, resolución automática/manual, autorizaciones, Freeze, inscripciones, resultados, cierres ni ningún bloqueo operativo.

## MIGRACIÓN 407 — CATEGORÍAS COMPLETAS Y REGLA DE CUPOS EN APERTURA

**Objetivo:** impedir que la fase de configuración de categorías se considere completa si alguna categoría carece de clasificación competitiva, y alinear las validaciones de apertura con la regla vigente de cupos.

**Qué hace:** agrega `obtener_estado_categorias_configuradas_407(uuid)`, que considera completa la fase `HANDICAP_RANGES` sólo cuando las franjas HCP son válidas y todas las categorías tienen al menos una clasificación competitiva configurada (`GROSS`, `NET` o `BOTH`). El evaluador 395 utiliza esta evidencia para ese nodo.

**Cupos:** actualiza `validar_configuracion_minima_torneo` y la comparación de `baseConfigurationReady` en `_estado_apertura_inscripciones_379` para aceptar `suma de cupos de categorías <= cupo máximo del torneo`; sólo el excedente es inválido.

**No modifica:** motor de desempates, reglas guardadas, Freeze, autorizaciones, motores deportivos ni acciones operativas. Las clasificaciones se siguen configurando mediante la RPC existente `configurar_clasificacion_categoria_torneo`.

## MIGRACIÓN 408 — MENSAJE DE RONDAS AL ABRIR INSCRIPCIONES

**Objetivo:** orientar al operador cuando intenta abrir inscripciones antes de terminar la configuración de rondas.

**Qué hace:** conserva exactamente el bloqueo existente de `abrir_inscripciones_torneo`, pero reemplaza el mensaje técnico por: “No se pueden abrir las inscripciones todavía. Debes configurar todas las rondas y sus turnos antes de abrir las inscripciones.”

**No modifica:** criterios de apertura, validación de rondas o turnos, autorizaciones, motores deportivos, Freeze, desempates ni ningún proceso operativo.


## MIGRACIÓN 409 — VIGENCIA COMERCIAL NO INTERRUMPE TORNEO EN CURSO

**Objetivo:** impedir que el fin de la vigencia comercial de plataforma interrumpa un torneo que ya fue iniciado formalmente y corregir el corte prematuro del último día causado por evaluar la fecha en UTC.

**Qué hace:** centraliza la regla en `torneo_esta_vencido_295` y `obtener_estado_vigencia_torneo_294`. Ambas usan la fecha local correspondiente a `campos_golf.timezone_id`. Si `tournaments.estatus = 'en_curso'`, la vigencia comercial no marca el torneo como vencido ni lo pone en solo lectura, permitiendo completar captura, conciliación, resultados, desempates, cierres, publicación y finalización mediante las reglas ya existentes. Para torneos que no están en curso, la vigencia comercial conserva su función de habilitar o bloquear escritura según sus fechas.

**Zona horaria:** no se hardcodea México. Se utiliza la zona horaria configurada en el campo del torneo; sólo existe fallback técnico a UTC si faltara ese dato. Al preparar la migración, todos los campos existentes tenían `timezone_id` configurado.

**Caso de validación:** `PRUEBA AUTOSERVICIO #3` permanece `en_curso` y conserva su `valid_through_date = 2026-09-27`. Después de la migración debe dejar de considerarse VENCIDO sin ampliar manualmente su vigencia y debe poder continuar su ciclo deportivo.

**No modifica:** fechas de contratación, estatus del torneo, motores deportivos, reglas competitivas, captura, conciliación, resultados, desempates, cierres, pagos, Asistente Operativo ni los guards consumidores; éstos continúan usando la función central de vigencia.

## MIGRACIÓN 410 — ETIQUETA CERRAR CAPTURA EN ASISTENTE

**Objetivo:** hacer que el Asistente Operativo nombre correctamente la acción del nodo `ROUND_CAPTURE_CLOSE`, evitando presentar como revisión una acción que corresponde ejecutar.

**Qué hace:** actualiza exclusivamente `workflow_master_nodes.action_label` del nodo 180 `ROUND_CAPTURE_CLOSE` de la plantilla activa `TEE_CENTRAL_STANDARD` versión 1, cambiando “Revisar cierre de captura” por “Cerrar captura”. Conserva el título `Cerrar captura` y el destino `captura-fisica`.

**Arquitectura:** la corrección se realiza en la plantilla maestra, que es la fuente de la etiqueta mostrada por el Asistente; no se hardcodea el texto en frontend.

**No modifica:** evaluador 395, RPC 396, navegación, cierre de captura, guards, autorizaciones, motores deportivos, reglas competitivas, resultados ni ningún proceso operativo. El Asistente continúa siendo guía y la aplicación conserva la autoridad para permitir o bloquear la acción.

## MIGRACIÓN 411 — RESULTADOS PARCIALES Y OFICIALES POR CATEGORÍA

**Objetivo:** permitir que cada categoría formalmente cerrada pueda publicar resultados parciales inmediatamente, visibles en la aplicación del jugador, sin esperar al cierre de las demás categorías; posteriormente la publicación oficial sustituye a la parcial.

**Modelo:** `tournament_round_category_publications.publication_status` admite `PARTIAL` y `PUBLISHED`. `PARTIAL` significa resultado parcial visible; `PUBLISHED` conserva el significado histórico de publicación oficial. La restricción única por ronda/categoría se conserva: no se crean dos publicaciones visibles de una misma categoría.

**Publicación parcial:** agrega `publicar_resultados_parciales_categoria_ronda`. Sólo permite publicar una categoría con cierre competitivo formal `FINAL` y congela exactamente el snapshot de ese cierre; no recalcula resultados ni modifica motores deportivos.

**Publicación oficial:** `publicar_resultados_categoria_ronda` conserva su firma y su función como publicación oficial. Si la categoría ya tiene una publicación `PARTIAL`, la promueve sobre la misma fila a `PUBLISHED`, reemplazando para el jugador la condición parcial por oficial sin duplicar resultados. Si ya es oficial, continúa siendo idempotente.

**Aplicación del jugador:** `obtener_resultados_publicados_categoria_ronda` pasa a esquema 2 e informa `publicationType = PARTIAL | OFFICIAL`. Agrega `obtener_categorias_resultados_publicados_ronda_411`, que devuelve todas las categorías de la ronda que ya tengan resultados visibles para construir un selector; el jugador puede consultar cualquier categoría publicada, no sólo aquella en la que participó.

**Ciclo maestro:** las publicaciones `PARTIAL` no satisfacen la publicación formal de la ronda. Las funciones existentes de formalización continúan considerando `publication_status='PUBLISHED'` como publicación oficial, por lo que el nodo `ROUND_RESULTS_PUBLICATION` no se completa únicamente porque todas las categorías tengan parciales.

**Compatibilidad:** las publicaciones históricas `PUBLISHED` permanecen oficiales sin migración de datos. Se conservan las restricciones únicas existentes por ronda/categoría y por cierre formal.

**No modifica:** motores Stroke Play, Stableford, A-Go-Go, Best Ball, cálculo de hándicap, desempates, cierre de captura, cierre competitivo de categoría, cierre competitivo de ronda, guards deportivos ni autorizaciones existentes. La publicación sigue dependiendo del cierre formal de categoría.

## MIGRACIÓN 412 — CIERRE DE RONDA ANTES DE PUBLICACIÓN OFICIAL

**Objetivo:** establecer la secuencia operativa correcta después del cierre de categorías: `Cerrar categorías → publicaciones parciales opcionales → Cerrar ronda → Publicar resultados oficiales`.

**Cierre de ronda:** `_cerrar_ronda_competitiva_pre314` deja de tratar `PUBLICATIONS_PENDING` como bloqueo. Continúa exigiendo cierres formales de categorías y el resto de las condiciones deportivas existentes. No modifica motores ni desempates.

**Publicación oficial:** `publicar_resultados_categoria_ronda` conserva su firma, pero ahora exige que exista un cierre competitivo de ronda `FINAL`. Mientras la ronda permanezca abierta sólo corresponde la publicación parcial creada en 411.

**Guía maestra:** reordena `ROUND_COMPETITIVE_CLOSE` a secuencia 220 y `ROUND_RESULTS_PUBLICATION` a 230. El Asistente continúa siendo exclusivamente guía; no adquiere autoridad operativa.

**Reparación de prueba:** corrige exclusivamente la publicación de categoría A de PRUEBA AUTOSERVICIO #3, creada durante la prueba de 411 antes del cierre de ronda, de `PUBLISHED/OFFICIAL` a `PARTIAL/PARTIAL`, siempre que la ronda continúe sin cierre formal.

**No modifica:** resultados deportivos congelados, cierres de categoría, captura, hándicaps, motores Stroke Play/Stableford/A-Go-Go/Best Ball, desempates, pagos ni autorizaciones administrativas.


## MIGRACIÓN 413 — PUBLICACIÓN OFICIAL DESPUÉS DEL CIERRE DE RONDA

**Objetivo:** corregir la evidencia descriptiva del ciclo para que cerrar competitivamente una ronda no equivalga a considerar sus resultados oficialmente publicados.

**Qué hace:** modifica únicamente `_estado_formalizacion_resultados_ronda_265`. Elimina la regla heredada `grandfatheredByRoundClosure` que, ante una ronda `FINAL`, marcaba todas sus categorías como cerradas y publicadas sin consultar las publicaciones reales. La función continúa evaluando la ronda cerrada mediante los cierres formales de categoría y `tournament_round_category_publications`.

**Publicación oficial:** una categoría cuenta como publicada para `allCategoriesPublished` únicamente cuando existe `publication_status='PUBLISHED'`. Una publicación `PARTIAL` continúa visible como parcial, pero no completa el nodo 230 `ROUND_RESULTS_PUBLICATION`.

**Compatibilidad:** se conserva la clave `grandfatheredByRoundClosure` en el payload normal con valor `false`. El estado `roundClosed` pasa a informar el cierre competitivo real aun cuando la función continúa evaluando publicaciones.

**Efecto en el Asistente:** el evaluador 395 podrá mantener pendiente `ROUND_RESULTS_PUBLICATION` después de cerrar la ronda mientras falten publicaciones oficiales, en vez de saltar directamente a `Finalizar torneo`. El Asistente sigue siendo guía y no adquiere autoridad operativa.

**No modifica:** publicaciones existentes, snapshots deportivos, cierres de categoría o ronda, motores Stroke Play/Stableford/A-Go-Go/Best Ball, hándicap, desempates, captura, pagos, guards ni autorizaciones.

## MIGRACIÓN 414 — FINALIZACIÓN EXIGE PUBLICACIÓN OFICIAL

**Objetivo:** impedir la finalización formal de un torneo mientras exista alguna ronda activa con categorías participantes cuyos resultados todavía no hayan sido publicados oficialmente.

**Qué hace:** modifica únicamente `previsualizar_finalizacion_torneo`. Conserva todos los gates históricos de cierre de rondas, lifecycle y clasificación acumulada Stableford, y agrega un gate de publicaciones oficiales reutilizando `_estado_formalizacion_resultados_ronda_265` para cada ronda activa.

**Regla:** sólo `publication_status='PUBLISHED'` cuenta como publicación oficial. `PARTIAL` no permite finalizar el torneo. Las categorías sin participantes no generan pendientes de publicación.

**Autoridad:** `finalizar_torneo` no se modifica porque ya vuelve a ejecutar `previsualizar_finalizacion_torneo` inmediatamente antes de crear el sello de finalización y cambiar `tournaments.estatus` a `finalizado`. Por tanto, el nuevo gate queda protegido en Supabase y no depende del frontend ni del Asistente.

**Evidencia adicional:** la previsualización incorpora `officialPublications` con conteos por torneo y por ronda para que la interfaz pueda explicar cuántas categorías participantes están publicadas oficialmente y cuántas faltan.

**No modifica:** motores Stroke Play/Stableford/A-Go-Go/Best Ball, resultados deportivos, desempates, hándicap, cierres de captura/categoría/ronda, publicaciones existentes, snapshots, pagos, permisos ni el evaluador/Asistente 395/396.


## MIGRACIÓN 415 — OPERACIÓN DE TARJETA STABLEFORD: HCP, VENTAJAS Y PUNTOS

**Objetivo:** completar la experiencia operativa de Stableford Individual para que tarjeta/captura digital, captura física/comparación y revisión administrativa puedan mostrar el Playing Handicap congelado, las ventajas por hoyo y los puntos Stableford Gross/Neto sin crear un segundo motor de cálculo.

**Qué hace:** agrega `obtener_operacion_stableford_tarjeta_415(score_card_id)`, una RPC de sólo lectura y exclusiva de `scoring_engine='stableford'` + `participation_type='individual'`. La función reutiliza los snapshots congelados de ronda y las funciones oficiales existentes `calcular_golpes_handicap_hoyo` y `calcular_puntos_stableford_estandar`. Devuelve por hoyo PAR, Stroke Index, `handicapStrokes`, evidencia digital y física, y sus puntos Stableford Gross/Neto. También devuelve Playing Handicap, clasificaciones Gross/Neto configuradas y metadatos del snapshot del motor.

**Ventajas:** `handicapStrokes` se deriva exclusivamente del `playing_handicap` congelado de `tournament_round_handicap_snapshots` y del Stroke Index congelado del hoyo. La suma de las ventajas/disventajas distribuidas debe coincidir exactamente con el Playing Handicap. El frontend puede representar cada golpe positivo con un punto verde dentro del recuadro del hoyo; valores mayores a 18 producen múltiples marcas según corresponda.

**Puntos durante la operación:** la RPC 415 calcula puntos sobre la evidencia disponible sin exigir captura física finalizada ni conciliación. Un hoyo `PENDING` conserva puntos `NULL`; `PICKUP` produce 0 puntos; `SCORE` usa la misma tabla matemática del motor oficial. La regla congelada de Hole In One, cuando esté habilitada, se respeta igual que en el resultado oficial.

**Gross/Neto:** la RPC informa las clasificaciones congeladas de la categoría mediante `grossEnabled` y `netEnabled`. Para `TORNEO PRUEBA STABLEFORD OCTUBRE`, categoría ÚNICA, ambas clasificaciones están habilitadas, por lo que la interfaz debe mostrar PUNTOS GROSS y PUNTOS NETO, con subtotales FRONT/OUT, BACK/IN y TOTAL.

**Frontend requerido:** consumir la RPC 415 únicamente cuando `useRoundScoringEngine` resuelva `stableford`. En la tarjeta/captura digital mostrar Playing HCP, ventajas por hoyo y puntos conforme se captura. En `physical-card-capture` agregar las ventajas y filas de puntos Stableford a `RESULTADO DE COMPARACIÓN`. En la revisión administrativa permitir ver los 18 hoyos de cada jugador con PAR, SI, ventajas, score y puntos. No duplicar en React la fórmula Stableford: React sólo presenta y totaliza los puntos por hoyo devueltos por 415.

**Seguridad y aislamiento:** la función reutiliza el guard de lectura vigente de `obtener_detalle_captura_tarjeta_score`, no abre permisos a `anon` y rechaza cualquier tarjeta que no sea Stableford Individual. No reemplaza ni modifica la RPC genérica de captura ni la RPC de resultado oficial Stableford.

**No modifica:** Stroke Play, A-Go-Go/team_stroke, Best Ball, sus RPC, cálculos, tarjetas o componentes; tampoco modifica scores, captura física/digital, conciliación, resultados oficiales, snapshots, hándicaps, clasificaciones, cierres, pagos, publicaciones ni datos existentes. La migración es aditiva y no hace backfill.

## MIGRACIÓN 416 — CORRECCIÓN DE NOMBRE DE JUGADOR EN ACUMULADO STABLEFORD

**Objetivo:** corregir el error `column p.nombre does not exist` que impedía consultar la clasificación acumulada Stableford y, por consecuencia, bloqueaba la previsualización de finalización de torneos Stableford.

**Causa:** `obtener_resultados_stableford_torneo(p_tournament_id)` hacía `JOIN public.players p` y utilizaba `p.nombre AS player_name`, pero `public.players` no tiene una columna `nombre`; el esquema vigente almacena el nombre del jugador en `nombres` y `apellidos`.

**Qué hace:** reemplaza exclusivamente esa referencia obsoleta por `btrim(concat_ws(' ', p.nombres, p.apellidos)) AS player_name`, siguiendo el patrón vigente utilizado por otras funciones de Tee Central. La migración valida previamente que exista exactamente una ocurrencia del patrón obsoleto esperado; si la definición no coincide con ese estado, aborta sin reemplazar la función.

**Impacto funcional:** restablece la cadena `obtener_resultados_stableford_torneo` → `obtener_leaderboard_stableford_torneo` → previsualización de finalización Stableford. También elimina la misma causa de error para consumidores de la clasificación global y desempates Stableford que dependan de `obtener_resultados_stableford_torneo`.

**Seguridad:** conserva la firma, lenguaje, volatilidad, `SECURITY DEFINER`, `search_path`, permisos y toda la lógica existente de la función. No modifica datos.

**No modifica:** frontend, Stroke Play, Best Ball, A-Go-Go/team_stroke, motor matemático Stableford, resultados por ronda, snapshots, hándicap, desempates, conciliación, captura física/digital, cierres, publicaciones, pagos ni permisos.

---

## Migración 417 — Reporte detallado de scores: Stroke Play Individual

**Archivo:** `417_reporte_detallado_scores_stroke_play.sql`  
**Verificación:** `417_verificacion_reporte_detallado_scores_stroke_play.sql`

### Objetivo

Agregar una capa de reporte detallado para **Stroke Play Individual**, por categoría, que permita consumir en una sola respuesta los resultados oficiales hoyo por hoyo y los acumulados **OUT / IN / TOTAL** para Gross y Neto, sin duplicar las reglas deportivas existentes.

### Qué hace

- Crea la RPC aditiva `public.obtener_reporte_detallado_scores_stroke_play_417(p_tournament_round_id uuid, p_tournament_category_id uuid, p_criterio text)`.
- La RPC está limitada explícitamente a `scoring_engine = stroke` y `tipo_participacion = individual`.
- Reutiliza como fuentes oficiales existentes:
  - `obtener_resultados_oficiales_ronda`
  - `obtener_leaderboard_ronda`
  - `obtener_desempates_ronda`
- Devuelve los hoyos oficiales existentes de cada tarjeta y agrega para presentación del reporte:
  - Gross OUT / IN / TOTAL.
  - Neto OUT / IN / TOTAL.
  - posición/base rank y evidencia de desempate disponible.
  - estado competitivo/outcome disponible.
  - Playing Handicap y datos identificadores de tarjeta/jugador.
- El criterio de presentación admite `GROSS` o `NETO` y valida que la clasificación correspondiente esté habilitada.
- Mantiene los cálculos deportivos en las funciones oficiales ya existentes; la nueva RPC funciona como capa de consulta/reporte.
- La función requiere usuario autenticado y permiso administrativo sobre el torneo.
- `PUBLIC` queda sin permiso de ejecución y `authenticated` recibe `EXECUTE`.
- Otras modalidades son rechazadas de forma controlada; 417 no implementa Stableford, Best Ball, A-Go-Go ni Stableford por equipos.

### Aislamiento y protección de motores existentes

La migración es aditiva y no redefine los motores deportivos existentes. No modifica captura, conciliación, leaderboard, desempates, cierre de ronda ni publicación de resultados.

El reporte A-Go-Go existente queda fuera del alcance de 417. Antes de la migración se registró como referencia el hash de definición de:

`obtener_reporte_scores_fisicos_categoria_a_gogo_ronda`

con MD5:

`567781c11fb33f443d61555f0950d87c`

El SQL de verificación comprueba que dicha definición permanezca intacta.

### Verificación prevista

El archivo independiente de verificación comprueba, en solo lectura:

- existencia, firma, retorno, volatilidad y `SECURITY DEFINER` de la nueva RPC;
- permisos de ejecución;
- permanencia de las funciones oficiales Stroke Play utilizadas;
- aislamiento respecto del reporte A-Go-Go;
- conservación exacta de la definición de la RPC A-Go-Go mediante su hash previo;
- disponibilidad de rondas y categorías Stroke Play Individual para prueba;
- consumo de resultados, leaderboard y desempates oficiales;
- prueba funcional autenticada con una ronda/categoría real;
- rechazo controlado de una modalidad distinta de Stroke Play Individual.

### Estado

**Preparada para ejecución manual y verificación.** La aplicación de la migración corresponde al operador; después de ejecutarla debe correrse/verificarse el SQL independiente antes de continuar con el frontend del reporte.



---

# CONTINUACIÓN AUDITADA DESDE MIGRACIÓN 417

**Base:** README 417 original, conservado íntegramente sin cambios. Las secciones siguientes se recuperaron de los README históricos individuales de cada migración; no se usaron los README truncados posteriores como base.

**418:** no se identificó evidencia verificable de una migración 418 en la documentación histórica 421; no se inventa una entrada.

## Migración 419 --- Reporte detallado de scores: Stableford Individual

**Objetivo:** agregar una capa de reporte detallado para **Stableford
Individual** que permita consultar por categoría los puntos oficiales
hoyo por hoyo, acumulados **OUT / IN / TOTAL**, y las clasificaciones
GROSS y NETO sin recalcular el motor deportivo en frontend.

**Qué hace:** crea la RPC
`public.obtener_reporte_detallado_scores_stableford_419(...)`, limitada
a Stableford individual. Entrega puntos GROSS/NETO por hoyo, HCP/Playing
HCP aplicable, OUT/IN/TOTAL, posiciones y evidencia de desempates
utilizando las fuentes oficiales existentes. Conserva la semántica
Stableford vigente, incluido PICKUP, y no modifica Stroke Play, A-Go-Go
ni Best Ball.

> Nota histórica: no se identificó en PROD un objeto de base de datos
> con sufijo 418. Este README no inventa una migración 418 sin evidencia
> verificable.

------------------------------------------------------------------------

---

## Migración 420 --- Reporte detallado de scores: Best Ball Team

**Archivo:** `420_reporte_detallado_scores_best_ball.sql`\
**Verificación:**
`420_verificacion_reporte_detallado_scores_best_ball.sql`

**Objetivo:** agregar el reporte detallado oficial de scores para **Best
Ball por equipos**, por categoría y criterio GROSS/NETO.

**Qué hace:** crea
`public.obtener_reporte_detallado_scores_best_ball_420(...)`. La unidad
competitiva es EQUIPO; entrega `teamName`, integrantes en orden con HCP
declarado y Playing HCP congelados, resultados oficiales por hoyo,
aportantes del Best Ball, OUT/IN/TOTAL, posiciones y evidencia de
desempate. Reutiliza el resultado oficial Best Ball y sus
leaderboard/desempates; no recalcula Best Ball en frontend ni modifica
A-Go-Go, Stroke Play o Stableford.

**Estado:** ejecutada y verificada estructuralmente en Supabase. La
prueba E2E visual quedó pendiente hasta disponer de una ronda Best Ball
real capturada y conciliada.

------------------------------------------------------------------------

---

## Migración 421 --- Configuración de tarjeta digital: default NO

**Archivo:** `421_configuracion_tarjeta_digital_default_no.sql`\
**Verificación:**
`421_verificacion_configuracion_tarjeta_digital_default_no.sql`

### Objetivo

Reutilizar la configuración existente
`public.tournaments.usar_tarjeta_digital` como decisión explícita de
cada torneo sobre el uso de captura digital de tarjetas, estableciendo
**NO** como comportamiento predeterminado.

### Qué hace

-   No crea una columna nueva: reutiliza
    `tournaments.usar_tarjeta_digital`.
-   Valida que la columna exista, sea `boolean` y `NOT NULL`; si el
    esquema no coincide, la migración aborta.
-   Cambia el `DEFAULT` de la columna a `false`.
-   Normaliza todos los torneos existentes a
    `usar_tarjeta_digital = false`.
-   Los torneos nuevos nacen con tarjeta digital desactivada y deberán
    activarla explícitamente cuando corresponda.
-   Agrega comentario descriptivo a la columna.
-   La operación se ejecuta dentro de una transacción.

### Alcance deliberado

421 **no** reactiva todavía el QR en el PDF, no habilita captura pública
sin login, no modifica `tournament_score_cards.qr_token`, no cambia RPCs
de captura, no modifica sesiones, scores, conciliación, resultados,
motores deportivos, cierres ni publicaciones.

La integración posterior de frontend permitirá seleccionar **¿Utilizar
tarjetas digitales? SÍ / NO** y las etapas siguientes harán que esa
decisión controle la impresión del QR y la captura digital pública por
token.

---

## Migración 422 --- Bloqueo de tarjeta digital después de emisión oficial

**Archivo:** `422_bloquear_tarjeta_digital_post_emision.sql`\
**Verificación:**
`422_verificacion_bloqueo_tarjeta_digital_post_emision.sql`

### Objetivo

Proteger en backend la decisión `tournaments.usar_tarjeta_digital` para
que pueda modificarse durante la preparación operativa del torneo, pero
quede definitivamente bloqueada cuando ya se hayan emitido tarjetas
oficiales.

### Regla operativa

-   Antes de la primera emisión oficial de tarjetas:
    `usar_tarjeta_digital` puede cambiarse entre SÍ y NO.
-   Preparar grupos no bloquea la opción.
-   Validar salidas no bloquea la opción.
-   El congelamiento de condiciones no bloquea la opción.
-   En cuanto cualquier ronda del torneo tenga una emisión oficial con
    `tournament_score_card_emissions.status = 'issued'`, la opción queda
    inmutable para todo el torneo.
-   El bloqueo se aplica en Supabase mediante trigger, por lo que no
    depende de que la UI respete la regla.

### Qué hace

-   Crea `public._proteger_tarjeta_digital_post_emision_422()`.
-   Crea `trg_proteger_tarjeta_digital_post_emision_422` sobre
    `UPDATE OF usar_tarjeta_digital` en `public.tournaments`.
-   Si el valor no cambia, permite el `UPDATE`.
-   Si el valor cambia y ya existe una emisión oficial `issued` para
    cualquier ronda del torneo, aborta con error `55000`.
-   Usa como fuente de verdad la misma tabla/estado que la
    infraestructura existente `_ronda_tiene_tarjetas_emitidas`:
    `tournament_score_card_emissions.status = 'issued'`.
-   No consulta ni modifica `tournament_condition_freezes`.
-   No cambia ningún valor existente.
-   No reactiva todavía QR, no modifica PDF y no habilita captura
    pública.

### UI asociada

La configuración del torneo deberá mostrar **TARJETA DIGITAL --- ¿Se
utilizará captura digital de scores durante el torneo? SÍ / NO**,
leyendo y guardando directamente `tournaments.usar_tarjeta_digital`.

En **Tarjetas → EMISIÓN OFICIAL DE TARJETAS**, mientras todavía no
exista emisión oficial, se mostrará un aviso dinámico:

**IMPORTANTE:** El torneo está configurado para **USAR TARJETAS
DIGITALES** / **NO USAR TARJETAS DIGITALES**. Antes de emitir las
tarjetas puede modificar esta opción. Después de la emisión ya no podrá
modificarse.

Después de la emisión, la configuración deberá mostrarse como no
editable.

---

## Migración 423 --- Infraestructura transversal de tarjeta digital por QR

**Archivo:** `423_infraestructura_qr_tarjeta_digital.sql`\
**Verificación:**
`423_verificacion_infraestructura_qr_tarjeta_digital.sql`

### Objetivo

Crear una infraestructura común de acceso y captura pública por QR para
las tarjetas oficiales de Tee Central, independiente del motor
deportivo. La tarjeta oficial continúa siendo `tournament_score_cards` y
su `qr_token` identifica de forma única la tarjeta. La infraestructura
queda preparada para Stroke Play individual, Stableford individual,
A-Go-Go/TEAM STROKE y Best Ball. Stableford TEAM podrá conectarse
posteriormente al mismo control común cuando exista su motor.

### Principio operativo

-   El QR permite abrir/consultar la tarjeta sin login.
-   Escanear el QR no toma automáticamente el control de escritura.
-   Solo un dispositivo por tarjeta puede tener control de edición a la
    vez.
-   El control técnico es temporal, distinto del `qr_token`, no
    identifica a una persona y no se imprime.
-   Lease: 5 minutos; el frontend renovará aproximadamente cada 30
    segundos mientras corresponda.
-   `DEJAR DE MARCAR` libera únicamente el dispositivo; no cierra la
    tarjeta ni la sesión deportiva.
-   El Comité puede liberar administrativamente un control atascado.
-   La sesión deportiva existente (`ready → in_progress → captured`) se
    conserva y no se crea automáticamente desde el QR.
-   La tarjeta física y la conciliación continúan siendo parte del
    proceso oficial.

### Qué crea

-   Tabla `tournament_scorecard_qr_capture_controls` para leases
    técnicos por tarjeta, con un índice único parcial que garantiza como
    máximo un control no liberado por `score_card_id`.
-   RLS activo y sin acceso directo para `anon`/`authenticated`; el
    acceso se hace exclusivamente por RPC `SECURITY DEFINER`
    token-scoped.
-   Helpers internos de hash, candado por tarjeta y validación del
    control.
-   RPC públicas 423 para:
    -   consultar tarjeta por QR;
    -   iniciar captura;
    -   renovar control;
    -   dejar de marcar;
    -   registrar/corregir resultado por QR;
    -   registrar inconformidad por QR.
-   RPC autenticada del Comité para liberar un control QR.

### Origen y auditoría

Se agregan `entry_source`/`actor_source` y `qr_capture_control_id` en
las tablas de scores/eventos comunes y Best Ball. Las filas históricas
NO se reclasifican: las nuevas columnas quedan `NULL` para
historia/legacy y `qr_public` se usa únicamente en operaciones nuevas
por QR.

Una operación QR no inventa identidad humana. La bitácora registra
tarjeta, hoyo, valores, fecha/hora, origen QR y el control técnico
utilizado. El `qr_token` no se copia al historial.

### Inconformidad

La captura QR puede registrar una `qr_disputed` sobre un resultado ya
capturado. No se atribuye a un jugador. El hoyo queda `disputed` y ya no
puede ser reescrito por el capturista QR; pasa a conciliación/Comité.
Las funciones de conciliación/resultados se adaptan para reconocer
`qr_disputed` junto con `player_disputed` en el historial.

### Motores

-   Stroke Play individual: SCORE.
-   Stableford individual: SCORE o PICKUP.
-   A-Go-Go / `team_stroke`: SCORE del equipo; no PICKUP.
-   Best Ball: SCORE o PICKUP por integrante y hoyo, usando sus tablas
    propias.

El acceso, lease, heartbeat, liberación y seguridad son comunes; la
escritura se despacha según `scoring_engine`.

### Convivencia con marcadores legacy

Las asignaciones circulares y tablas de marcadores no se eliminan en
423. La inicialización existente puede seguir creándolas. Para evitar
una regresión en torneos históricos que heredaron
`usar_tarjeta_digital=true`, 423 no bloquea globalmente toda captura
legacy solo por ese flag. Sí bloquea una escritura legacy que compita
con un control QR vigente sobre la misma tarjeta. La transición completa
de UI al flujo QR se hará en la fase frontend.

### Best Ball

423 hace inmutable `tournament_best_ball_scorecard_events` mediante
trigger, alineando su bitácora con la protección ya existente en
`tournament_scorecard_events`. No existen actualmente tarjetas Best Ball
emitidas en PROD; su prueba E2E deberá realizarse cuando exista una
ronda Best Ball real.

### Seguridad

-   `anon` no recibe permisos directos sobre tablas de scores, eventos,
    sesiones ni controles.
-   Las RPC públicas resuelven siempre `qr_token → tarjeta oficial` en
    servidor.
-   Las escrituras requieren además el token temporal del control
    activo.
-   El token de control se almacena únicamente como SHA-256; el valor en
    claro se devuelve al navegador al adquirir el lease.
-   Cada escritura vuelve a validar tarjeta, emisión,
    `usar_tarjeta_digital` y control activo.
-   Se reutiliza el candado transaccional por tarjeta con clave `18401`
    para serializar adquisición/escritura y evitar dos escritores.

### Fuera de alcance

423 no elimina marcadores legacy, no crea sesiones faltantes, no
modifica PDF, no cambia el algoritmo deportivo de ninguna modalidad, no
implementa Stableford TEAM y no reemplaza la tarjeta física ni la
conciliación.

---

## Migración 424 --- Lectura pública enriquecida de tarjeta digital por QR

**Objetivo:** enriquecer la lectura pública de la tarjeta digital
abierta desde el QR para que el capturista pueda identificar
inequívocamente la tarjeta física antes de iniciar la captura.

**Qué hace:** - agrega la RPC
`obtener_tarjeta_publica_qr_424(p_qr_token, p_control_token)`; -
conserva intacta `obtener_tarjeta_publica_qr_423` y todo el mecanismo
423 de control exclusivo, heartbeat, liberación, escritura e
inconformidad; - devuelve nombre del torneo, ronda, folio, modalidad,
participación, `unit_type` e información congelada de salida; - para
`unit_type='registration'`, devuelve la identidad deportiva congelada
del jugador y sus handicaps disponibles; - para `unit_type='team'`,
devuelve nombre del equipo e integrantes desde los snapshots oficiales
correspondientes; - devuelve PAR y SI/Stroke Index desde
`tournament_round_hole_snapshots`; - devuelve resultados digitales y
progreso cuando ya existe sesión de captura; - permite identificar la
tarjeta y consultar sus hoyos estructurales aun cuando el estado sea
`not_initialized`; - mantiene `invalid` y `digital_disabled` sin
exposición de información deportiva; - no expone correo, teléfono, fecha
de nacimiento ni identificadores de autenticación; - no crea tablas ni
modifica motores deportivos.

**Regla arquitectónica importante:** la unidad de la tarjeta se
determina por `tournament_score_cards.unit_type`, no por el nombre de la
modalidad. El futuro Stableford por equipos conservará una tarjeta
individual por jugador (`unit_type='registration'`) y el resultado TEAM
será calculado por el motor a partir de esas tarjetas individuales. No
se crea una tarjeta adicional de equipo para capturar el score agregado.

**Fuera de alcance de 424:** VENTAJA por hoyo, puntos Stableford y
cualquier nueva lógica de captura deportiva. Esos elementos quedan para
la Fase 2.

---

## Migración 425 — Cierre explícito de captura digital por QR

**Objetivo:** separar la liberación temporal del dispositivo (`DEJAR DE MARCAR`) del cierre formal de la responsabilidad de captura digital de una tarjeta (`CERRAR CAPTURA`).

La migración agrega a `tournament_scorecard_capture_sessions` un estado persistente de cierre digital mediante `digital_closed_at` y la referencia al control QR que realizó el cierre. También conserva la última reapertura administrativa y crea la bitácora inmutable `tournament_scorecard_qr_capture_closure_events` para registrar cierres y reaperturas.

Se incorpora `cerrar_captura_digital_qr_425(p_qr_token, p_control_token)`. Solo el dispositivo que mantiene el control QR vigente puede cerrar y únicamente cuando la tarjeta está completa: no debe existir ningún resultado `pending` y la sesión debe encontrarse en `captured`. Una inconformidad (`disputed`) cuenta como resultado capturado y no impide el cierre. Al cerrar se libera inmediatamente el lease del dispositivo.

Una tarjeta cerrada queda disponible por QR exclusivamente en modo lectura. `iniciar_captura_qr_423` fue reforzada para impedir adquirir un nuevo control mientras exista `digital_closed_at`. Como el cierre libera el lease vigente, las RPC de escritura QR existentes tampoco pueden seguir escribiendo con el token anterior.

Se agrega `obtener_tarjeta_publica_qr_425(p_qr_token, p_control_token)`, que conserva el contrato enriquecido de la lectura 424 y añade `digitalCapture.closed`, `closedAt` y `lastReopenedAt`. Cuando la tarjeta está cerrada devuelve `captureState='closed'` y `controlState='free'` para que cualquier dispositivo muestre la tarjeta en modo lectura y no ofrezca iniciar captura.

Se agrega `reabrir_captura_digital_qr_admin_425(p_score_card_id, p_reason)`. La reapertura requiere usuario autenticado con permisos administrativos del torneo y no se permite si la captura global de la ronda ya está cerrada. La reapertura no modifica scores: únicamente vuelve a habilitar la posibilidad de adquirir control QR para efectuar una corrección autorizada.

**Regla operativa:** `DEJAR DE MARCAR` libera un dispositivo pero no termina la captura. `CERRAR CAPTURA` declara terminada la responsabilidad digital de esa tarjeta. El cierre digital no sustituye la recepción de la tarjeta física, la captura física ni la conciliación.

**Verificación:** comprobar columnas de cierre/reapertura, RLS y bitácora, RPCs 425 y permisos; después de una prueba real, verificar que la tarjeta cerrada tenga `digital_closed_at`, que exista un evento `capture_closed`, que el QR permanezca en lectura y que solo una reapertura administrativa permita volver a adquirir control.

---

## Migración 426 — Adaptador QR a la operación Stableford Individual existente

**Objetivo:** reincorporar el acceso por QR a la tarjeta digital Stableford ya existente sin reconstruir el motor deportivo ni mantener dos implementaciones de las mismas reglas.

La migración extrae la lógica deportiva que ya utilizaba `obtener_operacion_stableford_tarjeta_415` a un núcleo privado único: `_obtener_operacion_stableford_tarjeta_core_426(p_score_card_id, p_include_physical)`. Ese núcleo conserva el Playing Handicap congelado, distribución de golpes por Stroke Index, SCORE/PICKUP, puntos Gross y Neto, clasificaciones configuradas, regla especial de Hole in One y orden de juego que ya utilizaba la operación 415.

`obtener_operacion_stableford_tarjeta_415(p_score_card_id)` conserva su nombre, firma, autenticación y guard de permisos anteriores; después del guard delega el cálculo al núcleo 426. Por tanto, la pantalla autenticada existente y el QR dejan de tener cálculos Stableford independientes y comparten una sola fuente de verdad.

Se agrega `obtener_tarjeta_publica_qr_426(p_qr_token, p_control_token)`. Parte de la lectura pública 425 y, únicamente cuando la tarjeta oficial corresponde a Stableford Individual (`scoring_engine='stableford'`, `participation_type='individual'`, `unit_type='registration'`), agrega `digitalOperation` generado por el mismo núcleo deportivo. La variante pública excluye los campos de captura física; no abre tablas ni expone la conciliación.

**Seguridad:** el núcleo 426 es `SECURITY DEFINER` pero no tiene `EXECUTE` para `PUBLIC`, `anon` ni `authenticated`; solo las RPC controladas pueden invocarlo. La lectura QR 426 mantiene la validación QR y estados de 425. Esta migración no modifica las escrituras 423, el lease/control del dispositivo, inconformidades ni el cierre 425.

**Regla arquitectónica:** 426 no crea un segundo motor Stableford. Reorganiza la operación ya existente para que tanto la tarjeta autenticada anterior como el nuevo acceso público QR consuman exactamente la misma lógica deportiva. El mismo criterio deberá aplicarse a las modalidades ya existentes cuando se conecten al QR: adaptar acceso y control, no reconstruir la tarjeta digital.

**Fuera de alcance:** A-Go-Go, Best Ball, Stableford TEAM futuro, captura física, conciliación, emisión/PDF y cambios de reglas deportivas.

**Verificación:** confirmar funciones y permisos, comprobar que 415 delega en el núcleo 426, probar una tarjeta Stableford Individual emitida y verificar que `digitalOperation` devuelve PH, clasificaciones, `handicapStrokes`, puntos Gross/Net y hoyos sin exponer campos `physical*` en la lectura pública.

---

## Migración 427 — CORREGIR VOLATILIDAD QR 426

**Objetivo:** corregir la clasificación de volatilidad de `public.obtener_tarjeta_publica_qr_426(text,text)` para que la lectura pública QR pueda ejecutar correctamente la cadena `426 → 425 → 424`.

**Qué hace:**
- Cambia únicamente `obtener_tarjeta_publica_qr_426(text,text)` de `STABLE` a `VOLATILE`.
- La corrección es necesaria porque `obtener_tarjeta_publica_qr_424` realiza mantenimiento de controles QR expirados mediante `UPDATE`; una función `STABLE` no puede ejecutar esa cadena de escritura.
- Mantiene `_obtener_operacion_stableford_tarjeta_core_426` como `STABLE`, porque ese core es de solo lectura.
- No cambia firmas, permisos, lógica deportiva, cálculo Stableford, control QR, cierre digital ni datos existentes.

**Verificación esperada:** 424, 425 y 426 deben quedar `VOLATILE`; el core Stableford 426 debe permanecer `STABLE`.

---

## Migración 428 — CORREGIR POLICY STORAGE VEHÍCULOS 367

**Objetivo:** impedir que la policy pública de carga de fotografías de vehículos de Acceso al Campo interfiera con subidas autenticadas de otros buckets de Storage.

**Diagnóstico confirmado:** `acceso_campo_vehiculos_insert_367` estaba asignada a `{anon, authenticated}` y utiliza `_storage_upload_vehiculo_autorizado_367(name)`. El helper corresponde al flujo público autorizado de vehículos y tiene EXECUTE para `anon` y `service_role`, pero no para `authenticated`. Esto podía causar `permission denied` durante cualquier INSERT autenticado en Storage, incluso en `logos-torneos`.

**Qué hace:** cambia únicamente la policy `acceso_campo_vehiculos_insert_367` para que aplique a `anon`. Mantiene intactos el `WITH CHECK`, el helper 367, buckets, datos y `logos_torneos_insert`. No concede permisos innecesarios al rol `authenticated`.

**Verificación esperada:** policy 367 con `{anon}`; `logos_torneos_insert` con `{authenticated}`; permisos del helper sin cambios.

---

## Migración 429 — CORREGIR INCONFORMIDAD RESUELTA EN CONCILIACIÓN

**Objetivo:** evitar que una inconformidad digital ya resuelta formalmente por Comité continúe apareciendo como `INCONF. ACTIVA` en la lectura de conciliación, conservando íntegra la evidencia histórica de la tarjeta.

**Diagnóstico confirmado:** en `STABLEFORD CON QR`, tarjeta `R01-V01-0003` de Melgoza Ignacio, hoyo 1, la evidencia vigente conserva digital 4, reclamo del jugador 3, físico 5 y una resolución administrativa `PHYSICAL = 5`. La conciliación está `COMPLETED` y no tiene casos pendientes, pero `obtener_conciliacion_tarjeta_score` seguía clasificando la inconformidad como `ACTIVE` únicamente porque `tournament_scorecard_hole_scores.status` permanece `disputed`.

**Qué hace:** actualiza exclusivamente `obtener_conciliacion_tarjeta_score(uuid)` para consultar también `tournament_scorecard_hole_resolutions`. Cuando existe una resolución formal para un hoyo que tuvo inconformidad, la lectura lo clasifica como `HISTORICAL_RESOLVED` antes de evaluar el `status='disputed'` de la captura digital original.

**Trazabilidad:** no modifica `tournament_scorecard_hole_scores.status`, no borra `qr_disputed`/`player_disputed`, no elimina el reclamo del jugador y no altera los snapshots digital, físico ni la resolución administrativa. El estado `disputed` original permanece como evidencia; únicamente cambia su interpretación dentro de la conciliación una vez que Comité ya resolvió el hoyo.

**Efecto esperado en la pantalla:** una conciliación completada con una inconformidad ya resuelta debe mostrar `INCONF. ACTIVAS = 0` e incrementar `INCONF. HIST. RESUELTAS`. Las diferencias y los casos que requirieron revisión pueden permanecer como evidencia histórica de lo ocurrido. `needsReview` continúa describiendo que el hoyo requirió revisión; no significa que siga pendiente.

**Compatibilidad:** no modifica `finalizar_conciliacion_tarjeta_score`, porque esa función ya considera resuelto un caso cuando existe `tournament_scorecard_hole_resolutions` y el caso verificado tenía `unresolved = 0`. No cambia motores Stroke, Stableford, A-Go-Go o Best Ball, captura QR 423, cierre QR 425, resultados, HCP, cierres competitivos ni datos existentes.

**Verificación esperada:** la función permanece `STABLE SECURITY DEFINER`; la definición incorpora la resolución formal al cálculo de `dispute_status`; en el caso Melgoza el historial sigue siendo digital 4 / reclamo 3 / físico 5 / resolución PHYSICAL 5, mientras la lectura de conciliación deja de contarlo como inconformidad activa.

---

## Migración 430 — CORREGIR DATOS GENERALES A-GO-GO EN ASISTENTE

**Objetivo:** corregir la evidencia descriptiva de **Datos generales** que consume el Asistente Operativo para que la modalidad **A-Go-Go** (`scoring_engine = team_stroke`) no exija el campo general `tournaments.handicap_allowance_pct`, ya que esta modalidad utiliza su configuración específica de **HCP TEAM**.

**Diagnóstico confirmado:** en **PRUEBA A-GO-GO CON QR**, la modalidad es `A_GOGO`, el motor es `team_stroke`, `handicap_allowance_pct` está en `NULL` y el propio catálogo de la modalidad tiene `handicap_allowance_default = NULL`. La función `obtener_estado_datos_generales_torneo_405(uuid)` exigía `PORCENTAJE_HANDICAP` indiscriminadamente para todas las modalidades. Por ello, `obtener_workflow_evaluado_395(uuid)` mantenía pendiente `TOURNAMENT_CONFIGURATION_COMPLETE` y el Asistente 396 seguía mostrando **Configurar datos generales**, aunque el torneo hubiera avanzado operativamente.

**Qué hace:** reemplaza únicamente `public.obtener_estado_datos_generales_torneo_405(uuid)`. La función obtiene el `scoring_engine` de la modalidad y mantiene `PORCENTAJE_HANDICAP` como obligatorio para las modalidades que usan el allowance general, pero lo excluye de `missingOrInvalid` y `requiredFields` cuando `scoring_engine = 'team_stroke'`. La respuesta agrega `requiresGeneralHandicapAllowance` y `scoringEngine` para hacer explícita la evidencia.

**Qué no hace:** no agrega un HCP Allowance general a A-Go-Go; no modifica `tournaments.handicap_allowance_pct`; no modifica la configuración ni el cálculo del HCP TEAM; no toca motores deportivos, inscripciones, congelamiento, workflow 395/396 ni `tournament_workflow_nodes`.

**Efecto esperado:** el Asistente se reevalúa dinámicamente. En **PRUEBA A-GO-GO CON QR**, `Configurar datos generales` debe quedar completo inmediatamente después de aplicar 430 si no existe otro dato general faltante, sin recrear el torneo ni reconstruir nodos materializados.

**Verificación:** comprobar la definición STABLE de la función 405; verificar que A-Go-Go devuelve `requiresGeneralHandicapAllowance=false` y no reporta `PORCENTAJE_HANDICAP`; comprobar como control de regresión que modalidades distintas de `team_stroke` continúan exigiendo el porcentaje general cuando corresponde.

---

## Migración 431 --- RECUPERAR Y CANCELAR BORRADOR DE INSCRIPCIÓN GRUPAL

**Objetivo:** hacer recuperable e idempotente la preparación de una
inscripción grupal por equipos antes del pago, evitando que un borrador
creado correctamente en Supabase bloquee al mismo jugador cuando el
formulario se cierra, se recarga, se reinicia o la respuesta de creación
no llega al frontend.

**Diagnóstico confirmado:**
`crear_equipo_grupal_con_slot_inicial(uuid,text)` crea el equipo y el
slot inicial del jugador antes del pago;
`agregar_slot_provisional_inscripcion_grupal` crea los demás slots
provisionales. Las inscripciones formales en `tournament_registrations`
se crean posteriormente, únicamente después del pago aprobado. En el
caso **PRUEBA A-GO-GO CON QR / Equipo Prueba**, quedaron 1 equipo y 2
slots provisionales pero 0 inscripciones formales. Al reiniciar el
formulario, el mismo slot inicial provocaba
`GROUP_REGISTRATION_ACTIVE_ROSTER` y el mensaje "Ya formas parte de un
equipo o tienes una invitación activa en este torneo".

**Regla económica preservada:** un team o roster provisional previo al
pago es solamente un **BORRADOR**. No equivale a inscripción deportiva.
`tournament_registrations` continúa creándose exclusivamente después de
pago aprobado. La auditoría confirmó también que el flujo individual
`procesar_resultado_pago` retorna sin crear inscripción cuando el pago
no es aprobado.

**Qué hace:** - Agrega `obtener_borrador_inscripcion_grupal_431(uuid)`,
que permite al jugador autenticado recuperar su propio borrador grupal
no pagado y sus slots activos. - Hace idempotente
`crear_equipo_grupal_con_slot_inicial(uuid,text)`: si el jugador ya
tiene su propio borrador grupal no pagado para ese torneo, devuelve el
mismo `teamId`/`slotId` con `status='recovered'` en lugar de intentar
crear otro equipo y lanzar `GROUP_REGISTRATION_ACTIVE_ROSTER`. -
Conserva el bloqueo cuando el conflicto corresponde realmente a otra
inscripción, otro roster/invitación, una pre-reserva o una reserva
telefónica. - Agrega `cancelar_borrador_inscripcion_grupal_431(uuid)`.
La cancelación explícita solo es posible si el equipo no tiene
inscripciones formales ni coberturas pagadas; cancela slots
provisionales, cierra intentos de pago todavía pendientes y da de baja
lógica al team borrador. - No borra físicamente el borrador: conserva
trazabilidad mediante estados `cancelled` y `activo=false`.

**Qué no hace:** no crea inscripciones antes del pago, no convierte
slots a `tournament_registrations`, no cambia tarifas, no modifica
motores A-Go-Go/Best Ball/Stableford, no toca HCP TEAM, tarjetas, QR,
resultados ni workflow del torneo.

**Frontend requerido después de aplicar 431:** al abrir
`GroupRegistrationFlow`, consultar
`obtener_borrador_inscripcion_grupal_431`. Si `found=true`, restaurar
`createdTeamId`, `createdSlotId` y los slots persistidos en memoria y
continuar el mismo borrador. La X, Esc, recarga o navegación no deben
cancelar automáticamente el borrador. Debe existir una acción explícita
**CANCELAR INSCRIPCIÓN GRUPAL** que invoque
`cancelar_borrador_inscripcion_grupal_431`.
`crear_equipo_grupal_con_slot_inicial` queda además como defensa
idempotente ante cortes de red o respuestas perdidas.

**Verificación esperada:** el caso `Equipo Prueba` continúa con 0
inscripciones formales; al reabrir el flujo el borrador se recupera sin
crear otro equipo; reintentar la creación devuelve el mismo team; la
cancelación explícita deja team inactivo y slots cancelados sin crear
inscripciones. Los flujos de pago individual y grupal continúan creando
`tournament_registrations` únicamente después de resultado aprobado.

---

## Migración 432 --- WORKFLOW POR MODALIDAD Y COMPOSICIÓN DE EQUIPOS

**Objetivo:** corregir el Workflow Maestro y el Asistente Operativo para
que el recorrido previo a una ronda respete la modalidad competitiva. En
particular, un torneo **A-Go-Go** (`A_GOGO / equipo / team_stroke`) con
inscripciones cerradas no debe recomendar **CONGELAR CONDICIONES**
mientras la composición de equipos o el HCP TEAM sigan pendientes.

**Diagnóstico confirmado:** en **PRUEBA A-GO-GO CON QR**, después de
cerrar inscripciones el Asistente recomendó **CONGELAR CONDICIONES**
aunque existían 16 inscripciones activas y 13 jugadores activos sin
`tournament_team_id`. El maestro tenía `FREEZE` en secuencia 70, antes
de `ROUND_TEAM_HCP` (80), grupos (90), preparación de salidas (100) y
validación (110). Además no existía un nodo **FORMAR EQUIPOS**. El
evaluador 395 sí reconocía `team_stroke` para HCP TEAM, pero no evaluaba
la composición de equipos.

**Qué hace:** agrega al maestro el nodo condicional `TEAM_COMPOSITION`
en secuencia 70, con la acción **Formar equipos**. Su aplicabilidad
exige exactamente `A_GOGO / equipo / team_stroke` y su evidencia
reutiliza `obtener_estado_equipos_incompletos_a_gogo_274(uuid)`,
incluida su regla vigente `compositionReady`; 432 no inventa una segunda
definición de equipo competitivo. `ROUND_TEAM_HCP` también queda
explícitamente restringido a A-Go-Go TEAM en el evaluador. `FREEZE` pasa
a secuencia 115, después de **Validar y cerrar salidas** y antes de
**Emitir tarjetas**.

**Orden A-Go-Go resultante:**
`Cerrar inscripciones → Formar equipos → Configurar HCP de equipos → Preparar grupos → Preparar salidas → Validar y cerrar salidas → Congelar condiciones → Emitir tarjetas → Iniciar torneo`.

**Distinción por modalidad:** los pasos `TEAM_COMPOSITION` y
`ROUND_TEAM_HCP` no se activan por el simple hecho de que exista
cualquier competencia por equipos. La 432 exige la combinación A-Go-Go
actual (`code=A_GOGO`, `tipo_participacion=equipo`,
`scoring_engine=team_stroke`). De esta forma Stroke Play Individual y
Stableford Individual los omiten, y Best Ball o Stableford por equipos
no heredan automáticamente reglas propias de A-Go-Go. Sus recorridos
podrán usar sus propias evidencias cuando corresponda.

**Arquitectura:** `obtener_workflow_evaluado_395(uuid)` continúa siendo
descriptiva, con `assistantRole=GUIDE_ONLY` y
`writesOperationalState=false`. La migración modifica su
evaluación/selección de `nextAction`, pero no convierte al Asistente en
autoridad deportiva ni ejecuta acciones. El freeze sigue siendo una
operación existente del torneo; únicamente deja de ser recomendado antes
de completar la preparación previa.

**Qué no hace:** no modifica motores Stroke, Stableford, A-Go-Go o Best
Ball; no modifica el cálculo de HCP TEAM; no asigna jugadores a equipos;
no prepara ni valida salidas; no congela condiciones; no emite tarjetas;
no toca QR, pagos, inscripciones, resultados, conciliación ni cierres.
Tampoco materializa `tournament_workflow_nodes`.

**Verificación esperada:** el maestro debe mostrar
`TEAM_COMPOSITION=70`, `ROUND_TEAM_HCP=80`, `ROUND_GROUPS=90`,
`ROUND_STARTS_PREPARE=100`, `ROUND_STARTS_VALIDATE=110`, `FREEZE=115` y
`SCORECARD_EMISSION=120`. En **PRUEBA A-GO-GO CON QR**, mientras la
evidencia 274 reporte composición pendiente, el Asistente autenticado
debe mostrar **FORMAR EQUIPOS**. Una vez resuelta la composición debe
avanzar a **CONFIGURAR HCP DE EQUIPOS**, y el freeze sólo debe aparecer
después de validar salidas.

---

## 432A — Corrección del orden de workflow: congelamiento antes de grupos/salidas

**Objetivo.** Corregir la Migración 432 ya aplicada para restablecer el orden operativo común: el congelamiento de condiciones ocurre antes de preparar grupos y salidas. La composición de equipos se evalúa antes del congelamiento en modalidades por equipos; el HCP TEAM permanece como paso exclusivo de A-Go-Go.

**Qué hace.**
- `TEAM_COMPOSITION` aplica a formatos con `tipo_participacion = equipo`.
- A-Go-Go conserva como evidencia especializada `obtener_estado_equipos_incompletos_a_gogo_274`.
- Best Ball y Stableford por equipos consideran resuelta la composición cuando todas las inscripciones activas están asignadas a un equipo activo; no se introduce HCP TEAM en esas modalidades.
- `FREEZE` pasa a secuencia 85, antes de grupos (90), salidas (100), validación (110) y emisión (120).
- El evaluador 395 queda con el flujo: pasos iniciales → pasos específicos pre-freeze → freeze → preparación de ronda → emisión → inicio.
- No modifica motores deportivos, reglas de score, autorizaciones ni funciones de congelamiento.

**Orden operativo resultante.**
- Individual: cerrar inscripciones → congelar → grupos → salidas → validar → emitir.
- Best Ball / Stableford equipo: cerrar inscripciones → formar equipos → congelar → grupos → salidas → validar → emitir.
- A-Go-Go: cerrar inscripciones → formar equipos → HCP TEAM → congelar → grupos → salidas → validar → emitir.


Este documento conserva un registro breve de cada migración aplicada o
preparada en el proyecto.

**Proyecto Supabase:** `GOLFING_FULL`\
**Aplicación:** las migraciones se ejecutan manualmente en Supabase, en
orden.\
**Criterio del README:** una entrada por migración, sin repetir el SQL.
Supabase es la fuente de verdad del esquema vivo.

---

## 433 — Formalización de resultados A-Go-Go y orden de cierre

**Objetivo.** Integrar A-Go-Go (`equipo / team_stroke`) al contrato operativo común de resultados, cierres por categoría y publicación oficial, reutilizando el leaderboard A-Go-Go existente; impedir además que una ronda futura pueda cerrarse antes de sus categorías.

**Qué hace.**
- `obtener_leaderboard_operativo_ronda` conserva Best Ball y el fallback histórico, y agrega el despacho `team_stroke/equipo` hacia `obtener_leaderboard_a_gogo_ronda`.
- No crea un segundo cálculo: reutiliza el resultado, rankings y desempates ya encapsulados por el leaderboard A-Go-Go.
- `_estado_formalizacion_resultados_ronda_265` puede así evaluar `allCategoriesReady`, `allCategoriesClosed` y `allCategoriesPublished` para A-Go-Go.
- `cerrar_categoria_competitiva_ronda` y `publicar_resultados_categoria_ronda` conservan sus contratos existentes.
- `cerrar_ronda_competitiva` agrega un guard: cuando la formalización está soportada exige `allCategoriesClosed=true` antes del cierre histórico `_pre314`.
- No reabre ni modifica rondas ya cerradas; la ronda histórica de PRUEBA A-GO-GO CON QR puede cerrar su categoría y publicar después de 433.
- No modifica scoring, HCP TEAM, tarjetas, QR, captura, conciliación ni resultados ya calculados.

**Flujo esperado.** Captura cerrada → Revisar resultados → Cerrar categorías → Cerrar ronda → Publicar resultados → Finalizar torneo.

---

## 433A — Normalización del contrato operativo A-Go-Go

**Objetivo.** Corregir la integración introducida por 433: el leaderboard A-Go-Go ya entregaba categorías, equipos y resultados oficiales, pero su contrato histórico no incluía la bandera superior `supported`. `_estado_formalizacion_resultados_ronda_265` interpreta la ausencia de esa bandera como `false`, dejando permanentemente pendiente REVISAR RESULTADOS.

**Qué hace.**
- Mantiene el despacho `team_stroke/equipo` hacia `obtener_leaderboard_a_gogo_ronda`.
- Añade exclusivamente en el adaptador común `supported=true` y `applicable=true`.
- Conserva intactas las ramas Best Ball y fallback histórico.
- No recalcula ni modifica scores, rankings, desempates, cierres, publicaciones, HCP TEAM, tarjetas, QR, captura o conciliación.
- Resultado esperado para PRUEBA A-GO-GO CON QR: 1 categoría, 4 equipos resueltos, `allCategoriesReady=true`; el Asistente avanza de REVISAR RESULTADOS a CERRAR CATEGORÍAS.

---

## Migración 434 — MOTOR BASE STABLEFORD POR EQUIPOS

**Objetivo:** habilitar la base deportiva de Stableford por equipos reutilizando las tarjetas individuales y el cálculo Stableford existente por jugador. No se crea tarjeta TEAM ni se captura manualmente un score de equipo.

**Qué hace:**

- Registra Stableford por equipos (`participation_type=equipo`, `scoring_engine=stableford`) en el motor de salidas Shotgun.
- Mantiene la unidad competitiva como **equipo**, pero la unidad oficial de tarjeta como **registration/jugador**. Cada integrante conserva tarjeta individual, QR individual, HCP individual y Playing Handicap individual.
- El contrato de salida TEAM se expande a una unidad individual por integrante y congela en esa unidad el `tournament_team_id`, evitando depender de una membresía mutable posterior.
- Agrega `effective_through_round_hole_snapshot_id` a los outcomes para que WD/DNF puedan conservar únicamente las aportaciones anteriores al abandono. No se infiere el hoyo por hora. DNS, DQ y NO_CARD no usan esta frontera.
- Los huecos están permitidos: **SIN SCORE** no equivale a PICKUP ni a abandono. Un jugador puede no tener score en uno o varios hoyos y volver a aportar posteriormente.
- `PICKUP` es un resultado válido de **0 puntos**.
- Crea `obtener_resultado_stableford_tarjeta_434(uuid)`, reutilizable para tarjetas individuales Stableford tanto de participación individual como de participación por equipos.
- Crea `obtener_resultado_stableford_equipo_ronda_434(round_id, team_id)`: por cada hoyo selecciona siempre **mejor 1** aportación válida. Gross y Neto se seleccionan de manera independiente; pueden provenir de jugadores distintos.
- Si varios integrantes empatan con la mejor aportación del hoyo, el equipo recibe los puntos una sola vez y se conservan todos los contribuyentes empatados para trazabilidad.
- Si ningún integrante tiene aportación utilizable en un hoyo, el equipo recibe 0 y el resultado conserva `hasContribution=false`, distinguiéndolo de uno o varios PICKUP.
- Outcomes: DNS no aporta; DQ/NO_CARD invalidan todas las aportaciones; WD/DNF conservan solamente resultados existentes hasta el último hoyo válido indicado. Los huecos anteriores permanecen huecos.
- El workflow existente ya limita `TEAM_HCP_REQUIRED` a A-Go-Go/team_stroke, por lo que Stableford TEAM no requiere HCP TEAM.
- La migración 434 **no** implementa todavía leaderboard, desempates, cierre/publicación ni reporte detallado de Stableford TEAM; esos componentes se construirán después de validar el motor base con un torneo real de prueba.

**Archivos:**

- `434-MIGRACION_MOTOR_BASE_STABLEFORD_POR_EQUIPOS.sql`
- `434-VERIFICACION_MOTOR_BASE_STABLEFORD_POR_EQUIPOS.sql`
- `434-README_TEE_CENTRAL_COMPLETO.md`

**Estado:** preparada para ejecución manual y posterior verificación.

---

## 434A — CORREGIR DATOS GENERALES STABLEFORD EQUIPO

**Objetivo:** corregir el diagnóstico de datos generales usado por el Asistente Operativo para que la modalidad `STABLEFORD_EQUIPO` no exija `handicap_allowance_pct` general.

**Qué hace:** actualiza únicamente `public.obtener_estado_datos_generales_torneo_405(uuid)`. Conserva la excepción existente de A-Go-Go / `team_stroke` y agrega una excepción explícita para `STABLEFORD_EQUIPO` (`equipo` + `stableford`). En Stableford por equipos cada integrante conserva su Playing HCP individual y no existe HCP TEAM. Stroke Play y Stableford individual continúan exigiendo el porcentaje general cuando corresponde.

**Alcance:** diagnóstico/workflow del Asistente. No modifica scores, motores deportivos, congelamientos, resultados ni datos del torneo.

---

## 435 — VALIDADOR DE SALIDAS STABLEFORD POR EQUIPOS

**Objetivo:** conectar `STABLEFORD_EQUIPO` Shotgun a un validador propio y eliminar la exigencia incorrecta de HCP TEAM.

**Qué hace:** crea `_previsualizar_validacion_salidas_stableford_team_shotgun_v1`, incorpora `shotgun_stableford_team_v1` al dispatcher común y actualiza exclusivamente el registro `shotgun + equipo + stableford`. Conserva las comprobaciones TEAM y exige HCP individual congelado por integrante. No consulta `tournament_round_team_handicap_versions`.

**Regla deportiva:** Stableford por equipos no tiene HCP TEAM. Cada jugador conserva HCP/Playing HCP y tarjeta individual. El equipo puede jugar disminuido y no puede exceder `jugadores_por_equipo`.

**Validación definitiva:** `validar_salidas_ronda` no se reemplaza; ya consume el previsualizador común. El constructor Stableford TEAM de 434 continúa generando unidades `registration`.

**No regresión:** no cambia las rutas de A-Go-Go, Best Ball, Stableford individual ni Stroke Play.

---

## 435A — COMPATIBILIDAD DE UNIDAD `registration` CON STABLEFORD TEAM

**Objetivo:** permitir persistir las unidades individuales de Stableford por Equipos conservando su `tournament_team_id`.

**Causa corregida:** el CHECK histórico `round_start_validation_units_type_consistency` obligaba a que toda unidad `registration` tuviera `tournament_team_id IS NULL`. El constructor Stableford TEAM 434 genera correctamente `registrationId + playerId + teamId + snapshots HCP`, porque la tarjeta es individual pero el motor necesita conocer el equipo del jugador.

**Qué hace:** amplía únicamente el CHECK de consistencia. Para `registration` siguen siendo obligatorios `tournament_registration_id`, `player_id`, `handicap_snapshot_id` y `round_handicap_snapshot_id`; `tournament_team_id` puede ser NULL en modalidades individuales o contener el equipo en Stableford TEAM. El contrato de `unit_type='team'` permanece sin cambios.

**Qué no hace:** no crea tarjetas TEAM, no crea HCP TEAM, no modifica grupos, no modifica el motor Stableford ni los validadores 435.

**Resultado esperado:** `validar_salidas_ronda` puede persistir los jugadores de Stableford TEAM como tarjetas/unidades individuales relacionadas con su equipo.

---

## 435B — COMPATIBILIDAD DE TARJETA `registration` CON STABLEFORD TEAM

**Objetivo:** permitir emitir tarjetas oficiales individuales de Stableford por Equipos conservando `tournament_team_id`.

**Causa corregida:** el CHECK histórico `tournament_score_cards_unit_consistency` obligaba a que toda tarjeta `registration` tuviera `tournament_team_id IS NULL`. Stableford TEAM necesita una tarjeta individual por jugador que, además, conserve la relación con su equipo.

**Qué hace:** amplía únicamente el CHECK de `tournament_score_cards`. Una tarjeta `registration` sigue exigiendo `tournament_registration_id` y `player_id`; `tournament_team_id` puede ser NULL para modalidades individuales o contener el equipo para Stableford TEAM. El contrato de las tarjetas `unit_type='team'` permanece sin cambios.

**Qué no hace:** no crea tarjetas TEAM para Stableford, no crea HCP TEAM, no modifica el motor de emisión ni las reglas deportivas.

**Resultado esperado:** la emisión oficial puede crear una tarjeta individual por integrante de Stableford TEAM, manteniendo el vínculo necesario jugador → equipo para el motor de resultados.

---

## 435C — OPERACIÓN DE TARJETA STABLEFORD TEAM

**Objetivo:** reutilizar la operación Stableford individual por tarjeta para las tarjetas individuales de `STABLEFORD_EQUIPO`.

**Causa corregida:** `_obtener_operacion_stableford_tarjeta_core_426` exigía históricamente `participation_type='individual'`, aunque Stableford TEAM emite correctamente tarjetas `registration` individuales. Esto impedía preparar el PDF oficial después de una emisión correcta.

**Qué hace:** el core 426 continúa exigiendo `unit_type='registration'` y `scoring_engine='stableford'`; acepta participación individual o, de forma explícita, `participation_type='equipo'` únicamente cuando `format_code='STABLEFORD_EQUIPO'`. En el segundo caso exige y verifica el `tournament_team_id` de la tarjeta contra la unidad validada. El cálculo de Playing HCP, golpes por Stroke Index, puntos Stableford, HIO y hoyos permanece igual.

**Contrato devuelto:** `participationType` refleja ahora el valor congelado real y `scoreCard.tournamentTeamId` conserva la trazabilidad jugador → equipo.

**Qué no hace:** no crea un HCP TEAM, no crea tarjeta TEAM y no cambia el cálculo individual Stableford.

---

## 435D — SNAPSHOT DEL MOTOR STABLEFORD PARA STABLEFORD TEAM

**Objetivo:** congelar el motor Stableford por jugador también cuando la participación es `equipo` y el formato es `STABLEFORD_EQUIPO`.

**Causa:** `congelar_condiciones_y_handicaps_torneo` creaba `tournament_stableford_engine_snapshots` sólo para `participation_type='individual'`. Por eso el torneo Stableford TEAM tenía freeze y HCP individuales correctos, pero no snapshot de versión del motor.

**Qué hace:** repara freezes Stableford soportados que ya existen y amplía el filtro del congelamiento futuro para aceptar `STABLEFORD_EQUIPO`. Se conserva la misma versión de cálculo individual (`stableford_individual_v1`, tabla `R21.1_STANDARD_V1`), porque el cálculo por jugador es el mismo; el motor TEAM agrega esas aportaciones posteriormente.

**Qué no hace:** no descongela el torneo, no recalcula HCP, no crea HCP TEAM y no cambia tarjetas ni resultados capturados.

---

## Migración 436 — Activación tardía de TARJETA DIGITAL y QR para Stableford por equipos

**Objetivo.** Permitir que el organizador corrija el olvido de activar TARJETA DIGITAL después de haber emitido las tarjetas oficiales, siempre antes de iniciar el torneo, y completar la compatibilidad del wrapper QR público con `STABLEFORD_EQUIPO`.

**Qué hace.** La protección creada en 422 conserva el bloqueo post-emisión, pero admite una única transición segura después de emitir: `NO → SÍ` mientras el torneo permanezca en `inscripcion_cerrada`. La transición `SÍ → NO` continúa bloqueada después de la emisión y cualquier cambio queda bloqueado una vez iniciado el torneo. La autorización no se convierte en una operación exclusiva de SUPERADMIN: se mantienen las reglas RLS/permisos existentes del torneo, incluyendo al organizador autorizado.

La activación tardía **no anula ni reemite** tarjetas, no cambia folios y no rota `qr_token`. Las tarjetas oficiales ya contienen sus tokens; `usar_tarjeta_digital` funciona como interruptor maestro para permitir su impresión/uso digital. Al activar la opción, el organizador puede volver a generar/imprimir el PDF oficial y los mismos registros de tarjeta deben mostrar su QR.

También se actualiza `obtener_tarjeta_publica_qr_426(text,text)` para reconocer tarjetas `registration` de `STABLEFORD_EQUIPO`. Se reutiliza `_obtener_operacion_stableford_tarjeta_core_426`: cada integrante conserva su tarjeta y operación Stableford individual; no se crea tarjeta ni QR de equipo. El motor TEAM seguirá siendo una capa posterior que selecciona la mejor aportación válida por hoyo.

**UI asociada (Lovable, no forma parte de la migración).** El control `TARJETA DIGITAL SÍ/NO` debe retirarse de Información General y convertirse en la primera sección de TARJETAS. Antes de emitir puede cambiarse normalmente. Después de emitir sólo debe ofrecerse `NO → SÍ` si el torneo aún no inició; al activarlo, debe permitir reimprimir las tarjetas oficiales con sus QR. Después de emitir con SÍ, y después de iniciar el torneo, el control se muestra bloqueado.

---

## Actualización 436A — TARJETA DIGITAL reversible antes de iniciar

### Objetivo
Corregir la protección introducida en 436 para que TARJETA DIGITAL sea una
decisión operativa reversible mientras el torneo todavía no haya iniciado.

### Regla definitiva
- Antes de iniciar el torneo, TARJETA DIGITAL puede cambiarse **SÍ ↔ NO**.
- Esto aplica aunque las tarjetas oficiales ya hayan sido emitidas.
- No se reemiten tarjetas ni se regeneran `qr_token`.
- Los mismos QR permanecen asociados a las mismas tarjetas.
- Con TARJETA DIGITAL = NO, el mecanismo digital queda deshabilitado.
- Al volver a SÍ, los mismos QR vuelven a habilitar el mecanismo digital.
- Después de iniciar el torneo, TARJETA DIGITAL queda congelada.

### Alcance
La regla es general para todas las modalidades que utilizan la infraestructura
de TARJETA DIGITAL. No es específica de Stableford por equipos.

### Base de datos
Se reemplaza la función trigger:
`public._proteger_tarjeta_digital_post_emision_422()`

Se conservan:
- SECURITY DEFINER.
- `search_path = public, pg_temp`.
- El control de autorización existente mediante RLS sobre `tournaments`.
- Las tarjetas oficiales emitidas.
- Folios.
- `qr_token`.
- Validaciones y salidas.

### Relación con 436
436 habilitó NO → SÍ después de emisión antes del inicio y adaptó el QR público
para Stableford por equipos. 436A amplía únicamente la regla del interruptor:
antes del inicio ahora permite SÍ ↔ NO.

La adaptación QR de Stableford por equipos realizada en 436 permanece intacta.

### Interfaz
El cambio visual/UX se realiza en Lovable y no forma parte de esta migración.
TARJETA DIGITAL debe permanecer como primera sección de TARJETAS y permitir
SÍ ↔ NO mientras el torneo no haya iniciado. Después del inicio debe mostrarse
bloqueada.

### Verificación esperada
En `STABLEFORD-PRUEBA QR`, mientras el torneo permanezca en
`inscripcion_cerrada`, el organizador debe poder:
1. pasar de SÍ a NO;
2. comprobar que el QR existente queda digitalmente deshabilitado;
3. volver de NO a SÍ;
4. comprobar que el mismo QR vuelve a funcionar.

No debe ser necesario reemitir tarjetas para apagar o volver a encender el
mecanismo digital. Solo será necesario reimprimir cuando se necesite obtener
físicamente una tarjeta que incluya el QR.

---

## Actualización 437 --- Leaderboard y cierre competitivo base Stableford TEAM

### Objetivo

Conectar el motor deportivo Stableford por equipos creado en 434 con la
capa operativa de resultados y cierre, sin crear una tarjeta TEAM
ficticia.

### Arquitectura preservada

La tarjeta oficial de Stableford por equipos continúa siendo individual
por jugador. El flujo sigue siendo:

**Jugador → tarjeta individual → resultado Stableford individual por
hoyo → motor 434 selecciona mejor aportación → resultado TEAM →
leaderboard TEAM.**

No se crea `tournament_score_card` de tipo TEAM para Stableford por
equipos.

### Identidad de desempates

`tournament_tiebreak_resolution_players` se amplía para admitir
`tournament_team_id`. La identidad de una fila de resolución debe ser
exactamente una de estas dos:

-   `score_card_id` para modalidades históricas basadas en tarjeta
    competitiva;
-   `tournament_team_id` para Stableford TEAM.

Los registros históricos permanecen válidos y no se transforman.

### Leaderboard

Se crea: `public.obtener_leaderboard_stableford_team_ronda_437(uuid)`

La función: - consume exclusivamente el resultado TEAM derivado por el
motor 434; - agrupa por categoría; - clasifica Gross y Neto de forma
independiente; - ordena por puntos Stableford descendentes; - considera
un equipo resuelto cuando todas sus tarjetas individuales emitidas están
conciliadas o tienen outcome terminal; - expone los hoyos TEAM y sus
integrantes para trazabilidad; - usa `competitiveUnit = TEAM`; -
conserva la llave histórica `players` dentro de categorías únicamente
por compatibilidad contractual, pero cada elemento se identifica como
TEAM.

### Dispatcher común

`public.obtener_leaderboard_operativo_ronda(uuid)` agrega una rama
explícita para: - `scoring_engine = stableford` -
`participation_type = equipo` - `format_code = STABLEFORD_EQUIPO`

Best Ball, A-Go-Go y modalidades históricas conservan sus rutas previas.

### Estado competitivo

Se crea: `public.obtener_estado_cierre_stableford_team_ronda_437(uuid)`

y se conecta a: `public.obtener_estado_cierre_competitivo_ronda(uuid)`.

Con ello Stableford TEAM deja de responder "modalidad no soportada".

Estados base: - `RESULTS_PENDING`: existen equipos con tarjetas
individuales todavía no resueltas; - `TIEBREAKS_PENDING`: todos los
equipos están resueltos pero existe al menos un empate Gross o Neto; -
`READY`: resultados resueltos y sin empates pendientes; - `FINAL`: la
ronda ya tiene cierre competitivo formal.

### Desempates --- alcance de 437

437 **no declara resuelto ningún empate TEAM**. Los detecta y los deja
explícitamente en `PENDING`.

La infraestructura de identidad TEAM queda preparada para la siguiente
fase, que aplicará las reglas automáticas Stableford (últimos 9/6/3,
hoyo 18, hoyo por hoyo por Stroke Index, etc.) a los puntos TEAM por
hoyo y permitirá resolución manual por `tournament_team_id` cuando
corresponda.

Esta separación evita abrir el cierre competitivo con un empate
falsamente resuelto.

### No modifica

-   motor deportivo 434;
-   cálculo Stableford individual;
-   tarjetas oficiales emitidas;
-   QR;
-   captura digital;
-   HCP individual;
-   salidas;
-   A-Go-Go;
-   Best Ball;
-   Stroke Play.

---

## Actualización 437A --- Corrección de clasificaciones Stableford TEAM

### Antecedente

La migración 437 conectó Stableford por equipos al leaderboard operativo
y al estado competitivo común sin crear una tarjeta TEAM ficticia.

Al ejecutar el flujo real desde la sesión autenticada del organizador
apareció:

`column s.clasifica_gross does not exist`

La verificación estructural de 437 no ejecutó esa rama autenticada y por
ello el defecto se detectó al probar la pantalla real.

### Causa

`tournament_category_classification_snapshots` no almacena dos booleanos
`clasifica_gross` y `clasifica_neto`.

La estructura real congela una fila por clasificación mediante
`tipo_resultado`. Los valores existentes son:

-   `gross`
-   `neto`

En `STABLEFORD-PRUEBA QR`, la categoría `UNICA` tiene ambas filas
congeladas.

### Corrección

437A reemplaza únicamente:

`public.obtener_leaderboard_stableford_team_ronda_437(uuid)`

Ahora:

-   `gross_enabled` es verdadero cuando existe una fila congelada
    `tipo_resultado='gross'` para la categoría;
-   `net_enabled` es verdadero cuando existe una fila congelada
    `tipo_resultado='neto'` para la categoría.

### No modifica

-   motor Stableford TEAM 434;
-   cálculo Stableford individual;
-   tarjetas oficiales;
-   QR y captura digital;
-   resultados capturados;
-   dispatchers creados/conectados en 437;
-   estructura de identidad TEAM para desempates;
-   A-Go-Go;
-   Best Ball;
-   Stroke Play.

### Resultado esperado

Al recargar **Resultados y cierre** de `STABLEFORD-PRUEBA QR`, ya no
debe aparecer el error de columna inexistente. El sistema debe avanzar
al estado competitivo real de la ronda: resultados pendientes,
desempates pendientes o listo, según corresponda.

### Estado de desempates

437A no amplía el alcance deportivo de 437: los desempates TEAM
continúan reportándose como pendientes hasta implementar su resolución
específica.

---

## Actualización 438 --- Desempates automáticos Stableford por equipos

### Objetivo

Completar la capa de desempates de Stableford TEAM sin crear tarjetas
TEAM y sin exigir al organizador una acción para desempates que las
reglas del torneo pueden resolver automáticamente.

### Principio

Stableford TEAM conserva tarjetas oficiales individuales. El desempate
se calcula sobre el resultado TEAM hoyo por hoyo ya producido por el
motor 434.

### Reutilización

438 no crea un algoritmo deportivo distinto. Reutiliza:
`public.evaluar_secuencia_desempate_stableford(...)` y, a través de
éste: `public.calcular_clave_metodo_desempate_stableford(...)`.

Por tanto, los métodos existentes se interpretan exactamente igual que
en Stableford individual, pero reciben los puntos TEAM Gross/Neto de
cada hoyo.

### Reglas del torneo de prueba

`STABLEFORD-PRUEBA QR` tiene configuradas para Gross y Neto: 1.
TARJETA_ULTIMOS_9 2. TARJETA_ULTIMOS_6 3. TARJETA_ULTIMOS_3 4.
TARJETA_ULTIMO_HOYO

Se aplican automáticamente en ese orden.

### Funciones

Se crea: - `obtener_desempates_stableford_team_ronda_438(uuid)` -
`obtener_leaderboard_stableford_team_ronda_438(uuid)`

Se actualiza el dispatcher: -
`obtener_leaderboard_operativo_ronda(uuid)`

Y el estado Stableford TEAM: -
`obtener_estado_cierre_stableford_team_ronda_437(uuid)`

### Comportamiento

Si un método automático rompe completamente el empate, el grupo queda
`RESOLVED_AUTOMATIC`, se asigna `tiebreakOrder` y `finalRank`, y deja de
bloquear el cierre.

Si todas las reglas configuradas se agotan y el empate matemático
persiste, 438 NO inventa un ganador. El grupo permanece pendiente porque
el torneo no tiene configurado un método final adicional. Esa situación
requiere definir una regla deportiva final, no una decisión arbitraria
del software.

### No modifica

-   scores capturados;
-   motor 434;
-   cálculo individual Stableford;
-   tarjetas oficiales;
-   QR;
-   salidas;
-   HCP;
-   A-Go-Go;
-   Best Ball;
-   Stroke Play.

### Caso actual

El empate detectado en `STABLEFORD-PRUEBA QR`:
`UNICA · GROSS · POSICIÓN 2` debe evaluarse automáticamente al consultar
nuevamente Resultados y cierre.

---

## Actualización 439 --- Acumulado y finalización Stableford por equipos

### Objetivo

Completar la capa global de torneo para Stableford TEAM. Hasta 438 la
ronda ya tenía leaderboard y desempates automáticos, pero la
previsualización de finalización todavía clasificaba `stableford/equipo`
como no soportado.

### Clasificación acumulada TEAM

Se crea: `public.obtener_leaderboard_stableford_team_torneo_439(uuid)`

La unidad competitiva es el equipo. No se crea tarjeta TEAM.

Para cada equipo: - suma los puntos Gross TEAM de todas las rondas
requeridas; - suma los puntos Neto TEAM de todas las rondas
requeridas; - exige que el equipo tenga resultado resuelto en todas las
rondas activas Stableford TEAM para entrar al ranking acumulado; -
conserva detalle de puntos por ronda; - clasifica Gross y Neto
independientemente.

### Desempates acumulados

Cuando dos equipos empatan en puntos acumulados, 439 reutiliza:
`evaluar_secuencia_desempate_stableford_multirronda(...)`

La evidencia deportiva proviene de la última ronda y de sus puntos TEAM
por hoyo, igual que la arquitectura multirronda Stableford ya existente.

No se inventa un ganador si las reglas configuradas no logran romper el
empate.

### Finalización del torneo

Se amplía `_previsualizar_finalizacion_torneo_pre314(uuid)` de forma
quirúrgica.

Cuando todas las rondas activas congeladas son: -
`scoring_engine = stableford` - `participation_type = equipo`

el modo pasa a: `STABLEFORD_TEAM`

y `aggregateCompetition` utiliza el leaderboard TEAM 439.

El torneo sólo podrá finalizar cuando, además de los gates ya
existentes: - todas las rondas estén cerradas; - las publicaciones
oficiales requeridas estén completas; - el acumulado TEAM esté
`READY_FOR_PUBLICATION`.

### Se conserva

-   Stableford individual y su acumulado existente;
-   Stroke Play y lógica histórica;
-   A-Go-Go;
-   Best Ball;
-   motor TEAM 434;
-   tarjetas individuales;
-   QR;
-   desempates de ronda 438;
-   autorización del organizador/Superadmin existente.

### Caso de prueba

En `STABLEFORD-PRUEBA QR` debe desaparecer el mensaje:
`El cierre competitivo todavía no soporta scoring_engine=stableford / participation_type=equipo.`

Mientras la ronda continúe sin cierre/publicación formal, la
finalización debe seguir pendiente, pero por esa causa operativa real y
no por modalidad no soportada.

---

## Actualización 440 --- Formalización de resultados Stableford TEAM

### Diagnóstico

La capa pública `obtener_estado_cierre_competitivo_ronda` ya reconocía
`stableford/equipo/STABLEFORD_EQUIPO` y utilizaba
`obtener_estado_cierre_stableford_team_ronda_437`.

Sin embargo, `_estado_formalizacion_resultados_ronda_265` seguía
llamando directamente a
`_obtener_estado_cierre_competitivo_ronda_pre249`. Esa cadena termina en
la lógica histórica pre213, que sólo contempla Stroke individual y
Stableford individual y genera el error:

`El cierre competitivo todavía no soporta scoring_engine=stableford / participation_type=equipo.`

### Cambio 440

Se modifica únicamente
`_estado_formalizacion_resultados_ronda_265(uuid)`:

-   Stableford TEAM usa
    `obtener_estado_cierre_stableford_team_ronda_437(uuid)`.
-   Ese estado ya consume el leaderboard/desempates automáticos 438.
-   Las demás modalidades continúan usando exactamente la ruta histórica
    pre249.
-   No se modifica el motor deportivo.
-   No se crea tarjeta TEAM.
-   No se modifica captura, QR, HCP ni resultados por hoyo.
-   No se altera el frontend.

### Resultado esperado

`STABLEFORD-PRUEBA QR` debe dejar de mostrar el error de modalidad no
soportada. A partir de ahí, el cierre/finalización sólo debe quedar
bloqueado por pendientes reales del flujo competitivo: resultados,
cierres formales, publicaciones o lifecycle, según corresponda.

---

## Actualización 441 --- Cierre formal de ronda Stableford TEAM

### Diagnóstico

La rama Stableford TEAM de `obtener_estado_cierre_competitivo_ronda`
consumía `obtener_estado_cierre_stableford_team_ronda_437`. Cuando
resultados y desempates estaban completamente resueltos, 437 devolvía
`READY`.

La capa común de cierre y el frontend habilitan `CERRAR RONDA` cuando el
estado competitivo previo es `FINAL`. Sin embargo, la rama TEAM sólo
convertía a `FINAL` cuando ya existía una fila FINAL en
`tournament_round_competitive_closures`. Esto generaba una dependencia
circular: para crear el cierre se exigía FINAL, pero FINAL sólo aparecía
después del cierre.

### Cambio 441

-   Stableford TEAM conserva 437/438 como fuente deportiva.
-   `READY` + todas las categorías formalmente cerradas se expone como
    `FINAL`, indicando que la ronda está preparada para el cierre
    formal.
-   Si las categorías todavía no están cerradas, se expone
    `CATEGORIES_PENDING`.
-   `RESULTS_PENDING` y `TIEBREAKS_PENDING` se conservan sin
    reinterpretación.
-   La publicación oficial NO se convierte en requisito para cerrar la
    ronda. Se preserva el orden establecido: cierre de categoría →
    cierre de ronda → publicación oficial.
-   Se incorpora `resultsClosure` mediante
    `validar_cierre_resultados_ronda`, aprovechando que Stableford TEAM
    mantiene tarjetas oficiales individuales. Esto restablece el
    contrato común de Tarjetas / Resueltas / Pendientes / Outcomes para
    la interfaz.
-   Una vez persistido el cierre formal de ronda, el estado sigue siendo
    `FINAL` y `competitivelyClosed=true`.
-   No se modifica el motor Stableford TEAM, los puntos, desempates,
    tarjetas, QR, HCP, captura ni resultados por hoyo.
-   Se preservan sin cambios las ramas de Best Ball y de las demás
    modalidades.

---

## Actualización 441A --- Corrección de regresión en resultsClosure Stableford TEAM

### Diagnóstico

La 441 agregó `resultsClosure` llamando a
`validar_cierre_resultados_ronda`. Esa función no era neutral por
modalidad: para Stableford TEAM derivaba a la cadena histórica pre213 y
volvía a producir el rechazo `stableford / participation_type=equipo`.

### Corrección

-   Se elimina esa llamada exclusivamente de la rama Stableford TEAM.
-   Se conserva `obtener_estado_cierre_stableford_team_ronda_437` como
    estado deportivo y `obtener_leaderboard_stableford_team_ronda_438`
    como fuente de conteos.
-   `resultsClosure.summary` se construye sumando `memberCards`,
    `resolvedMemberCards` y `unresolvedMemberCards` que 438 ya entrega
    por equipo.
-   No se crea tarjeta TEAM: esos conteos representan las tarjetas
    individuales de los integrantes.
-   Se conserva la regla 441: `READY` + categorías formalmente cerradas
    =\> `FINAL` previo al cierre formal.
-   La publicación no es requisito para cerrar la ronda.
-   Best Ball y las demás modalidades conservan sus rutas anteriores.

---

## Actualización 441B --- Fast path de ronda cerrada Stableford TEAM

**Diagnóstico:** después del cierre formal,
`obtener_estado_cierre_competitivo_ronda` seguía recalculando el estado
TEAM mediante 437/438 y además volvía a consultar la formalización. Una
sola lectura podía disparar varias evaluaciones completas del
leaderboard y desempates, provocando `statement timeout`.

**Corrección:** para Stableford TEAM, si ya existe un cierre competitivo
`FINAL`, la función devuelve el `closure_snapshot` persistido ---que es
la evidencia inmutable del cierre--- y sólo normaliza
`competitiveStatus=FINAL` y `competitivelyClosed=true`. No recalcula
resultados, leaderboard ni desempates.

Las rondas Stableford TEAM todavía abiertas conservan la lógica 441A.
Best Ball y las demás modalidades no se modifican. La publicación
oficial continúa separada del cierre; la publicación de la ronda de
prueba permanece `PARTIAL` hasta que el organizador ejecute la
publicación oficial.

---

## Migración 442 --- REPORTE DETALLADO INDIVIDUAL STABLEFORD TEAM

**Archivo:** `442-MIGRACION_REPORTE_DETALLADO_STABLEFORD_TEAM.sql`\
**Verificación:**
`442-VERIFICACION_REPORTE_DETALLADO_STABLEFORD_TEAM.sql`

### Objetivo

Crear una fuente consolidada y escalable para el reporte individual hoyo
por hoyo de los integrantes de equipos en rondas Stableford por equipos,
evitando el patrón N×tarjeta desde el navegador y manteniendo
equivalencia deportiva con el motor Stableford TEAM instalado.

### Diagnóstico previo

Se confirmó que `obtener_resultado_stableford_tarjeta_434` calcula la
tarjeta individual usando evidencia oficial, snapshots congelados,
Playing Handicap, distribución por Stroke Index, tabla Stableford y
override de Hole In One. El motor
`obtener_resultado_stableford_equipo_ronda_434` consume esas tarjetas y
aplica posteriormente la elegibilidad por outcome para seleccionar BEST
1 por hoyo.

También se confirmó una discrepancia preexistente: la cadena oficial
usada por 434 exige hoyos oficiales SCORE/PICKUP completos, por lo que
el caso conceptual SIN SCORE intermedio todavía no está implementado por
el motor vigente. La 442 no intenta corregir esa discrepancia desde un
reporte.

### Qué hace

-   Crea
    `obtener_reporte_detallado_scores_stableford_team_442(uuid,uuid,text)`.
-   Parámetros: ronda, categoría y criterio `GROSS` / `NETO`.
-   Devuelve una sola estructura JSON agrupada por equipo y jugador.
-   Incluye HCP índice congelado, Playing HCP, tee, folio, outcome,
    estado de disponibilidad oficial, totales y 18 hoyos.
-   Por hoyo incluye PAR, Stroke Index, SCORE/PICKUP, golpes Gross,
    golpes de ventaja, score Neto, puntos Gross, puntos Neto, criterio
    seleccionado y aplicación de override HIO.
-   Expone la elegibilidad del hoyo frente al outcome para trazabilidad,
    sin recalcular la aportación TEAM.
-   `DNS`, `DQ` y `NO_CARD` quedan no elegibles para aportación;
    `WD`/`DNF` respetan el último hoyo válido cuando existe. Esta marca
    es informativa en el reporte y no sustituye el motor TEAM.
-   Usa snapshots congelados de hándicap, ronda, hoyos, motor y reglas
    especiales.
-   Reutiliza `calcular_golpes_handicap_hoyo` y
    `calcular_puntos_stableford_estandar`.
-   La implementación es set-based y no llama una vez por jugador a
    `obtener_resultado_stableford_tarjeta_434`.
-   `authenticated` recibe EXECUTE; `PUBLIC` queda revocado.
-   La función es `STABLE SECURITY DEFINER` con
    `search_path=public,pg_temp`.

### Protección del motor existente

442 es aditiva. No redefine 434, 438, 439, cierre de categoría, cierre
de ronda, publicación oficial, clasificación acumulada ni desempates. No
crea tarjeta TEAM y no recalcula BEST 1 por hoyo.

### Verificación obligatoria antes de frontend

El SQL independiente incluye una comparación contra
`obtener_resultado_stableford_tarjeta_434` para las 12 tarjetas actuales
de `STABLEFORD-PRUEBA QR`.

Criterio de aceptación deportivo:

-   cero diferencias de Playing HCP y totales;
-   cero diferencias hoyo por hoyo en SCORE/PICKUP, gross score, golpes
    de handicap, puntos Gross y puntos Neto;
-   12 tarjetas distintas;
-   18 hoyos por tarjeta;
-   216 comparaciones de hoyo sin diferencias.

La prueba funcional requiere contexto autenticado. Después de demostrar
equivalencia se podrá conectar Lovable al nuevo RPC. Para una ronda real
de 150-200 jugadores se recomienda además medir
`EXPLAIN (ANALYZE, BUFFERS)` y el tamaño del JSON antes de considerar
cerrado el requisito de escala.

### Alcance deliberadamente excluido

442 no corrige SIN SCORE intermedio, no cambia outcomes, no modifica
captura o conciliación, no crea ranking individual, no selecciona
aportantes TEAM y no modifica ninguna regla deportiva.

### Estado

**Preparada para ejecución manual.** Primero ejecutar la migración 442;
después ejecutar la verificación y exigir cero diferencias contra 434
antes de pedir la integración frontend.

---

## Migración 443 --- ALINEAR DESEMPATES DEL ASISTENTE

**Archivo:** `443-MIGRACION_ALINEAR_DESEMPATES_ASISTENTE.sql`  
**Verificación:** `443-VERIFICACION_ALINEAR_DESEMPATES_ASISTENTE.sql`

### Objetivo
Corregir la inconsistencia por la cual el Asistente exigía reglas GROSS y NETO aunque las clasificaciones reales del torneo requirieran solamente uno de esos tipos.

### Diagnóstico confirmado
`obtener_workflow_evaluado_395` usa `obtener_estado_configuracion_desempates_406` para `TIEBREAK_CONFIGURATION_COMPLETE`. La 406 exigía `gross > 0 AND neto > 0`. En `2SOME - STABLEFORD PRUEBA` sólo se requiere NETO: existen cuatro reglas NETO R&A 9/6/3/último hoyo; 261 devuelve COMPLETE y la antigua 406 devolvía incompleto.

Se verificó además que 406 es consumida actualmente por el workflow 395.

### Qué hace
443 redefine únicamente 406. Conserva sus contadores descriptivos GROSS/NETO, pero delega `complete` al validador canónico 261. De esta forma los tipos requeridos provienen de las clasificaciones reales y se conserva la validación existente de secuencia R&A, faltantes, reglas inválidas y conflictos.

No modifica 395, reglas almacenadas, motores deportivos, frontend, plantilla del workflow, resultados ni datos del torneo.

### Comportamiento esperado
- NETO solamente: exige NETO.
- GROSS solamente: exige GROSS.
- GROSS + NETO: exige ambos.
- Configuración faltante, inválida o conflictiva: continúa incompleta.

### Verificación
La verificación comprueba estructura/delegación, el caso real NETO-only, consistencia global 261/406 y el posterior avance del workflow. El criterio principal de consistencia global es **cero filas**.

### Estado
**Preparada para ejecución manual y posterior verificación.**

---

## Migración 444 --- IDENTIFICACIONES Y AUDITORÍAS DE ACCESO

**Archivo:** `444-MIGRACION_IDENTIFICACIONES_Y_AUDITORIAS_ACCESO.sql`  
**Verificación:** `444-VERIFICACION_IDENTIFICACIONES_Y_AUDITORIAS_ACCESO.sql`

### Objetivo
Proteger la fotografía de identificación oficial obligatoria por ingreso al campo, auditar sus consultas y aplicar conservación diferenciada.

### Qué hace
Agrega una fotografía privada de identificación por evento de ingreso, registra si llega en vehículo y mantiene placa manual en mayúsculas. Separa las identificaciones del bucket de vehículos, agrega autorizaciones de carga, auditoría de consultas y consulta de auditorías por torneo para Organizador/Superadmin. Las fotografías se purgan a los 15 días del estado terminal del torneo y las auditorías un mes calendario después de la purga física efectiva.

### Cómo lo hace
Crea bucket privado sin política de lectura cliente, funciones para autorizar/confirmar cargas de la puerta, RPC reservada al servicio para autorizar y auditar consultas, y control de la purga 368 que impide borrar registros mientras haya imágenes físicas en ambos buckets. Las auditorías conservan identificadores propios para sobrevivir a la eliminación de entradas. Añade cron independiente para limpiar auditorías vencidas.

### Estado y despliegue obligatorio
**Preparada para ejecución manual. NO habilitar la captura de identificaciones hasta completar los servicios.** Después de ejecutar SQL y verificación, deben desplegarse y probarse: (1) una Edge Function autenticada que valide el JWT, llame `autorizar_consulta_identificacion_444` con service_role y cree URL firmada de vida corta; (2) actualización de `purge-access-storage-368` para llamar `obtener_identificaciones_purga_444` y eliminar del bucket `acceso-campo-identificaciones` antes de `confirmar_purga_acceso_368`; (3) UI de captura obligatoria y pestañas AUDITORÍAS. No incluir rutas de identificación en reportes, PDF o Excel. El SQL por sí solo **no implementa** la Edge Function ni el frontend.

### Advertencias operativas
La fotografía se confirma después de crear el evento de ingreso: el frontend debe conservar `entryId` y reintentar la carga sin registrar un segundo ingreso. La obligatoriedad debe exigirse en el flujo UI y en la finalización del registro; los eventos históricos no reciben fotos retroactivamente. Se debe informar el tratamiento de datos personales antes de capturar. No sustituir la foto de identificación por `vehiculo_foto_path`. Revisar en pruebas los permisos de Storage y la purga de objetos huérfanos.

---

## Migración 445 --- RECUPERACIÓN DE INGRESOS INCOMPLETOS (versión definitiva propuesta)

**Archivo:** `445-MIGRACION_RECUPERACION_INGRESOS_INCOMPLETOS.sql`  
**Verificación:** `445-VERIFICACION_RECUPERACION_INGRESOS_INCOMPLETOS.sql`

### Objetivo
Permitir recuperar registros incompletos en la misma puerta durante 30 minutos, no bloquear ingresos legítimos en otra puerta, y convertir automáticamente en FALLIDO cualquier registro sin identificación al vencer el plazo.

### Qué hace
Añade el estado persistente `estado_identificacion_445` (`PENDIENTE`, `COMPLETADO`, `FALLIDO`). Crea la función pública `registrar_o_recuperar_ingreso_acceso_445` para uso sin sesión mediante QR de puerta y QR del jugador; recupera solo pendientes de la misma puerta y día que no hayan vencido. En otra puerta advierte sin exponer detalles y permite un registro nuevo tras confirmación. El guardia nunca consulta fotos anteriores. Un trigger impide confirmar fotos de ingresos vencidos o fallidos. Un cron cada minuto llama `marcar_ingresos_fallidos_445` para cerrar pendientes de 30 minutos y registrar exactamente una auditoría `ACCESS_ENTRY_FAILED` por entrada, con motivo `IDENTITY_NOT_CONFIRMED_30_MIN`.

### Cómo lo hace
Utiliza validaciones existentes de puerta, torneo y jugador, un advisory lock por inscripción, y la RPC 362 para creación. Una vista de lectura sin rutas de fotografía distingue estados operativos, incluido el vencimiento por reloj mientras espera el cron. La función de cierre toma filas `FOR UPDATE SKIP LOCKED` y una restricción única parcial evita duplicados de auditoría. Los eventos fallidos se conservan conforme a las reglas de purga de la migración 444.

### Integración pendiente
Lovable debe sustituir la RPC 362 por la 445 en el guardia, manejar `RECOVER`, `CREATED` y `CONFIRM_NEW_ENTRY`, preservar advertencias de QR reutilizado y exigir foto nueva en todo ingreso nuevo. Revisar todos los contadores/reportes que lean `tournament_access_entries` directamente: **solo COMPLETADO cuenta como ingreso válido**; los fallidos se muestran aparte. Adaptar el catálogo visual de AUDITORÍAS para `ACCESS_ENTRY_FAILED`/`ERROR` (mostrar como «Ingreso fallido»). La migración no reescribe automáticamente todos los reportes existentes.

### Límites y validación
El cron puede tardar hasta aproximadamente un minuto adicional en materializar el estado FALLIDO; la vista y el trigger respetan el límite de 30 minutos inmediatamente. El flujo antiguo que llama directamente 362 todavía existe: es obligatorio migrar el frontend y verificar que no queden otros consumidores. Se requiere prueba funcional con QR de puerta y jugador en torneo de prueba; no se han ejecutado pruebas destructivas en producción. La ejecución del SQL es exclusivamente manual por el usuario.

### Estado
**Propuesta lista para revisión y ejecución manual, pendiente de verificación en Supabase y adaptación de Lovable.**

---

## Migración 446 --- VALIDACIÓN DE IDENTIFICACIÓN DENTRO DE 30 MINUTOS

**Archivo:** `446-MIGRACION_VALIDACION_IDENTIFICACION_30_MINUTOS.sql`  
**Verificación:** `446-VERIFICACION_VALIDACION_IDENTIFICACION_30_MINUTOS.sql`

### Objetivo
Reforzar las RPC de carga de identificación para rechazar desde la preparación y la confirmación cualquier ingreso vencido, fallido o ya completado.

### Qué hace y cómo lo hace
Redefine exclusivamente `preparar_identificacion_acceso_444` y `confirmar_identificacion_acceso_444` conservando firmas y formatos de respuesta de éxito. Verifica que la puerta esté operativamente abierta, la ventana de acceso del torneo esté habilitada y el registro pertenezca a la puerta; bloquea la fila de ingreso con `FOR UPDATE` y exige `estado_identificacion_445='PENDIENTE'`, fotografía ausente y antigüedad estrictamente inferior a 30 minutos. Las autorizaciones de carga vencen a más tardar al límite de los 30 minutos. En confirmación, la fotografía se valida contra Storage, se actualiza el registro y el trigger 445 asigna `COMPLETADO`.

### Conservación y compatibilidad
No modifica cron, trigger, tablas, políticas RLS, buckets, reportes, auditorías ni motores deportivos. No reabre ingresos `FALLIDO` ni recupera entradas vencidas. No elimina fotografías cargadas pero no confirmadas: siguen sujetas a la purga existente. Las respuestas de error deben presentarse al guardia indicando que debe iniciar un nuevo registro.

### Verificación y estado
Ejecutar manualmente en Supabase y luego ejecutar el SQL de verificación (solo lectura). La comprobación estructural no sustituye una prueba funcional real con una puerta de prueba. Lovable debe adaptar la interfaz a la RPC 445 y mostrar los errores de 446.

---

## Actualización 447 — Estados y reportes de acceso

### Alcance
Se amplían aditivamente los contratos JSON de `obtener_reporte_acceso_torneo_366` y `validar_qr_jugador_acceso_361`. Se crea `obtener_auditorias_acceso_447` para no alterar el tipo TABLE de `obtener_auditorias_acceso_444`. La 444 continúa operativa y sin cambios.

### Reglas de conteo
- **COMPLETADO**: único estado que cuenta como entrada efectiva. `totalEntries`, `uniquePlayers`, `sameDayReuses`, `accompaniedEntries`, `vehiclePhotos` y `platesCaptured` del reporte se refieren a entradas completadas.
- **PENDIENTE**: ingreso sin fotografía dentro de los 30 minutos.
- **FALLIDO**: estado FALLIDO, o PENDIENTE cuyo plazo ya transcurrió aunque el cron todavía no haya actualizado la fila. No es ingreso efectivo.
- **Historial QR**: `priorEntries`, `priorEntriesToday`, `hasPriorEntries`, `hasPriorEntryToday` y sus advertencias se conservan como *intentos* por seguridad. Se añaden `completedEntries`, `completedEntriesToday`, `pendingAttemptsToday` y `failedAttemptsToday`.
- **Reporte**: se añaden `totalAttempts`, `completedEntries`, `pendingEntries`, `failedEntries` en summary, y `entryStatus`, `isEffectiveEntry` por fila.
- **Auditoría**: nueva RPC 447 con campos adicionales `access_point_name`, `access_point_id`, `reason`; conserva autenticación y autorización por torneo. No se devuelven fotografías, placas ni contenido JSON crudo. Para auditorías sin puerta asociable los campos quedan NULL.

### Operación y compatibilidad
El usuario ejecuta la migración manualmente; ChatGPT solo verifica con SQL de lectura. Lovable debe actualizar la pantalla de AUDITORÍAS para llamar a la RPC 447 y utilizar los nuevos campos; adaptar la lista de ingresos y las advertencias de QR a los contadores diferenciados. No hay cambios a motores deportivos, RLS, Storage, cron ni funciones de captura 445/446.

### Validación pendiente
Pruebas de integración con una puerta real, con eventos de ingreso completado, pendiente, fallido y reingreso; validar diferencias entre conteos y auditoría.


---

## Migración 448 — Inscripción individual directamente en equipo con pago el día del evento

**Archivo:** `448-MIGRACION_INSCRIPCION_EQUIPO_PAGO_DIA_EVENTO.sql`  
**Verificación:** `448-VERIFICACION_INSCRIPCION_EQUIPO_PAGO_DIA_EVENTO.sql`

### Objetivo
Permitir que un jugador se inscriba en un torneo por equipos, quede asociado al equipo elegido y mantenga independiente la situación económica de su inscripción, inicialmente PENDIENTE, para liquidarla el día del evento.

### Qué hace
Crea la RPC `inscribir_pago_dia_evento_en_equipo_448(p_tournament_id uuid, p_team_id uuid)` para jugadores autenticados. Valida torneo activo, inscripciones abiertas, opción de pago en el evento, formato por equipos, equipo activo y perteneciente al torneo, categoría del equipo, inexistencia de inscripción duplicada y ausencia de una plaza provisional del mismo jugador. Calcula la tarifa individual con el criterio de la RPC 339. Inserta una única inscripción activa con equipo y categoría vinculados, `estado_pago='PENDIENTE'`, importe por pagar y sin pago registrado. Los triggers existentes siguen validando cupos, perfil, categoría, marca y congelamiento. Una falla revierte la operación completa.

### Alcance y límites
No altera las funciones de cobro ni el motor deportivo, no registra pagos y no autoriza excepciones al congelamiento. No permite esta alta después de congelar condiciones. No reutiliza plazas provisionales existentes: las rechaza para evitar duplicidad de ocupación. No modifica la RPC 339 de inscripción sin equipo. El flujo de pago posterior se conserva separado de la inscripción.

### Integración con Lovable
En la pantalla de inscripción, cuando el jugador seleccione equipo y pago el día del evento, invocar `inscribir_pago_dia_evento_en_equipo_448` con los UUID del torneo y equipo. Para la inscripción sin equipo continuar usando `inscribir_pago_dia_evento_339`. Mostrar la inscripción creada y el saldo PENDIENTE, sin iniciar cobro ni llamar después a una asignación adicional. Mostrar los errores reales de la RPC. No ejecutar SQL desde Lovable.

### Estado y verificación
**Propuesta preparada; pendiente de ejecución manual por el usuario y verificación posterior de solo lectura en Supabase.** Se requiere además prueba funcional con jugador de prueba, equipo con cupo, sin duplicados, y comprobación del registro económico. La verificación SQL no sustituye esa prueba.


---

## MIGRACIÓN 449 — PREPARADA — INSCRIPCIÓN DE EQUIPO COMPLETO CON PAGO EL DÍA DEL EVENTO

**Archivo:** `449-MIGRACION_EQUIPO_COMPLETO_PAGO_DIA_EVENTO.sql`  
**Verificación:** `449-VERIFICACION_EQUIPO_COMPLETO_PAGO_DIA_EVENTO.sql`  
**Estado:** PREPARADA; pendiente de ejecución manual del usuario en Supabase y verificación posterior. Sin pruebas funcionales realizadas.

### Objetivo
Agregar al flujo existente de inscripción de un equipo completo la opción **PAGAR EL DÍA DEL EVENTO**, con la tarifa especial `tarifa_equipo_completo` distribuida entre las plazas. Cada integrante asume únicamente su parte, no el iniciador del equipo. La selección se efectúa con el equipo completo, pero los invitados conservan el proceso vigente de confirmación posterior.

### Qué hace
Incorpora `tournament_team_deferred_payments_449` y `tournament_team_deferred_slots_449` para registrar, en una sola transacción, el compromiso económico del equipo y los importes individuales por plaza. El reparto se realiza en centavos y asigna los centavos residuales por orden estable de las plazas. La RPC `registrar_equipo_completo_pago_dia_evento_449(p_team_id)` valida sesión, autorización, torneo activo, inscripciones abiertas, modalidad por equipos, opción de pago diferido habilitada, ausencia de congelamiento, plantilla completa y ausencia de cobros, intentos pendientes o inscripciones incompatibles. Las plazas confirmadas se convierten a inscripciones con `estado_pago='PENDIENTE'`, `total_a_pagar` individual y ningún pago registrado; las invitaciones pendientes conservan su estado y se convierten al confirmarse.

### Compatibilidad y protecciones
El pago inmediato no cambia para equipos que no eligieron el nuevo esquema. Los triggers 449 impiden nuevos intentos de pago grupal inmediato para equipos comprometidos con pago diferido y evitan incorporar o eliminar plazas después de fijar el reparto. La confirmación existente `confirmar_invitacion_equipo` conserva sus ramas de inscripción ya pagada y cobertura grupal pagada, e informa correctamente la inscripción pendiente creada para el nuevo caso. No se simulan coberturas pagadas. Se conservan los triggers deportivos, de perfil, cupos y congelamiento de las inscripciones.

### Limitaciones operativas
La migración no agrega una política de sustitución/reconfiguración del equipo después de fijar el compromiso; las plazas no pueden agregarse ni eliminarse mediante las operaciones normales de roster. El rechazo de una invitación sigue disponible, pero no reasigna automáticamente su importe ni crea una deuda para quien rechazó. Una eventual reasignación requiere diseño y autorización separados. No se habilitan pagos parciales. No se modifican los procedimientos de cobro individual vigentes.

### Integración pendiente de Lovable
Agregar únicamente en el registro de equipo completo la alternativa **PAGAR EL DÍA DEL EVENTO** cuando el torneo lo permita. Mostrar la tarifa especial completa y las cuotas individuales, sin pedir medio de pago ni iniciar la pasarela. Al confirmar, llamar a `registrar_equipo_completo_pago_dia_evento_449(p_team_id)` y refrescar el equipo, las invitaciones y las inscripciones. Mantener intactos el pago inmediato, la generación de invitaciones y la aceptación de los invitados. No ejecutar SQL desde Lovable.

### Verificación y estado
El archivo de verificación contiene únicamente SELECT sobre existencia de objetos, permisos, triggers, reparto exacto, integridad de inscripciones y ausencia de cobros grupales incompatibles. Su ejecución y las pruebas funcionales en torneo de prueba están pendientes; no se afirma que la migración esté instalada ni validada en producción.


---

## MIGRACIÓN 450 — PREPARADA — RESERVAS DE CARRITOS POR TORNEO

**Archivo:** `450-MIGRACION_RESERVAS_CARRITOS.sql`  
**Verificación:** `450-VERIFICACION_RESERVAS_CARRITOS.sql`  
**Estado al 13 de octubre de 2026:** SQL preparado; **NO ejecutado** por el usuario; **NO verificado** en Supabase; pruebas funcionales pendientes.

### Objetivo
Incorporar un módulo independiente de reserva, renta, cobro manual, entrega y devolución de carritos de golf, sin afectar inscripciones deportivas, resultados ni pasarela de cobros.

### Identidad y permisos
El operador se identifica mediante el correo electrónico único de la plataforma y su cuenta existente de Supabase Auth. No se crea una segunda identidad ni se almacenan contraseñas en tablas de carritos. SUPERADMIN administra todos los torneos; ORGANIZADOR administra los torneos de su ámbito; el operador solo opera los torneos expresamente asignados. Las asignaciones se revocan por torneo. El alta inicial de un correo inexistente se realiza por el flujo vigente de autenticación y no por SQL.

### Estructura
Se crean ocho tablas `cart_*_450`: configuración por torneo; inventario de 2 y 4 plazas por ronda con precio; operadores asignados; folios de reserva; reservas por ronda; cobros manuales; distribución de cobros por ronda; auditoría. Se activa RLS y se revoca acceso directo a roles públicos; se exponen únicamente RPC autenticadas con comprobación de permisos.

### Reglas económicas y operativas
La tarifa se define por carrito y ronda. El total de una reserva multirronda es la suma de los precios de sus rondas. Si la configuración indica todas las rondas, un solo folio ocupa inventario en cada ronda; de lo contrario se elige una ronda. Máximo un carrito activo por jugador y ronda. Las reservas se serializan por torneo para evitar sobreventa. Se admite cobro parcial con distribución explícita a una o varias rondas y registro de fecha, medio, cobrador y usuario registrador. El módulo no cobra mediante pasarela. Se registran entrega y devolución por ronda, y cancelación manual individual por ronda con historial preservado. El CUT no provoca cancelaciones automáticas.

### RPC principales
`cart_can_450`, `cart_dashboard_450`, `cart_configure_450`, `cart_assign_operator_450`, `cart_book_450`, `cart_cancel_round_450`, `cart_delivery_450` y `cart_record_payment_450`.

### Integración pendiente en Lovable
Crear las pantallas RESERVAS CARRITOS para SUPERADMIN, organizadores y operadores, y la acción RESERVAR CARRITO en MIS TORNEOS para jugadores. Utilizar la autenticación vigente; nunca enviar SQL desde Lovable. Para dar de alta operadores que no tienen cuenta, usar el flujo de invitación/registro existente. Mostrar «NO HAY DISPONIBILIDAD — AGOTADOS» y «CARRITO RESERVADO — FOLIO [número]». Incorporar reportes, saldos por ronda, entrega/devolución y gestión de reservas posteriores al CUT.

### Límites, verificación y pendientes
La verificación adjunta es de solo lectura y revisa objetos, RLS, permisos, integridad, sobreventa y pagos. Después de la ejecución manual del usuario, ChatGPT deberá ejecutarla y analizar resultados; además hacen falta pruebas de permisos con identidades reales, concurrencia, reserva multirronda y pagos parciales. No se declara instalada ni funcionalmente validada. La configuración del operador no cambia contraseñas de Supabase Auth. El control de finalización automática de permisos y la integración del CUT con una lista de candidatos a cancelación quedan para Lovable/implementación posterior y deben probarse.


---

## VERIFICACIÓN POSTERIOR A LA EJECUCIÓN DE MIGRACIÓN 450 — 13 OCTUBRE 2026

El usuario confirmó la ejecución manual de la migración 450 en GOLFING_FULL. Consultas de solo lectura confirmaron ocho tablas con RLS habilitado, ocho funciones RPC, ausencia de permisos directos de anon/authenticated sobre las tablas y denegación de ejecución anónima de las RPC. Al momento de verificar había cero operadores y cero reservas, sin incidencias detectadas de inventario, duplicados o pagos. Esta es una **verificación estructural**, no una validación funcional con usuarios. El texto histórico de 450 que indica «NO ejecutada» se conserva sin alteraciones porque documenta el estado de preparación en su fecha.

## MIGRACIÓN 450A — PREPARADA, NO EJECUTADA — CORRECCIÓN DE SEGURIDAD Y DISPONIBILIDAD DE CARRITOS

**Archivo:** `450A-MIGRACION_CORRECCION_SEGURIDAD_RESERVAS_CARRITOS.sql`  
**Verificación:** `450A-VERIFICACION_CORRECCION_SEGURIDAD_RESERVAS_CARRITOS.sql`  
**Estado:** PREPARADA; pendiente de ejecución manual por el usuario y verificación posterior.

### Diagnóstico
La inspección de solo lectura identificó que el rol real de organizador es `tournament_organizer` con ámbito `tournament`, no los códigos `ORGANIZADOR` o `ORGANIZER` previstos en 450. El rol real de SUPERADMIN es `superadmin` con ámbito `global`. La corrección mantiene autorizaciones independientes por torneo y no cambia otras áreas de la aplicación.

### Qué hace
Reemplaza la comprobación de permisos `cart_can_450` usando códigos y ámbitos reales; limita a los organizadores a asignaciones directas al torneo, conserva el acceso global del SUPERADMIN y restringe a operadores a sus torneos activos, impidiendo el acceso operativo tras finalizar o cancelar el torneo. Impide configurar, reservar, cancelar, entregar o registrar pagos en torneos terminales. Permite revocar operadores incluso después de la finalización, pero no asignarlos. Agrega `cart_availability_450(uuid)` para consultar tarifas, rondas y disponibilidad desde el perfil del jugador inscrito sin revelar otros jugadores, reservas o cobros. No crea cuentas ni contraseñas y no altera datos previos.

### Límites y verificación
La verificación 450A es exclusivamente de lectura. Quedan pendientes pruebas funcionales con SUPERADMIN, ORGANIZADOR, OPERADOR, JUGADOR y usuarios de otros torneos, además de pruebas de concurrencia y validación del flujo Lovable. La restricción de permisos del operador se aplica a las RPC de este módulo; la protección frente a otros módulos depende de sus controles de acceso preexistentes. No se afirma que 450A haya sido ejecutada.


---

## INCIDENCIA Y REVISIÓN DE LA MIGRACIÓN 450A — 13 OCTUBRE 2026

El primer intento manual de ejecución de 450A falló con SQLSTATE 42601: «unexpected end of function definition» en la línea 156. Una consulta de solo lectura posterior confirmó que `cart_availability_450(uuid)` no existía y que `cart_can_450` todavía no contenía `tournament_organizer`. No se confirmó aplicación de los cambios de 450A.

Se corrigió **el mismo archivo 450A**, sin crear una nueva migración: siete terminaciones PL/pgSQL `END $$;` se reemplazaron por `END;` seguido de `$$;`. Se mantiene el nombre `450A-MIGRACION_CORRECCION_SEGURIDAD_RESERVAS_CARRITOS.sql` y su verificación `450A-VERIFICACION_CORRECCION_SEGURIDAD_RESERVAS_CARRITOS.sql`. El identificador 450B fue propuesto por error y **no corresponde a una migración ejecutada ni a un nuevo paso**. No ejecutar ningún archivo 450B.

**Estado de la versión corregida 450A:** PREPARADA, PENDIENTE DE EJECUCIÓN MANUAL Y VERIFICACIÓN POSTERIOR. Revisión de sintaxis estática realizada; no se declara ejecución exitosa ni validación funcional. El historial previo se conserva íntegro.


---

## SEGUNDO INTENTO FALLIDO DE 450A Y CORRECCIÓN DE SINTAXIS — 13 OCTUBRE 2026

El usuario informó un segundo fallo de ejecución manual de la migración 450A con SQLSTATE 42601: «unexpected end of function definition at end of input», cerca de la línea 164. Se detectó un paréntesis de cierre faltante en el `SELECT jsonb_build_object(...)` de la función `cart_availability_450`. La instrucción que terminaba en `...'[]'::jsonb)) INTO v_result` fue corregida a `...'[]'::jsonb))) INTO v_result`. Se revisó el balance de paréntesis de los ocho cuerpos de funciones y la terminación de los siete bloques PL/pgSQL.

Una consulta de solo lectura confirmó que `cart_availability_450(uuid)` aún no existe y que `cart_can_450` todavía no contiene `tournament_organizer`. Por ello, la 450A no se considera aplicada. Se mantiene el identificador **450A**; **450B no debe ejecutarse**.

**Estado:** SQL 450A corregido y preparado; ejecución manual y verificación funcional pendientes. La revisión es estática, no equivale a una prueba de compilación/ejecución en PostgreSQL.


---

## MIGRACIÓN 451 — PREPARADA, NO EJECUTADA — PROTECCIÓN DE CONFIGURACIÓN DE CARRITOS — 13 OCTUBRE 2026

**Archivo:** `451-MIGRACION_PROTECCION_CONFIGURACION_CARRITOS.sql`  
**Verificación:** `451-VERIFICACION_PROTECCION_CONFIGURACION_CARRITOS.sql`  
**Estado:** PREPARADA; pendiente de ejecución manual y verificación de solo lectura.

### Objetivo y funcionamiento
Refuerza `cart_configure_450` sin crear tablas nuevas. Desde la primera reserva histórica del torneo, congela la modalidad UNA RONDA/TODAS LAS RONDAS y los precios ya configurados por ronda y capacidad, incluso si las reservas fueron canceladas. El inventario puede aumentar o disminuir, pero nunca por debajo de las reservas activas. Evita introducir nuevas tarifas tras la primera reserva, valida filas duplicadas y mantiene la transacción atómica.

### Suspensión y correo pendientes
Para no suspender silenciosamente un servicio sin cumplir la notificación acordada, esta versión impide deshabilitar el servicio cuando existen reservas activas; el envío de correo y la confirmación explícita del operador se implementarán en una fase posterior, mediante el mecanismo existente de correo. La suspensión con reservas activas **NO** se considera implementada. Si no hay reservas activas, puede deshabilitarse. Esta restricción provisional deberá sustituirse cuando se habiliten notificaciones verificables. No se envían correos desde esta migración.

### Verificación y límites
El archivo de verificación es de solo lectura; verifica firma y contenido de la RPC, estado de reservas e inexistencia de sobreventa. Quedan pendientes pruebas funcionales con identidades reales y confirmación de entrega de correos en su fase. Lovable debe mostrar mensajes de bloqueo y no afirmar que las notificaciones fueron enviadas.


---

## MIGRACIÓN 452 — PREPARADA, NO EJECUTADA — ALTA Y VINCULACIÓN DE OPERADORES DE CARRITOS — 13 OCTUBRE 2026

**SQL:** `452-MIGRACION_ALTA_VINCULACION_OPERADORES_CARRITOS.sql`  
**Verificación:** `452-VERIFICACION_ALTA_VINCULACION_OPERADORES_CARRITOS.sql`  
**Estado:** PREPARADA; pendiente de ejecución manual del usuario y de verificación estructural y funcional.

### Objetivo
Permitir que un organizador autorizado, dentro de su torneo, vincule un operador existente por correo o registre una solicitud de alta para una persona nueva, sin intervención del SUPERADMIN, sin selector de torneos ni catálogo global de operadores. Un operador conserva una identidad única en Supabase Auth y puede estar vinculado a torneos de organizadores diferentes.

### Qué hace
Agrega `cart_operator_pending_452` con RLS y sin permisos directos para clientes. Introduce cinco RPC SECURITY DEFINER: `cart_link_or_register_operator_452` (vinculación inmediata si el correo existe en Auth; solicitud pendiente si es nuevo y se proporcionan nombres y apellidos), `cart_activate_operator_452` (la propia persona autenticada y con correo confirmado activa sus solicitudes pendientes), `cart_operators_for_tournament_452` (lista limitada al torneo abierto), `cart_my_tournaments_452` (torneos vigentes vinculados al usuario) y `cart_cancel_pending_operator_452` (anulación de solicitud pendiente). Reutiliza `cart_operators_450`, `cart_assign_operator_450`, `cart_can_450` y la auditoría existente. La desactivación de un vínculo activo sigue utilizando `cart_assign_operator_450(...,false)`. No concede rol `tournament_organizer`, ni acceso a otros módulos.

### Integración posterior de Lovable
La activación de cuenta nueva necesita un flujo React de OTP mediante Supabase Auth (`signInWithOtp`/`verifyOtp`), creación personal de contraseña (`updateUser`) y llamada a `cart_activate_operator_452`. La migración **no envía correos por sí sola**, no crea identidades Auth ni contraseñas y no garantiza que el usuario haya completado el registro. El frontend deberá presentar estados Vinculado / Pendiente / Desactivado, y mostrar solo los torneos devueltos por `cart_my_tournaments_452` y únicamente las funciones de carritos, con protección de rutas. El alta de operadores no debe llamar `completar_autoregistro_organizador_296`, porque ese flujo crea una identidad de organizador, no un operador. Los correos de autenticación se envían únicamente cuando el propio operador utiliza el flujo OTP; no se presupone correo automático al crear la solicitud pendiente.

### Seguridad y pruebas pendientes
El organizador solo puede operar desde un torneo autorizado; los pendientes se reclaman únicamente por la identidad Auth cuyo correo verificado coincide. El permiso operativo de carritos continúa sujeto a `cart_can_450` y excluye torneos cancelados o finalizados. Deben verificarse con cuentas reales: alta nueva, vinculación existente, varias asignaciones independientes, baja, alta cancelada, seguridad por torneo, flujo OTP/contraseña y acceso directo a rutas administrativas. El SQL de verificación es de solo lectura. No se declara migración ejecutada, publicada ni probada funcionalmente.


---

## CORRECCIÓN 452A — PREPARADA, NO EJECUTADA — CALIFICACIÓN DEL TIPO CITEXT EN RPC DE OPERADORES — 14 OCTUBRE 2026

**Migración:** `452A-MIGRACION_CORRECCION_CITEXT_OPERADORES.sql`  
**Verificación:** `452A-VERIFICACION_CORRECCION_CITEXT_OPERADORES.sql`  
**Estado:** PREPARADA; pendiente de ejecución manual y verificación. La migración 452 se encontraba instalada y fue comprobada estructuralmente; en prueba de alta de operador en torneo XYZ se produjo `type "citext" does not exist`.

### Diagnóstico verificado en Supabase (solo lectura)
La extensión `citext` está instalada en el esquema `public`. Las funciones de la migración 452 utilizan `SET search_path TO ''`, pero tres de ellas realizan conversiones sin esquema `::citext`, provocando el error en ejecución.

### Objetivo y alcance
Corregir exclusivamente las referencias de tipo a `::public.citext` en las tres RPC `cart_link_or_register_operator_452`, `cart_activate_operator_452` y `cart_cancel_pending_operator_452`, preservando sus firmas, lógica y permisos existentes. No se crean ni eliminan cuentas Auth, no se modifican datos, tablas, políticas RLS, flujos de contraseñas ni otras funciones. No corresponde a un cambio exclusivo de Lovable.

### Verificación y pendientes
El SQL de verificación es de solo lectura y revisa la existencia del tipo, la calificación explícita en el código de las tres funciones, `SECURITY DEFINER`, propietario y permisos de ejecución, además del número de solicitudes pendientes. Después de ejecutar manualmente 452A debe repetirse la prueba funcional de alta con un correo de prueba y comprobar si la reversión de la cuenta fallida anterior ocurrió. No afirmar que la cuenta fallida fue borrada sin verificación.


---

## CORRECCIÓN 452B — PREPARADA, NO EJECUTADA — CITEXT EN ASIGNACIÓN DE OPERADORES — 14 OCTUBRE 2026

**Migración:** `452B-MIGRACION_CORRECCION_CITEXT_ASIGNAR_OPERADOR.sql`  
**Verificación:** `452B-VERIFICACION_CORRECCION_CITEXT_ASIGNAR_OPERADOR.sql`  
**Estado:** PREPARADA; pendiente de ejecución manual y verificación. La corrección 452A fue verificada estructuralmente en Supabase, pero el alta real de un operador en el torneo XYZ continuó fallando con `type "citext" does not exist`.

### Diagnóstico y objetivo
Consulta de solo lectura confirmó que `public.cart_assign_operator_450` todavía contiene `lower(trim(p_email))::citext` con `SET search_path TO ''`. La función 452 `cart_link_or_register_operator_452` llama a esta RPC durante la vinculación. Las tres RPC corregidas por 452A ya utilizan `::public.citext`; la revisión de todas las funciones `cart_*` encontró esta única referencia restante sin calificar.

### Qué hace
Reemplaza únicamente la definición de `public.cart_assign_operator_450`, cambiando `::citext` a `::public.citext`. Conserva la firma, los controles de autorización, la lógica de vinculación y desactivación, `SECURITY DEFINER`, `search_path` y el registro de auditoría. No crea ni elimina cuentas, no modifica datos, tablas, permisos ni el frontend. Es una corrección SQL que ejecuta manualmente el usuario, no Lovable.

### Verificación y pendientes
El SQL de verificación es exclusivamente de lectura; comprueba el tipo `public.citext`, la firma, seguridad y permisos de la RPC, y revisa todas las funciones `cart_*` para detectar referencias `::citext` sin esquema. Debe verificarse su ejecución antes de repetir el alta funcional de un operador de prueba. La comprobación estructural no equivale a haber probado el alta ni el rollback de cuentas en Supabase Auth.


---

## MIGRACIÓN 453 — PREPARADA, NO EJECUTADA — ENTREGA Y DEVOLUCIÓN DE CARRITOS — 14 OCTUBRE 2026

**Migración:** `453-MIGRACION_ENTREGA_DEVOLUCION_CARRITOS.sql`  
**Verificación:** `453-VERIFICACION_ENTREGA_DEVOLUCION_CARRITOS.sql`  
**Estado:** PREPARADA, NO EJECUTADA. Pendiente ejecución manual del usuario y verificación de solo lectura y pruebas funcionales.

### Objetivo
Controlar la entrega y devolución física de carritos por reserva, jugador y ronda, con pago completo **únicamente de la ronda entregada**, procedencia y trazabilidad automática, sin catálogo de flotilla ni inspecciones o fotografías obligatorias.

### Qué hace
Agrega a `cart_booking_rounds_450` tres campos: `cart_origin_453` (PROPIO/AJENO/OTRO), `cart_origin_other_453` (descripción obligatoria cuando es OTRO) y `return_notes_453` (observaciones opcionales de devolución). Reutiliza `cart_identifier` como referencia opcional, y los campos existentes `delivered_at`, `delivered_by`, `returned_at` y `returned_by` para fecha, hora y usuario autenticado. Las entregas y devoluciones se auditan en `cart_audit_450` con vínculo a reserva, jugador y ronda.

Introduce `cart_delivery_453(p_booking_round,p_return,p_cart_origin,p_cart_origin_other,p_cart_identifier,p_return_notes)`, protegida por `cart_can_450`, que impide entregar reservas canceladas, carritos ya entregados, torneos finalizados/cancelados o rondas con saldo pendiente. El pago se comprueba con las asignaciones existentes `cart_payment_allocations_450` y pagos de la misma reserva y torneo. Cada ronda es independiente. Impide devoluciones antes de entregar y segundas devoluciones; **nunca devuelve automáticamente**. La devolución manual es admisible después de finalizar la ronda o torneo, para no perder el control de un carrito aún fuera. No se permite modificar los datos originales de entrega durante la devolución.

Para cerrar la vía antigua que no comprobaba pago, revoca a `authenticated`, `anon` y `PUBLIC` el permiso de ejecución de `cart_delivery_450(uuid,boolean,text)`; conserva su definición histórica. La interfaz Lovable deberá cambiar las llamadas de entrega y devolución a la nueva RPC 453. El estado operativo se deriva de las fechas: PENDIENTE (sin entrega), ENTREGADO / PENDIENTE DE DEVOLUCIÓN (entregado sin devolución) y DEVUELTO (con devolución). No cambia el estado ACTIVE/CANCELLED de la reserva ni introduce catálogo de unidades físicas.

### Verificación, compatibilidad y pendientes
El SQL de verificación es exclusivamente de lectura: comprueba columnas, restricciones, firmas, seguridad, privilegios, movimientos y posibles anomalías de datos. **No se declara ejecutada ni verificada en Supabase.** Antes de aplicar en producción, revisar si existen entregas históricas que carezcan de procedencia o pago completo; la migración no las reescribe ni las presenta como conformes. Si Lovable todavía llama a `cart_delivery_450`, esas operaciones dejarán de funcionar hasta actualizar la integración; coordinar aplicación SQL y frontend sin publicar unilateralmente. Probar con operador real: ronda impaga, pago parcial, pago completo de una ronda con otra pendiente, entrega duplicada, devolución duplicada, devolución tras cierre, autorización por torneo y auditoría. No enviar correos nuevos ni alterar pagos de inscripciones.


---

## Migración 454 — ENCARGADOS DE SEGURIDAD (14 de octubre de 2026)

**Estado documental:** preparada para ejecución manual por el usuario; NO ejecutada ni verificada aún en Supabase.

**Objetivo:** habilitar encargados de seguridad independientes del organizador, asignados por torneo, con permisos específicos para el módulo CONTROL DE ACCESO.

**Archivos:** `454-MIGRACION_ENCARGADOS_SEGURIDAD.sql` y `454-VERIFICACION_ENCARGADOS_SEGURIDAD.sql`.

**Funcionamiento:** reutiliza el modelo de operadores de carritos: vinculación inmediata de cuenta existente en Supabase Auth; si no existe, solicitud pendiente hasta registro, confirmación de correo y activación. Una misma cuenta puede estar en múltiples torneos. No se crean empleados ni colaboradores del organizador, ni contraseñas propias en tablas públicas. Solo organizador o SUPERADMIN administra altas, permisos y revocaciones.

**Permisos independientes:** administrar puntos y credenciales, abrir/cerrar puertas, apertura general, consultar ingresos y consultar reportes. Los controles se aplican en Supabase, no únicamente en la interfaz. Las funciones operativas históricas mantienen su lógica y reciben una autorización adicional específica, mediante modificación controlada de las guardias de organizador. La migración falla y revierte completamente si una función requerida o su guardia no coincide con el esquema inspeccionado.

**Seguridad:** RLS habilitado en tablas nuevas; sin SELECT directo para authenticated; RPCs SECURITY DEFINER con comprobación de auth.uid(), torneo activo y permisos; exclusión de torneos terminales. La función de activación requiere correo confirmado. El encargado no recibe rol de organizador ni acceso a módulos ajenos.

**Verificación:** ejecutar posteriormente el SQL de verificación de solo lectura, comprobar la presencia de 15 funciones adaptadas, políticas y privilegios; realizar pruebas con cuentas reales para vinculación existente, alta pendiente, activación, revocación, separación entre torneos y cada permiso.

**Frontend:** Lovable implementará sección ENCARGADOS DE SEGURIDAD y acceso independiente después de aplicar/verificar SQL. Lovable NO ejecuta migraciones. No publicar sin autorización.

**Constancia posterior de 453:** consultas de solo lectura efectuadas el 14 de octubre de 2026 confirmaron presencia de columnas y RPC `cart_delivery_453`; esta constancia se agrega sin alterar la anotación histórica previa de 453 como pendiente.


---

## Corrección 454A — CORRECCION GUARDIAS SEGURIDAD (14 de octubre de 2026)

**Motivo:** el primer intento de ejecución de la migración 454 devolvió `P0001: Guardia no encontrada en abrir_acceso_campo_ahora_359`. La expresión regular de la migración 454 no reconocía el argumento anidado `auth.uid()` de `public.is_tournament_organizer`.

**Evidencia de reversión:** consulta de solo lectura posterior al error: `to_regclass('public.security_operators_454')` y `to_regclass('public.security_operator_pending_454')` devolvieron NULL. La migración 454 falló dentro de `BEGIN ... COMMIT` y no se observan sus tablas nuevas.

**Corrección:** 454A sustituye íntegramente la migración fallida 454 (NO debe ejecutarse 454 antes). Conserva el resto del SQL y reemplaza la búsqueda de guardias por una expresión compatible con `auth.uid()` y `v_auth_uid`; exige exactamente una coincidencia por función y revierte toda la transacción si alguna no coincide. El patrón se probó con consultas de solo lectura en Supabase para las funciones relevantes y su reemplazo se verificó en texto de prueba. No se ha ejecutado 454A.

**Archivos:** `454A-MIGRACION_CORRECCION_GUARDIAS_SEGURIDAD.sql` y `454A-VERIFICACION_CORRECCION_GUARDIAS_SEGURIDAD.sql`. El SQL 454 original y el README 454 se conservan como historial; el README 454A agrega esta nota sin reescribir contenido anterior.

**Estado:** pendiente de ejecución manual del usuario y verificación posterior de solo lectura. No se declara probada la operación funcional con usuarios reales.


---

## MIGRACIÓN 455 — PREPARADA, NO EJECUTADA — NOMBRES EN LISTADOS DE CARRITOS Y SEGURIDAD — 15 OCTUBRE 2026

**Migración:** `455-MIGRACION_NOMBRES_OPERADORES_CARRITOS_SEGURIDAD.sql`  
**Verificación:** `455-VERIFICACION_NOMBRES_OPERADORES_CARRITOS_SEGURIDAD.sql`  
**Estado:** PREPARADA; ejecución manual y verificación pendientes. No se considera aplicada.

### Objetivo
Mostrar nombres y apellidos de los operadores de reservas de carritos y encargados de seguridad ya vinculados, además del correo, sin solicitar nuevamente estos datos ni consultar el catálogo de jugadores.

### Qué hace
Actualiza exclusivamente las funciones `cart_operators_for_tournament_452(uuid)` y `security_operators_for_tournament_454(uuid)`. En el arreglo JSON `operators`, agrega `nombres` y `apellidos` obtenidos de `auth.users.raw_user_meta_data` mediante la relación `auth_user_id`. Si faltan esos metadatos, devuelve NULL para el campo y la interfaz debe conservar el correo como alternativa. Conserva todos los campos históricos de `operators` y `pending`, las firmas, las validaciones `cart_can_450` y `security_manage_454`, `SECURITY DEFINER`, `search_path`, privilegios y filtros por torneo. No modifica tablas, datos, autenticación, asignaciones, permisos ni las altas y revocaciones.

### Integración y pendientes
Después de ejecutar manualmente la migración, verificar las definiciones mediante el SQL de solo lectura y solicitar a Lovable que muestre nombre completo en ambos listados, con correo como dato secundario y alternativa cuando falte el nombre. Probar con una cuenta real de cada módulo. Lovable no ejecuta migraciones SQL.


---

## MIGRACIÓN 456 — LIVE SCORE DIGITAL — MI CATEGORÍA (16 DE OCTUBRE DE 2026)

**Archivos:** `456-MIGRACION_LIVE_SCORE_DIGITAL_MI_CATEGORIA.sql` y `456-VERIFICACION_LIVE_SCORE_DIGITAL_MI_CATEGORIA.sql`.

**Estado documental:** SQL preparado para ejecución manual. **NO EJECUTADO NI VERIFICADO EN SUPABASE.** La versión preliminar de la 456 y los borradores de corrección 456A no fueron ejecutados y quedan sustituidos por esta versión única 456. No constituyen migraciones adicionales ni dejan huecos en la numeración.

**Objetivo:** añadir LIVE SCORE provisional para jugadores autenticados de su propia categoría durante torneos en curso, utilizando exclusivamente eventos de captura de tarjeta digital QR. Independiente de tarjetas físicas, Comité, conciliación y resultados oficiales.

**Alcance técnico:** crea la función de consulta `public.obtener_live_score_mi_categoria_456(uuid)` con `SECURITY DEFINER`, verificación de `auth.uid()`, inscripción activa y categoría del jugador, torneo `en_curso`, tarjeta digital habilitada y última validación de ronda con estado `validated`. La función solo puede ejecutarse por el rol `authenticated` y no modifica datos. Consulta las últimas evidencias QR en `tournament_scorecard_events` y `tournament_best_ball_scorecard_events`; las capturas pendientes no se convierten en cero. Mantiene indicador de disputa asociado a la captura digital y calcula resultados provisionales usando snapshots de hándicap, función de distribución de ventajas y función Stableford existentes. Para Best Ball toma mínimos bruto/neto por hoyo; para Stableford por equipos, máximos puntos bruto/neto por hoyo. A-Go-Go utiliza tarjeta y hándicap de equipo.

**Publicación:** en modalidades individuales, cada hoyo aparece conforme se captura. En A-Go-Go, Best Ball y Stableford por equipos, el primer score QR del hoyo siguiente libera lo disponible del hoyo anterior, siguiendo `play_sequence` (también para Shotgun); no se espera a todos los integrantes ni se revisan DNS/WD/DNF/DQ para publicar. El último hoyo jugado se libera al cerrar digitalmente la(s) tarjeta(s) de la unidad. Los totales solo incluyen hoyos publicados. Los 18 hoyos permanecen representados y los no publicados no revelan resultados.

**Interfaz pendiente en Lovable:** agregar acceso desde MIS TORNEOS a LIVE SCORE — MI CATEGORÍA, mostrar aviso «Información provisional de tarjetas digitales. No verificada oficialmente.», ordenar jugadores por apellido y equipos por nombre, cuadrícula móvil de 18 hoyos agrupados 1–9 y 10–18, expansión de aportaciones y punto rojo junto al score en disputa. Lovable no crea ni ejecuta SQL.

**Verificación pendiente:** tras ejecución manual del usuario, ejecutar exclusivamente las consultas de lectura del archivo de verificación, comprobar permisos y probar desde la aplicación con las modalidades disponibles. Los escenarios sin capturas QR reales, particularmente Best Ball, no deben declararse probados hasta contar con evidencia.


---

## MIGRACIÓN 457 — AUTOSERVICIO DE RESERVAS DE CARRITOS PARA JUGADORES — 16 OCTUBRE 2026

**Archivos:** `457-MIGRACION_AUTOSERVICIO_RESERVAS_CARRITOS_JUGADORES.sql` y `457-VERIFICACION_AUTOSERVICIO_RESERVAS_CARRITOS_JUGADORES.sql`.

**Estado:** PREPARADA, NO EJECUTADA. No se atribuye verificación funcional.

**Objetivo:** integrar la reserva de carritos por el propio jugador autenticado desde MIS TORNEOS, utilizando el módulo administrativo ya existente de la migración 450. No se modifica la configuración, inventario, tarifas, pagos ni entrega/devolución.

**Funciones nuevas:** `cart_my_bookings_457(uuid)` devuelve únicamente reservas del jugador autenticado, folio, rondas, estado, importe, pagos aplicados y saldo por ronda; `cart_self_book_457(uuid,integer,uuid)` valida inscripción, bloquea el torneo para serializar la operación, impide duplicados activos y delega el alta a `cart_book_450`; `cart_self_cancel_round_457(uuid,text)` permite cancelar una ronda propia activa, no entregada y sin pagos aplicados, con auditoría. Las reservas con pagos deben tramitar su cancelación con un operador para evitar inconsistencias de cobro/reembolso.

**Configuración de rondas:** se respeta estrictamente `cart_settings_450.all_rounds`: si es verdadero, `cart_book_450` reserva todas las rondas activas; si es falso, el jugador selecciona una ronda. No se cambia la semántica histórica de esta configuración. Capacidades permitidas: 2 y 4 plazas. No se implementa pasarela de pagos ni cobros automáticos.

**Seguridad:** `SECURITY DEFINER`, `search_path=public,pg_temp`, comprobación de `auth.uid()`, inscripción activa y pertenencia de la reserva al jugador. Acceso `EXECUTE` solamente a `authenticated`, revocado para `PUBLIC` y `anon`. No se conceden permisos administrativos.

**Lovable:** mostrar RESERVAR CARRITO / MI RESERVA DE CARRITO dentro de MIS TORNEOS cuando corresponda, consultar `cart_availability_450` y `cart_my_bookings_457`, reservar mediante `cart_self_book_457` y cancelar sin pagos mediante `cart_self_cancel_round_457`. Mostrar folios, importes y saldos por ronda. No ejecutar migraciones SQL ni publicar sin autorización.

**Verificación:** consultas de solo lectura del archivo 457. La migración se ejecuta manualmente por el usuario. Probar con un jugador autenticado, varias rondas, falta de inventario, duplicados, cancelación con/sin pago y controles de identidad antes de declarar validación funcional.


---

## MIGRACIÓN 458 — CONFIGURACIÓN OBLIGATORIA DE FORMAS DE PAGO E INSCRIPCIÓN GRATUITA — 22 OCTUBRE 2026

**Archivos:** `458-MIGRACION_CONFIGURACION_PAGOS_E_INSCRIPCION_GRATUITA.sql` y `458-VERIFICACION_CONFIGURACION_PAGOS_E_INSCRIPCION_GRATUITA.sql`.

**Estado:** PREPARADA, NO EJECUTADA. La verificación SQL y las pruebas funcionales están pendientes de la ejecución manual del usuario. El README 457 anterior se preserva íntegramente como prefijo de este documento, sin editar ni reordenar entradas históricas.

**Objetivo:** exigir al organizador configurar y guardar expresamente las dos decisiones de cobro antes de abrir inscripciones: cobro en línea con tarjeta y pago el día del torneo. Los valores posibles son SÍ/SÍ, SÍ/NO, NO/SÍ y NO/NO. NO/NO significa torneo gratuito, no una omisión. Una vez registrada la primera inscripción, incluso si después queda inactiva, no pueden cambiarse las decisiones de pago. Los torneos existentes y sus inscripciones históricas no se transforman ni se recalculan.

**Base de datos:** incorpora a `tournaments` las columnas `pago_tarjeta_online_habilitado`, `configuracion_pagos_guardada_at` y `configuracion_pagos_guardada_por`. La función `guardar_configuracion_pagos_458(uuid,boolean,boolean)` verifica autorización del organizador o Superadmin, dos respuestas explícitas, planificación, ausencia de cualquier inscripción histórica y tarifas en cero cuando el torneo es gratuito. El trigger `_validar_configuracion_pagos_458` impide modificaciones de formas de pago después de cualquier inscripción, rechaza tarifas positivas para un torneo gratuito y exige configuración guardada antes de la transición inicial de planificado a inscripciones abiertas. Se conserva la función de apertura anterior y las protecciones existentes.

**Inscripción gratuita:** se añade `NA` al enum `medio_pago_torneo`, como código exclusivamente interno, nunca como opción para el jugador. Las inscripciones gratuitas se registran con `total_a_pagar=0`, `monto_pagado=0`, `estado_pago=PAGADO`, `fecha_pago` de la inscripción y `referencia_pago` igual al folio generado por el trigger vigente. No se crea intento de pago ni transacción bancaria. El trigger `_validar_na_inscripcion_458` limita `NA` a torneos configurados expresamente como gratuitos y verifica integridad de importes, estado, fecha y folio. Se conservan sin cambios las restricciones de integridad de la migración 339. La nueva función `_proteger_intento_pago_configuracion_458` impide intentos de pago de inscripción en línea en torneos configurados sin tarjeta.

**RPC de inscripción:** `inscribir_gratis_individual_458(uuid,uuid)` para individual y `inscribir_gratis_en_equipo_458(uuid,uuid)` para integrantes de equipos; ambas verifican autenticación, torneo activo, inscripciones abiertas, configuración gratuita, tarifa cero y categoría/equipo. Los triggers existentes siguen verificando duplicados y otras condiciones. `registrar_equipo_completo_gratis_458(uuid)` confirma el compromiso de equipo completo con roster válido, convierte únicamente las plazas ya confirmadas y mantiene invitaciones pendientes. La tabla `tournament_team_free_enrollments_458` identifica el compromiso; `_al_confirmar_slot_gratis_458` convierte automáticamente al aceptar una invitación, y `_proteger_roster_gratis_458` evita cambios estructurales incompatibles. No se modifica el procedimiento 449 de pago diferido. Las funciones internas no conceden EXECUTE a usuarios autenticados.

**Seguridad:** funciones expuestas como `SECURITY DEFINER` con `search_path=public,pg_temp`, validación de identidad y permisos; `EXECUTE` solo para `authenticated`. La tabla de compromisos de equipos gratuitos tiene RLS habilitada y sin permisos directos para clientes. La migración no incluye pasarela Stripe ni supone que exista una integración de cobro real.

**Lovable pendiente (no es migración):** en INSCRIPCIONES mostrar las dos preguntas obligatorias y GUARDAR CONFIGURACIÓN antes de ABRIR INSCRIPCIONES; distinguir respuesta no seleccionada de NO; bloquear edición desde primera inscripción; en la App de Jugadores mostrar solo alternativas habilitadas y, para NO/NO, INSCRIPCIÓN GRATUITA sin checkout. Invocar los nuevos RPC según inscripción individual, integrante de equipo o equipo completo; conservar el flujo de invitaciones, el asistente operativo, correos y reportes. Revisar que las notificaciones y los reportes interpreten `NA` como ausencia de cobro, no ingreso. Lovable NO ejecuta migraciones SQL. El cobro real por Stripe permanece pendiente de su diseño y autorización.

**Verificación pendiente:** ejecutar exclusivamente consultas de solo lectura del archivo de verificación después de la migración manual; probar combinaciones de configuración, intento de apertura sin guardar, bloqueo tras inscripción cancelada, importes cero, folio/referencia, duplicados, aceptación de invitaciones, RLS, correo de confirmación, reportes y modalidades pagadas existentes. No declarar migración ejecutada ni funcionalidad validada sin evidencia.


---

## MIGRACIÓN 459 — PATROCINADORES TRANSVERSALES, PAGOS PARCIALES Y RECIBOS — 3 NOVIEMBRE 2026

**Objetivo:** administrar patrocinadores en cualquier torneo, con compromisos económicos fijos o flexibles y seguimiento de pagos por abono.

**Qué hace:** distingue patrocinio ECONÓMICO FIJO y FLEXIBLE; conserva el importe de categoría al registrar un patrocinio fijo; permite múltiples aportaciones, pagos consecutivos con fecha, importe y referencia, saldo automático y un PDF privado por pago con control de envío. Corrige `MIN(uuid)` en la creación de equipos de cortesía sin modificar las reglas deportivas ni los flujos de inscripción.

**Estado:** preparada para ejecución manual y verificación; integración de Lovable pendiente.


---

## MIGRACIÓN 459A — AJUSTES Y CANCELACIÓN DE APORTACIONES FLEXIBLES — 3 NOVIEMBRE 2026

**Objetivo:** permitir corregir cantidades, descripciones y compromisos de aportaciones flexibles, o cancelarlas cuando el patrocinador cambie su ofrecimiento.

**Qué hace:** agrega cantidad opcional para apoyos no monetarios, modificación controlada y cancelación lógica con motivo e historial de cambios. Excluye las aportaciones canceladas del compromiso monetario y bloquea reducciones que dejen compromisos por debajo de pagos recibidos. Conserva los pagos, recibos, categorías económicas fijas, cortesías y motores deportivos. Incorpora las RPC `sponsor_registrar_aportacion_459a`, `sponsor_modificar_aportacion_459a` y `sponsor_cancelar_aportacion_459a`.

**Estado:** CORRECCIÓN PREPARADA; NO EJECUTADA NI VERIFICADA FUNCIONALMENTE. La migración 459 se comprobó instalada mediante consultas de solo lectura. La Fase 2 de Lovable aún no ha sido ejecutada. SQL de migración y verificación correspondientes a 459A; ejecución exclusivamente manual por el usuario.


---

## MIGRACIÓN 459B — PERMISO DE CARGA DE ARCHIVOS DE PATROCINADORES — 3 NOVIEMBRE 2026

**Objetivo:** corregir el error de permisos `permission denied for function _identity_upload_authorized_444` que aparece al guardar un patrocinador con archivos adjuntos.

**Qué hace:** concede exclusivamente al rol `authenticated` permiso `EXECUTE` sobre la función existente `_identity_upload_authorized_444(text)`, utilizada por una política de Storage que incluye a usuarios autenticados. No cambia la función, las políticas, los buckets, los datos ni las reglas deportivas.

**Estado:** preparada, pendiente de ejecución manual y verificación. Prueba funcional de guardado con logotipo y constancia fiscal pendiente.

**Pendiente independiente:** revisar la reducción segura de cortesías de patrocinadores cuando ya existen jugadores vinculados, inscritos o equipos creados; no resuelto por esta corrección.


---

## MIGRACIÓN 459C — VALORACIÓN DE PATROCINIOS MIXTOS — 3 NOVIEMBRE 2026

**Objetivo:** permitir que cualquier categoría comercial (MASTER, ORO, PLATA, BRONCE y categorías variables) acepte múltiples aportaciones en dinero, bienes o servicios, con valoración acordada de la especie y control monetario separado.

**Qué hace:** añade `valor_estimado_459c` para bienes y servicios, que puede estar pendiente; transforma de manera conservadora el compromiso fijo histórico en un renglón de dinero sin alterar `compromiso_fijo_459`; crea automáticamente un renglón inicial de dinero para nuevas categorías de monto fijo. Recalcula `sponsor_estado_financiero_459` desde aportaciones monetarias de cualquier categoría y crea `sponsor_valor_total_459c` para presentar valor de categoría, dinero, especie, valor acordado, aportaciones por valorar y saldo solo monetario. Incorpora RPC `sponsor_registrar_aportacion_459c`, `sponsor_modificar_aportacion_459c`, `sponsor_cancelar_aportacion_459c` y conserva auditoría de modificaciones de valor estimado con motivo. No cambia pagos, recibos, cortesías, equipos, inscripciones o motores deportivos.

**Ejemplo funcional:** PLATA $65,000 = dinero $50,000 + comida en campo estimada en $15,000; saldo monetario inicial $50,000. El valor de la categoría es referencia comercial; el recibo fiscal de este flujo corresponde únicamente a pagos monetarios y requiere emisión externa válida.

**Compatibilidad:** los RPC anteriores 459/459A permanecen para continuidad, pero el frontend debe utilizar los 459C para registrar/editar/cancelar aportaciones mixtas. La categoría fija inicia con el valor monetario de referencia, editable con motivo y protección de importes ya pagados. La especie sin valoración no genera deuda. Las cifras de referencia congeladas en `compromiso_fijo_459` no se sobrescriben.

**Estado:** SQL PREPARADO; NO EJECUTADO NI VERIFICADO FUNCIONALMENTE. Usuario ejecuta manualmente 459C; posteriormente verificar con el archivo de solo lectura y solicitar a Lovable actualización del formulario y reportes. CURAQ fue observado antes de la migración con categoría MASTER, compromiso $110,000, sin aportaciones ni pagos.

**Pendientes ajenos a esta migración:** cierre correcto del visor PDF y descarga de constancia fiscal; protección de reducción de cortesías cuando existen jugadores vinculados; implementación y pruebas de cobros/recibos Fases 3 y 4. No se asumen completados.


---

## MIGRACIÓN 459D — CORRECCIÓN AUDITADA DE PAGOS Y BLOQUEO POR XML COINCIDENTE — 3 NOVIEMBRE 2026

**Archivos:** `459D-MIGRACION_CORRECCION_PAGOS_VALIDACION_XML_BLOQUEO.sql` y `459D-VERIFICACION_CORRECCION_PAGOS_VALIDACION_XML_BLOQUEO.sql`.

**Estado:** PREPARADA; NO EJECUTADA NI VERIFICADA FUNCIONALMENTE. Esta entrada documenta el diseño y no afirma ninguna modificación de Supabase. Ejecución manual exclusiva del usuario. Se conserva íntegramente el README maestro 459C como prefijo, con todo el historial anterior, sin alterar entradas históricas cuya situación real pueda haber evolucionado.

**Motivo:** en CURAQ se registró pago N.º 1 de $50,000 (20/10/2026, referencia TRANSFERENCIA 201261), pero el importe correcto es $55,000. El pago necesita corrección auditada antes de aceptar su comprobante. La migración NO modifica automáticamente CURAQ ni otro registro.

**Regla aprobada:** primero se registra el pago. Mientras no tenga comprobante validado, se puede corregir fecha, importe y referencia con motivo obligatorio, conservando número consecutivo, UUID e historial de valores anterior/nuevo, actor y fecha. El XML del comprobante se carga desde la app; un procedimiento autorizado analiza el atributo `Total` del elemento principal `Comprobante` y `Moneda=MXN` y compara exactamente con `sponsor_pagos_459.monto`. XML inválido o monto diferente: se rechaza la operación, sin conservar comprobante ni bloquear el pago. Cuando coincide: se guarda el XML original y su importe de manera privada y atómica, y el pago queda bloqueado definitivamente para importe y demás campos identificadores. El PDF es documento legible adicional y puede asociarse después en el bucket privado existente; registro de «enviado» permanece por pago. No se verifica SAT, RFC, impuestos, complementos de pago ni deducibilidad.

**Implementación:** tablas `sponsor_pagos_correcciones_459d` (historial auditado, lectura RLS autorizada) y `sponsor_pagos_xml_459d` (texto XML original privado, importe y metadatos, sin SELECT directo), triggers `_sponsor_proteger_pago_validado_459d` y `_sponsor_proteger_xml_459d` contra cambios posteriores, RPC `sponsor_corregir_pago_459d`, `sponsor_validar_adjuntar_xml_459d`, `sponsor_obtener_xml_459d`, `sponsor_listar_pagos_459d`. El XML se elige en el formulario y se transmite como texto a RPC; no se necesita un nuevo bucket. Se ajusta `sponsor_adjuntar_recibo_459` y la política INSERT de Storage para requerir previamente XML validado. Se refuerza `sponsor_registrar_pago_459` para heredar en servidor la preferencia general de recibo del patrocinador.

**Integridad y compatibilidad:** no altera aportaciones mixtas, saldos, cortesías, equipos, inscripciones ni motores deportivos. No elimina pagos, no crea pagos adicionales, no cambia CURAQ por sí sola. El recibo PDF permanece en almacenamiento privado; el XML se obtiene por RPC autorizada y no se muestra por lectura directa a clientes. Existen protecciones contra aceptar un comprobante cuyo `Total` no coincida y contra correcciones posteriores al bloqueo. La migración aborta si detecta PDF ya asociados, para no transformar documentación previa sin revisión.

**Lovable pendiente:** añadir CORREGIR PAGO antes de comprobante con motivo, presentar historial, selector de XML y PDF, validar XML mediante RPC en servidor (no solo Javascript), mostrar rechazo por monto/moneda, bloquear controles tras aceptación, consultar/descargar XML y PDF y marcar enviado según flujo existente. Cargar XML primero; PDF después de validar XML. No ejecutar SQL desde Lovable. Pruebas funcionales y revisión de permisos pendientes de sesión real.


---

## MIGRACIÓN 460 — CONFIGURACIÓN PREPARATORIA DE TRANSFERENCIA Y REFERENCIA DE INVITACIÓN — 4 NOVIEMBRE 2026

**Objetivo:** preparar la configuración general por torneo para transferencia bancaria y referencia de invitación, sin alterar los flujos de inscripción o cobro existentes.

**Qué hace:** agrega siete campos a `tournaments`: habilitación futura de transferencia, banco, titular, número de cuenta, CLABE y los switches para solicitar y exigir el nombre del invitador. Comprueba CLABE de 18 dígitos y coherencia de switches; protege cambios por autorización, estado planificado y ausencia de inscripciones históricas. Mantiene la lógica y los triggers 458 sin modificaciones. La transferencia permanece expresamente deshabilitada hasta la migración 461, que adaptará la detección de torneos gratuitos. No cambia datos existentes ni crea inscripciones, pagos o correos.

**Estado:** PREPARADA, NO EJECUTADA NI VERIFICADA EN SUPABASE. Ejecución manual exclusiva del usuario. La verificación SQL de solo lectura y las pruebas posteriores están pendientes.

**Archivos:** `460-MIGRACION_CONFIGURACION_TRANSFERENCIA_REFERENCIA_INVITACION.sql` y `460-VERIFICACION_CONFIGURACION_TRANSFERENCIA_REFERENCIA_INVITACION.sql`.


---

## MIGRACIÓN 461 — INTEGRACIÓN DE TRANSFERENCIA EN CONFIGURACIÓN DE PAGOS — 4 NOVIEMBRE 2026

**Objetivo:** permitir que la configuración del torneo distinga tarjeta, transferencia bancaria diferida y pago el día del evento, individualmente o combinados, sin confundir transferencia con gratuidad.

**Qué hace:** crea una RPC de guardado único para las tres modalidades, datos bancarios y switches de invitación; elimina el bloqueo temporal de transferencia de la 460; adapta únicamente las condiciones de gratuidad de las funciones 458 y conserva sus protecciones, inscripciones y flujos existentes. No inscribe jugadores, no cobra ni envía correos. El frontend y las inscripciones diferidas se implementarán en pasos posteriores.

**Estado:** PREPARADA, pendiente de ejecución manual y verificación en Supabase.


---

## MIGRACIÓN 462 — PERSISTENCIA DE MODALIDAD DE PAGO E INVITADOR EN INSCRIPCIONES — 4 NOVIEMBRE 2026

**Objetivo:** preparar cada inscripción para conservar la modalidad de pago elegida y el nombre de la persona que invitó al jugador, sin afectar los procedimientos existentes.

**Qué hace:** agrega dos columnas opcionales con restricciones de formato a `tournament_registrations`. Conserva íntegros los datos y las inscripciones históricas; no modifica pagos, inscripciones, equipos, correos ni políticas de seguridad. La captura y las validaciones funcionales se incorporarán posteriormente.

**Estado:** PREPARADA; ejecución manual y verificación en Supabase pendientes.


---

## MIGRACIÓN 463 — INSCRIPCIÓN INDIVIDUAL CON PAGO DIFERIDO UNIFICADO — 4 NOVIEMBRE 2026

**Objetivo:** incorporar transferencia bancaria y pago el día del evento como modalidades diferidas de una misma inscripción individual, sin crear un sistema paralelo.

**Qué hace:** crea una sola RPC para ambas modalidades con inscripción `PENDIENTE`, registra la modalidad y el invitador, y reutiliza las validaciones deportivas y de tarifas existentes. Conserva intactos los procedimientos anteriores, equipos, pagos y correos.

**Estado:** PREPARADA; pendiente de ejecución manual y verificación en Supabase.


---

## MIGRACIÓN 464 — INSCRIPCIÓN GRATUITA INDIVIDUAL CON INVITADOR — 4 NOVIEMBRE 2026

**Objetivo:** permitir guardar el nombre del invitador en inscripciones individuales gratuitas respetando si el torneo lo solicita y si es obligatorio.

**Qué hace:** incorpora una nueva RPC para inscripción gratuita con las mismas reglas de gratuidad de la función 458 y guarda el invitador en el mismo registro. No modifica la función 458 ni los pagos, equipos o inscripciones existentes.

**Estado:** PREPARADA; pendiente de ejecución manual y verificación en Supabase.


---

## MIGRACIÓN 465 — INVITADOR EN INSCRIPCIÓN INDIVIDUAL CON TARJETA — 4 NOVIEMBRE 2026

**Objetivo:** conservar el nombre del invitador al registrar una inscripción individual pagada con tarjeta, según la configuración del torneo.

**Qué hace:** valida el invitador en el intento de pago y lo copia a la inscripción definitiva cuando el pago se aprueba, usando el campo JSONB existente y modificando solo la rama individual del procesador. Preserva importes y las ramas de equipos y prerreservas.

**Estado:** PREPARADA; pendiente de ejecución manual y verificación en Supabase.


---

## MIGRACIÓN 466 — TRAZABILIDAD Y REENVÍO DE INVITACIONES TELEFÓNICAS — 5 NOVIEMBRE 2026

**Objetivo:** conservar el historial de intentos de invitación por reserva telefónica y permitir su rastreo y reenvío controlado desde Lovable.

**Qué hace:** crea una tabla de auditoría por intento con destinatario, usuario, fecha, identificadores de Resend y estado; protege acceso exclusivo de servidor y evita intentos simultáneos. No modifica las reservas ni los correos de inscripción. El botón, el envío y la consulta de entrega se implementan exclusivamente en Lovable. Los envíos históricos sin identificador no se pueden rastrear retroactivamente.

**Estado:** PREPARADA, NO EJECUTADA NI VERIFICADA EN SUPABASE. Integración Lovable pendiente.

**Archivos:** `466-MIGRACION_TRAZABILIDAD_REENVIO_INVITACIONES_TELEFONICAS.sql` y `466-VERIFICACION_TRAZABILIDAD_REENVIO_INVITACIONES_TELEFONICAS.sql`.


---

## MIGRACIÓN 467 — BASE SEGURA DE OPERADOR DE INSCRIPCIONES — 5 NOVIEMBRE 2026

**Objetivo:** habilitar identidad y asignación por correo/OTP para operadores de INSCRIPCIONES limitados a sus torneos, sin crear catálogo general ni conceder rol de organizador.

**Qué hace:** crea asignaciones por torneo, autorización independiente, activación por correo verificado, revocación, listado de torneos autorizados, consulta acotada y de solo lectura del perfil de inscritos, y tabla/consulta de auditoría. No amplía las RPC operativas existentes ni autoriza todavía cobros o reservas; esas funciones y la pantalla simplificada quedan pendientes de adaptación Lovable y autorizaciones por operación. La auditoría de fallos necesita registro independiente desde el servidor.

**Estado:** PREPARADA; no ejecutada, no verificada ni publicada. Solo el usuario ejecuta SQL en Supabase. No conceder acceso operativo hasta completar y verificar las siguientes fases.

**Archivos:** `467-MIGRACION_BASE_OPERADOR_INSCRIPCIONES.sql` y `467-VERIFICACION_BASE_OPERADOR_INSCRIPCIONES.sql`.


---

## MIGRACIÓN 468 — CONSULTA DE JUGADORES INSCRITOS PARA OPERADOR — 5 NOVIEMBRE 2026

**Objetivo:** habilitar una consulta limitada a las inscripciones activas del torneo asignado al operador 467, sin reutilizar la vista administrativa ni conceder acceso al catálogo general de jugadores.

**Qué hace:** crea `registration_operator_players_468(uuid)`, que exige autorización `view_players` mediante 467 y devuelve folio, nombre, categoría, estado de pago e identificador de jugador únicamente de inscripciones activas del torneo autorizado. El perfil individual se consulta por la RPC 467 de solo lectura. No modifica datos, permisos generales, pagos, reservas, tarjetas, inscripciones ni pantallas de organizador. La integración visual en Lovable y pruebas autenticadas permanecen pendientes hasta la ejecución manual de esta migración.

**Estado:** PREPARADA, NO EJECUTADA NI VERIFICADA EN SUPABASE. Ejecución exclusiva del usuario.

**Archivos:** `468-MIGRACION_CONSULTA_INSCRITOS_OPERADOR.sql` y `468-VERIFICACION_CONSULTA_INSCRITOS_OPERADOR.sql`.


---

## MIGRACIÓN 469 — AUTORIZACIONES OPERADOR DE INSCRIPCIONES — 5 NOVIEMBRE 2026

**Objetivo:** permitir que el operador autorizado por torneo utilice las funciones originales de pagos, reservas previas y reserva telefónica, sin incorporarlo al catálogo administrativo.

**Qué hace:** agrega permisos de consulta acotados por torneo, acceso a comprobantes, procedimientos específicos para registrar y anular pagos con auditoría, historial y reportes de cobranza, registro de comprobantes con UID del operador y consulta de categorías elegibles. Conserva las funciones originales de organizador/SUPERADMIN y los datos históricos; la integración de las pantallas y operaciones de servidor queda pendiente de Lovable.

**Estado:** PREPARADA, NO EJECUTADA NI VERIFICADA EN SUPABASE. Ejecución SQL exclusiva del usuario; verificar mediante consultas de solo lectura antes de habilitar las operaciones para operadores.

**Archivos:** `469-MIGRACION_AUTORIZACIONES_OPERADOR_INSCRIPCIONES.sql` y `469-VERIFICACION_AUTORIZACIONES_OPERADOR_INSCRIPCIONES.sql`.


---

## MIGRACIÓN 469A — CORRECCIÓN DE AUDITORÍA DE OPERADOR DE INSCRIPCIONES — 5 NOVIEMBRE 2026

**Objetivo:** corregir la incompatibilidad entre el resultado de auditoría de tres operaciones 469 y la restricción ya instalada en 467.

**Qué hace:** cambia exclusivamente el resultado de auditoría de `OK` a `success` en registrar pago, anular pago y registrar comprobante de transferencia. Conserva autorizaciones, procedimientos originales, datos y registros históricos.

**Estado:** PREPARADA; pendiente de ejecución manual y verificación en Supabase. La migración 469 está instalada, pero se detectó este problema mediante consultas de solo lectura. No se ha habilitado la integración del operador en Lovable.

**Archivos:** `469A-MIGRACION_CORRECCION_AUDITORIA_OPERADOR_INSCRIPCIONES.sql` y `469A-VERIFICACION_CORRECCION_AUDITORIA_OPERADOR_INSCRIPCIONES.sql`.


---

## MIGRACIÓN 469B — CORRECCIÓN DE ESQUEMA DE BÚSQUEDA EN PAGOS DEL OPERADOR — 5 NOVIEMBRE 2026

**Objetivo:** resolver el error `relation "tournament_categories" does not exist` al registrar pagos desde OPERADOR DE INSCRIPCIONES, sin afectar los pagos de ORGANIZADOR y SUPERADMIN.

**Qué hace:** ajusta exclusivamente el `search_path` de `registration_operator_register_payment_469` y `registration_operator_void_payment_469` a `public, pg_temp`, igual que los procedimientos administrativos originales. No cambia cuerpos de las funciones, validaciones, permisos, auditoría, disparadores ni datos históricos.

**Estado:** PREPARADA, NO EJECUTADA NI VERIFICADA EN SUPABASE. Tras ejecución manual, confirmar instalación con verificación de solo lectura y realizar prueba funcional de pago con una cuenta operadora.

**Archivos:** `469B-MIGRACION_CORRECCION_SEARCH_PATH_PAGOS_OPERADOR.sql` y `469B-VERIFICACION_CORRECCION_SEARCH_PATH_PAGOS_OPERADOR.sql`.


---

## MIGRACIÓN 470 — ASIGNACIÓN DE CARRITOS INCLUIDOS — 6 NOVIEMBRE 2026

**Objetivo:** incorporar asignación automática de carritos incluidos en torneos, independiente de la renta, con salidas validadas en firme como requisito.

**Qué hace:** incorpora modalidades excluyentes RENTA, INCLUIDOS y SIN_CARRITOS; inventario por ronda, distribución automática y numeración de carritos, identificación de ocupantes conforme a la hoja de salidas, confirmación, intercambio controlado antes de entregas, control de entrega y devolución por jugador, trazabilidad y control del estado para el Asistente Operativo. La visualización y boletas PDF quedan pendientes de Lovable.

**Estado:** PREPARADA; NO EJECUTADA NI VERIFICADA FUNCIONALMENTE EN SUPABASE. Sustituye borradores no ejecutados denominados 470/470A. Requiere revisión antes de ejecución manual por el usuario.

**Archivos:** `470-MIGRACION_ASIGNACION_CARRITOS_INCLUIDOS.sql` y `470-VERIFICACION_ASIGNACION_CARRITOS_INCLUIDOS.sql`.


---

## MIGRACIÓN 470A — CORRECCIÓN DE PERMISOS DE ASIGNACIÓN DE CARRITOS — 6 NOVIEMBRE 2026

**Objetivo:** eliminar privilegios de escritura y `TRUNCATE` concedidos al rol `authenticated` sobre las seis tablas de asignación de carritos creadas en la migración 470.

**Qué hace:** revoca todos los privilegios de tabla de `authenticated` en esas seis tablas y concede únicamente `SELECT` sujeto a las políticas RLS existentes. Conserva permisos de `postgres` y `service_role`; no altera datos, procedimientos, triggers, estructura ni el módulo de renta.

**Estado:** PREPARADA, PENDIENTE DE EJECUCIÓN MANUAL Y VERIFICACIÓN EN SUPABASE. La migración 470 está instalada y sus objetos principales fueron verificados por consultas de solo lectura; la corrección 470A aún no está ejecutada.

**Archivos:** `470A-MIGRACION_CORRECCION_PERMISOS_ASIGNACION_CARRITOS.sql` y `470A-VERIFICACION_CORRECCION_PERMISOS_ASIGNACION_CARRITOS.sql`.


---

## MIGRACIÓN 470B — CORRECCIÓN DE DUPLICADOS EN CARRITOS INCLUIDOS — 6 NOVIEMBRE 2026

**Objetivo:** evitar que la distribución de carritos duplique jugadores cuando las salidas validadas de equipos ya contienen una unidad por jugador.

**Qué hace:** ajusta únicamente `cart_plan_470(uuid)` para tratar como jugador individual las unidades con jugador o inscripción explícitos y expandir equipos completos solo cuando la unidad no identifica a un jugador. Conserva nombres de equipo, validación de duplicados, controles de acceso, inventario y el resto de la función. No modifica datos ni salidas.

**Estado:** PREPARADA; NO EJECUTADA NI VERIFICADA EN SUPABASE. Requiere ejecución manual del usuario y posterior verificación de solo lectura y prueba funcional.

**Archivos:** `470B-MIGRACION_CORRECCION_DUPLICADOS_CARRITOS_INCLUIDOS.sql` y `470B-VERIFICACION_CORRECCION_DUPLICADOS_CARRITOS_INCLUIDOS.sql`.
