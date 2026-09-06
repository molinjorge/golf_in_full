# TEE CENTRAL / GOLF IN FULL — README HASTA MIGRACIÓN 256

## Estado
- Proyecto Supabase: `GOLFING_FULL`.
- Aplicadas/verificadas antes de esta propuesta: hasta **255**.
- Migración propuesta actual: **256**.
- Las migraciones se ejecutan manualmente en Supabase.

### 252 — Countback y orden de leaderboard A-Go-Go
Corrige countback por `holeNumber` y reordena después de `finalRank`.

### 253 — Protección de capacidad de equipos
Impide sobrecupo en asignaciones/reasignaciones y conserva compatibilidad con roster slots.

### 254 — Franjas de hándicap como requisito formal
Valida franjas independientemente del orden de captura; las exige para finalizar configuración y abrir inscripciones; agrega paso explícito al Asistente.

### 255 — Ajuste ACL de franjas
Retira EXECUTE a `anon` sobre `validar_franjas_handicap_torneo(uuid)` y conserva authenticated/service_role.

### 256 — Inicio formal del torneo como frontera competitiva
- Mantiene `iniciar_torneo()` como transición formal desde `inscripcion_cerrada` a `en_curso`.
- Crea `obtener_estado_inicio_torneo_256(uuid)` para exponer, sin escribir, las mismas precondiciones operativas principales:
  - condiciones congeladas;
  - primera ronda activa;
  - salidas validadas;
  - tarjetas oficiales emitidas;
  - captura digital completamente inicializada.
- Crea un gate común que exige que la tarjeta pertenezca a un torneo `en_curso`.
- La inicialización digital `PENDING` sigue permitida antes del inicio.
- La primera escritura real `SCORE`/`PICKUP` queda bloqueada antes de `en_curso`.
- Recepción y captura física quedan bloqueadas antes de `en_curso`.
- Conciliación queda bloqueada antes de `en_curso`.
- Los cierres formales ya exigían `en_curso` y se conservan.
- El Asistente pasa a `schemaVersion=12` e incorpora el paso `START_TOURNAMENT`.

## Flujo operativo formal después de 256

**Cerrar inscripciones**
→ **Congelar condiciones**
→ **Armar grupos**
→ **Validar salidas**
→ **Emitir tarjetas / inicializar captura**
→ **INICIAR TORNEO**
→ **Captura competitiva**
→ **Captura física / conciliación**
→ **Cerrar categorías**
→ **Cerrar ronda**
→ **Finalizar torneo**

## Principio importante
Antes de INICIAR TORNEO se permite preparar la competencia, pero no registrar resultados competitivos.

Esto evita el defecto anterior en el que el torneo podía acumular resultados y sólo al intentar cerrar la ronda se descubría que nunca había pasado formalmente a `en_curso`.

## Siguiente paso frontend, después de verificar 256
Alinear Lovable con el backend:
1. incorporar claramente el botón/acción INICIAR TORNEO al flujo operativo;
2. permitirlo sólo cuando `obtener_estado_inicio_torneo_256().readyToStart=true`;
3. mostrar los blockers del helper cuando aún no esté listo;
4. hacer que el Asistente ejecute/navegue hacia la acción de inicio;
5. ocultar/deshabilitar captura competitiva antes de `en_curso`;
6. no duplicar las reglas backend en frontend.

### 257 — Campo de golf como fuente de verdad y retiro de `duracion_dias`
Se simplifica la configuración base del torneo para evitar inconsistencias entre Club y Campo.

- Se elimina `tournaments.duracion_dias`, dato redundante ya retirado del frontend y sin uso funcional en backend.
- `tournaments.campo_golf_id` pasa a ser el dato principal de sede.
- `tournaments.club_id` se deriva automáticamente desde `campos_golf.club_id`.
- Se conserva el trigger histórico `trg_validar_campo_pertenece_al_club`, pero ahora materializa el club en vez de comparar contra un club capturado.
- Si no hay campo, `club_id` queda `NULL`, preservando `provisionar_torneo()`.
- `validar_configuracion_minima_torneo()` exige Campo de golf y ya no reclama Club como dato independiente.
- `tournament_rounds.campo_golf_id` no cambia.
