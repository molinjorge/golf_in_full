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

## Migración 418 — HCP declarado congelado en reporte detallado Stroke Play

**Archivo:** `418_hcp_declarado_reporte_stroke_play.sql`  
**Verificación:** `418_verificacion_hcp_declarado_reporte_stroke_play.sql`

### Objetivo

Enriquecer el reporte detallado de **Stroke Play Individual** creado en la migración 417 para que pueda mostrar por separado el **HCP declarado/índice congelado para el torneo** y el **Playing HCP** de la ronda.

### Diagnóstico previo

La RPC 417 entregaba únicamente `playingHandicap`. La base sí conserva el índice histórico utilizado para la competencia en `tournament_handicap_snapshots.handicap_index`, enlazado a la unidad de validación oficial de la tarjeta.

Esta fuente es preferible al valor actual de `players.handicap_declarado`, porque el perfil del jugador puede cambiar después. El snapshot conserva además `handicap_source`, `handicap_source_date` y `handicap_status`.

En la revisión de **PRUEBA AUTOSERVICIO #3** se comprobó que el snapshot conserva el valor histórico utilizado para cada jugador y que éste es distinto conceptualmente del Playing Handicap calculado para la ronda.

### Qué hace

- Redefine únicamente `public.obtener_reporte_detallado_scores_stroke_play_417(...)`, conservando su nombre y parámetros para no romper el frontend ya conectado.
- Eleva `schemaVersion` del payload de 1 a 2.
- Agrega a cada jugador:
  - `declaredHandicap`: `tournament_handicap_snapshots.handicap_index`.
  - `handicapSource`.
  - `handicapSourceDate`.
  - `handicapStatus`.
- Conserva sin cambios `playingHandicap`.
- El dato nuevo se obtiene a través de la tarjeta oficial → unidad de validación → snapshot de hándicap congelado.
- No consulta el HCP actual del perfil como fuente del reporte y no recalcula hándicap en frontend.

### Aislamiento

418 no modifica tablas, triggers, motores deportivos, captura, conciliación, leaderboard, desempates, cierre, resultados oficiales, Stableford, Best Ball ni A-Go-Go.

La RPC A-Go-Go protegida debe conservar el MD5:

`567781c11fb33f443d61555f0950d87c`

### Uso previsto en frontend

Una vez ejecutada y verificada 418, el reporte Stroke Play puede presentar:

`POS | JUGADOR | HCP DECLARADO | PLAYING HCP | 1–9 | OUT | 10–18 | IN | TOTAL`

El frontend debe leer `declaredHandicap` y `playingHandicap` como datos distintos y no recalcular ninguno.

### Estado

**Preparada para ejecución manual y verificación.**

---

## Migración 419 — Reporte detallado de puntos Stableford Individual

**Archivo:** `419_reporte_detallado_puntos_stableford.sql`  
**Verificación:** `419_verificacion_reporte_detallado_puntos_stableford.sql`

### Objetivo

Agregar un contrato backend específico para el **Reporte Detallado de Stableford Individual**, equivalente operativamente al reporte detallado de Stroke Play pero respetando el motor Stableford: por hoyo se reportan **puntos Stableford GROSS o NETO**, no golpes recalculados por frontend.

### Diagnóstico previo

Stableford ya dispone de fuentes deportivas oficiales completas:

- `obtener_resultado_stableford_oficial_tarjeta`
- `obtener_resultados_stableford_oficiales_ronda`
- `obtener_leaderboard_stableford_ronda`
- `obtener_desempates_stableford_ronda`

El resultado oficial por tarjeta ya contiene por hoyo `grossPoints`, `netPoints`, `handicapStrokes`, score gross/net oficial, PICKUP y aplicación de reglas especiales. El leaderboard ya resuelve posiciones y desempates Stableford.

Por tanto, el nuevo reporte no debe duplicar el motor ni recalcular puntos en frontend.

### Qué hace

Crea `public.obtener_reporte_detallado_scores_stableford_419(round_id, category_id, criterio)`.

- Solo admite `scoring_engine=stableford` y `participation_type=individual`.
- Reutiliza resultados y leaderboard oficiales Stableford.
- Admite criterio `GROSS` o `NETO` únicamente cuando la clasificación correspondiente está habilitada.
- Entrega posición oficial y metadatos de desempate.
- Entrega por hoyo el payload oficial Stableford existente.
- Calcula en backend OUT/IN como suma de los **puntos oficiales ya producidos por el motor**; no vuelve a calcular las reglas Stableford.
- Entrega TOTAL oficial del motor.
- Incluye `declaredHandicap` desde `tournament_handicap_snapshots.handicap_index` y mantiene separado `playingHandicap`.
- Conserva estados terminales, pickups y demás evidencia oficial contenida en `holes`.
- Seguridad: `SECURITY DEFINER`, requiere usuario autenticado y permiso administrativo; `anon` no recibe EXECUTE.

### Contrato previsto

`reportType = DETAILED_POINTS_STABLEFORD`

Cada jugador incluye, entre otros:

- posición/orden/desempate;
- `declaredHandicap`;
- `playingHandicap`;
- puntos GROSS OUT / IN / TOTAL;
- puntos NETO OUT / IN / TOTAL;
- `holes` oficiales con `grossPoints`, `netPoints`, `handicapStrokes`, PICKUP y evidencia Stableford.

### Aislamiento

419 no modifica Stroke Play, Best Ball, A-Go-Go, tablas, triggers, captura, conciliación, cierre ni publicación.

La RPC protegida de A-Go-Go debe conservar el MD5:

`567781c11fb33f443d61555f0950d87c`

### Estado

**Preparada para ejecución manual y verificación.**

---

## Migración 420 — Reporte detallado de scores Best Ball TEAM

**Archivo:** `420_reporte_detallado_scores_best_ball.sql`  
**Verificación:** `420_verificacion_reporte_detallado_scores_best_ball.sql`

### Objetivo

Agregar el contrato backend para el reporte detallado de **Best Ball por equipos**, sin duplicar el motor deportivo.

### Diagnóstico previo

Best Ball ya cuenta con una cadena oficial:

- `obtener_resultado_oficial_best_ball_325`: autoridad oficial por tarjeta/equipo. Calcula el mejor GROSS y el mejor NET por hoyo después de conciliación y conserva qué integrantes cuentan en cada métrica.
- `obtener_desempates_best_ball_ronda_327`: evidencia de desempates.
- `obtener_leaderboard_best_ball_ronda_328`: leaderboard oficial por categoría/equipo, clasificación GROSS/NETO y estado competitivo.

El resultado F11 conserva por hoyo `officialBestGross`, `officialBestNet`, `grossCountingPlayers`, `netCountingPlayers` y la evidencia individual de todos los integrantes.

### Qué hace

Crea `public.obtener_reporte_detallado_scores_best_ball_420(round_id, category_id, criterio)`.

- Solo admite Best Ball TEAM.
- Reutiliza F11/F13/F14; no reproduce el cálculo de Best Ball.
- Unidad competitiva: TEAM.
- Devuelve equipo, integrantes congelados, HCP congelado y Playing HCP individual.
- Devuelve por hoyo el mejor score oficial GROSS y NET del equipo y qué integrante(s) aportaron ese score.
- Devuelve OUT/IN calculados en backend a partir de los scores oficiales F11 y TOTAL oficial F11.
- Devuelve rank base y evidencia de empate/desempate del backend.
- GROSS y NETO solo se permiten cuando la categoría correspondiente está habilitada.
- Requiere autenticación y permiso administrativo; `anon` no recibe EXECUTE.

### Importante

Best Ball no tiene un único HCP TEAM. Cada integrante conserva su HCP/Playing HCP individual congelado; el motor selecciona el mejor resultado por hoyo después de aplicar el handicap individual correspondiente para NET.

No existe actualmente una ronda Best Ball detectada en los snapshots de condiciones consultados antes de preparar 420, por lo que la prueba funcional real deberá realizarse cuando exista una ronda Best Ball emitida, capturada y conciliada.

### Aislamiento

420 no modifica Stroke Play, Stableford, A-Go-Go, captura, conciliación, resultados existentes, cierres ni publicación. A-Go-Go continúa protegido y sus tres archivos frontend existentes no deben modificarse.

### Estado

**Preparada para ejecución manual y verificación.**
