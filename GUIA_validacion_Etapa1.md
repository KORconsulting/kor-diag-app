# Etapa 1 — Cómo aplicar la validación en Supabase

Esta guía acompaña a `supabase_validacion_etapa1.sql`. Es el candado que
hoy bloquea usar el sistema con un estudio real: la web ya es pública y,
sin esto, las tablas aceptan envíos basura.

## Qué hace (en una frase)
Hace que **solo entren respuestas de un estudio que tú registraste y que
está abierto**, con la estructura correcta y sin payloads inflados.

Lo que ya estaba bien (RLS, separación ética: anon solo escribe, tú lees)
**no se toca**. Esto suma la capa que faltaba: integridad.

## Cuatro candados que instala
1. **Lista blanca de estudios** (`estudios_validos` + llave foránea). Un
   bot que tope con la URL no conoce ningún código válido: no entra.
2. **Interruptor de apagado** (`activo`). Cierras el campo y deja de
   aceptar envíos, sin borrar nada.
3. **CHECK de estructura y tamaño**. `items` debe ser un objeto JSON con
   el número de claves esperado; nada vacío, nada gigante.
4. **Anti-flood**. Techo de respuestas por estudio (500 por defecto): ni
   acertando un código se puede inundar la tabla.

## Pasos para aplicarlo (una sola vez)
1. Entra a Supabase → tu proyecto → **SQL Editor** → **New query**.
2. Abre `supabase_validacion_etapa1.sql`, copia **todo** y pégalo.
3. **Run**. Es re-ejecutable: si lo corres dos veces no falla ni duplica.

> Nota: el script borra las filas de prueba que **no** tengan código de
> estudio (son datos sin valor que estorban para activar la regla). Si
> tienes pruebas que quieras conservar, comenta las 3 líneas marcadas en
> la sección 2 antes de correrlo.

## Tu rutina de trabajo de campo

**Antes de empezar con un estudio nuevo** — regístralo (si no, sus
respuestas serán rechazadas):

```sql
insert into public.estudios_validos (codigo, etiqueta)
values ('estudio-norte', 'Estudio Norte - piloto Cali');
```

El `codigo` es el mismo slug que el facilitador escribe en la pantalla
"Preparar sesión" de los formularios. Reglas del slug: minúsculas,
números y guiones, sin tildes ni espacios (ej. `estudio-norte`).

**Al cerrar el campo** — apágalo para dejar de recibir envíos:

```sql
update public.estudios_validos set activo = false
where codigo = 'estudio-norte';
```

**Ver qué estudios tienes y su estado:**

```sql
select codigo, etiqueta, activo, created_at
from public.estudios_validos order by created_at desc;
```

## Cómo verificar que quedó bien (opcional)
En el SQL Editor, intenta un insert con un estudio inventado:

```sql
insert into public.respuestas (estudio, codigo, items)
values ('estudio-pirata', 'x', '{"1":"5"}'::jsonb);
```

Debe **fallar** con un mensaje como *"El estudio estudio-pirata no está
registrado en la lista blanca."* Si falla, el candado funciona.

## Parámetro ajustable
El techo anti-flood (500 respuestas por estudio) está en la función
`fn_guardia_estudio()`, en la línea marcada `<<< AJUSTA AQUÍ`. Un estudio
real tiene de 5 a 40 participantes; solo súbelo si algún día corres uno
enorme.

## Lo que esto NO cubre (honestidad técnica)
- **No es un captcha.** Si alguien conoce un código de estudio activo,
  puede mandar respuestas mientras esté abierto. La defensa real es que
  el código solo se comparte con el facilitador y el estudio se apaga al
  terminar. Para campañas con riesgo alto, la Etapa siguiente sería un
  token de sesión por dispositivo; hoy no hace falta.
- **No valida que cada respuesta esté entre 1 y 7** ítem por ítem. La UI
  de botones ya constriñe eso en los envíos legítimos, y el resto de
  candados bloquea los ilegítimos. Validación de rango por valor queda
  para después, si algún día se justifica.

---
*Verificado contra un PostgreSQL real antes de entregar: aplicación
limpia y nueve casos de prueba (legítimo entra; estudio inexistente,
estudio cerrado, items vacío, items no-objeto, payload gigante, estudio
nulo, texto sobre-largo y flood, todos rechazados).*
