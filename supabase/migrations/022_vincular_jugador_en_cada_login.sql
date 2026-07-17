-- =========================================================
-- MIGRACIÓN 022
-- La migración 020 solo vinculaba en el momento de la PRIMERA
-- confirmación de correo de una cuenta. Si esa cuenta ya estaba
-- confirmada de antes (por una prueba previa, por ejemplo) y
-- después se crea/recrea un perfil pre-registrado en players,
-- nunca había un segundo momento para intentar la vinculación.
--
-- Esta migración agrega un tercer disparador: cada vez que
-- alguien inicia sesión exitosamente (last_sign_in_at cambia),
-- se reintenta la vinculación. Es seguro repetirlo: la función
-- solo actúa si encuentra un perfil con auth_user_id vacío.
-- =========================================================

create trigger trg_vincular_jugador_en_login
after update of last_sign_in_at on auth.users
for each row
when (new.last_sign_in_at is distinct from old.last_sign_in_at)
execute function vincular_jugador_preregistrado();
