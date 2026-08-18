# MIGRACIÓN 140 — VALIDACIÓN Y CIERRE DE SALIDAS POR RONDA

## Estado

**Preparada para ejecución manual en Supabase.** No debe marcarse como aplicada hasta ejecutar el verificador posterior y obtener `31 verificaciones; 0 error(es)`.

Las migraciones 136, 137, 138 y 139 deben estar aplicadas y verificadas antes de ejecutar ésta.

## Archivos

- `140_validacion_y_cierre_salidas_ronda.sql`: migración con escritura de esquema. Crea las validaciones versionadas, RPC, RLS y candados de salidas.
- `SUPABASE-VERIFICAR-VALIDACION-CIERRE-SALIDAS-RONDA.sql`: verificador posterior de sólo lectura. No modifica datos ni esquema.

## Objetivo

Incorporar un paso operativo previo a la emisión de tarjetas:

1. revisar integralmente las salidas de una ronda;
2. guardar una fotografía inmutable y versionada del acomodo aceptado;
3. impedir modificaciones accidentales mientras la salida esté validada;
4. permitir una reapertura explícita, auditada y con motivo;
5. dejar una base reutilizable para otras modalidades.

La primera implementación habilitada es **Stroke Play individual con salida Shotgun**.

## Diseño reutilizable

La validación pertenece a la ronda completa y no a un PDF ni a una categoría aislada.

| Nivel | Función |
|---|---|
| `tournament_round_start_validations` | Cabecera versionada de la validación y fotografía JSON canónica. |
| `tournament_round_start_validation_groups` | Grupos físicos incluidos en la salida validada. |
| `tournament_round_start_validation_units` | Unidades asignadas a cada grupo. Admite `registration` y deja preparado `team`. |
| `validator_engine` | Identifica el conjunto de reglas aplicado. La primera versión es `stroke_individual_shotgun_v1`. |

Las modalidades futuras podrán reutilizar el mismo versionado, RLS, reapertura, auditoría, locks y tablas normalizadas. Cada nueva modalidad deberá incorporar su propio validador y constructor de fotografía sin alterar las versiones históricas existentes.

## RPC públicas

Todas requieren sesión `authenticated` y permiso administrativo sobre el torneo.

### `previsualizar_validacion_salidas_ronda(uuid)`

No escribe. Devuelve:

- si la ronda está lista;
- motor validador aplicable;
- errores y advertencias;
- conteo de configuraciones, grupos y participantes;
- validación activa, si ya existe.

### `validar_salidas_ronda(uuid)`

- serializa la operación mediante un lock por ronda;
- vuelve a ejecutar todas las validaciones dentro del mismo cierre;
- guarda una fotografía JSON determinista;
- genera un hash MD5 del contenido;
- crea las filas normalizadas de grupos y unidades;
- es idempotente si la ronda ya está validada.

### `obtener_estado_validacion_salidas_ronda(uuid)`

Devuelve el estado ligero para la interfaz: validada o no, versión activa, hash, cantidades e historial.

### `reabrir_salidas_ronda(uuid, text)`

Requiere un motivo de al menos cinco caracteres. Conserva intacta la versión anterior y la marca como `reopened`; después pueden corregirse las salidas y crear una versión nueva.

## Validaciones iniciales

Entre otras comprobaciones, la migración revisa:

- torneo congelado y ronda incluida en el snapshot;
- ronda activa y salida Shotgun;
- modalidad Stroke Play individual;
- formato vivo igual al formato congelado;
- 18 hoyos congelados;
- turnos, categorías, configuraciones y hoyos Shotgun activos;
- cada participante activo pertenece exactamente a un turno y un grupo;
- inexistencia de participantes duplicados, inactivos o sin snapshot;
- coincidencia de categoría entre participante y grupo;
- grupos no vacíos y dentro del máximo;
- orden interno completo y sin duplicados;
- posiciones físicas A/B únicas y válidas;
- salida B sólo cuando el hoyo permite doble salida;
- consistencia entre turno, hoyo, grupo y hora;
- ausencia de equipos en el motor individual;
- distancias congeladas disponibles para cada tee y hoyo.

Las advertencias no impiden validar, pero se devuelven a la interfaz. Incluyen, por ejemplo, estatus del torneo todavía abierto, advertencias heredadas del congelamiento, inscripciones retiradas y grupos por debajo del tamaño normal.

## Qué queda bloqueado después de validar

Mientras exista una validación activa no pueden insertarse, modificarse ni eliminarse filas que alteren la salida de esa ronda en:

- `tournament_round_shifts`;
- `tournament_round_shift_categories`;
- `tournament_shotgun_category_configs`;
- `tournament_shotgun_category_holes`;
- `tournament_groups`;
- `tournament_group_players`;
- `tournament_group_teams`.

También se bloquea la baja o reactivación de una inscripción incluida en una ronda validada. Esto se aplica mediante triggers de base de datos, por lo que protege tanto las RPC existentes como las escrituras directas permitidas por políticas antiguas.

Para realizar cambios debe utilizarse primero `reabrir_salidas_ronda()`.

## Qué no crea ni congela esta migración

- No crea tarjetas físicas o electrónicas.
- No crea folios ni códigos QR.
- No genera ni guarda PDF.
- No captura resultados ni sanciones.
- No inicia deportivamente la ronda ni cambia el torneo a `en_curso`.
- No congela perfiles ni catálogos globales.
- No emite, cancela ni repone tarjetas.

La emisión, identidad, QR, cancelación y reposición de tarjetas corresponde a la **Migración 141**. La tarjeta física seguirá siendo el documento oficial; el registro digital será social/provisional según la regla acordada.

## Seguridad

- Las tres tablas nuevas tienen RLS habilitado.
- `authenticated` sólo recibe `SELECT` sobre ellas.
- No existen políticas ni privilegios de escritura directa para `anon` o `authenticated`.
- Toda escritura se realiza mediante RPC `SECURITY DEFINER` autorizadas.
- Las funciones internas no son ejecutables desde los roles cliente.
- Sólo puede existir una validación activa por ronda.
- Las fotografías históricas no pueden editarse ni eliminarse.

## Orden de ejecución

1. Abrir el SQL Editor del proyecto correcto en Supabase.
2. Ejecutar completo `140_validacion_y_cierre_salidas_ronda.sql`.
3. Confirmar que finaliza sin error y muestra `Success`.
4. Ejecutar completo `SUPABASE-VERIFICAR-VALIDACION-CIERRE-SALIDAS-RONDA.sql`.
5. Confirmar `31 verificaciones; 0 error(es)`.
6. Compartir el resultado antes de iniciar cambios en Lovable.

## Importante para Lovable

Lovable no debe crear ni ejecutar migraciones. Después de verificar Supabase, el frontend deberá consumir exclusivamente las cuatro RPC públicas de esta migración, mostrar los errores reales y tratar el estado validado como sólo lectura hasta una reapertura autorizada.
