-- ============================================================
-- KOR App · ETAPA 1 — Capa de validacion e integridad
-- ============================================================
-- Que resuelve este script (y que NO):
--   La RLS y la separacion etica YA estaban resueltas en los
--   esquemas previos (anon solo inserta, autenticado lee; la
--   auditoria es solo-consultor). Eso NO se toca aqui.
--
--   Lo que faltaba es la CAPA DE INTEGRIDAD. Hoy, con la web
--   publica, cualquiera que conozca la URL puede mandar un POST
--   con un estudio inventado, items vacios o un blob gigante, y
--   entraria. Este script cierra eso con cuatro candados:
--     1) Lista blanca de estudios (tabla estudios_validos + FK):
--        solo se aceptan respuestas de un estudio que TU registraste
--        y que esta activo. Es ademas tu interruptor de apagado.
--     2) CHECK de estructura: items debe ser un objeto JSON real,
--        ni vacio ni absurdamente grande.
--     3) CHECK de longitud en los campos de texto: corta payloads
--        inflados.
--     4) Trigger anti-flood: techo de filas por estudio, para que
--        nadie pueda inundar una tabla aunque acierte un slug.
--
-- Como correrlo: Supabase > SQL Editor > New query > pega TODO > Run.
-- Es re-ejecutable: si lo corres dos veces no falla ni duplica.
-- ============================================================


-- ============================================================
-- 1. LISTA BLANCA DE ESTUDIOS
-- ============================================================
-- Registro central de estudios-cliente. El slug (codigo) es la
-- llave que cruza clima + bienestar + auditoria. Solo los slugs
-- que vivan aqui y esten activos podran recibir respuestas.
create table if not exists public.estudios_validos (
  codigo      text primary key,                 -- slug corto, minusculas, sin tildes (ej. estudio-norte)
  etiqueta    text,                              -- nombre legible para ti (no se comparte)
  activo      boolean not null default true,     -- interruptor: false = deja de aceptar respuestas
  created_at  timestamptz not null default now()
);

-- Candado de forma del slug: minusculas, numeros y guiones; 2 a 60 chars.
do $$
begin
  alter table public.estudios_validos
    add constraint chk_slug_formato
    check (codigo ~ '^[a-z0-9][a-z0-9-]{1,59}$');
exception when duplicate_object then null;
end $$;

-- RLS: esta tabla es solo tuya. El rol anonimo NO necesita verla;
-- la verificacion de llave foranea funciona aunque anon no pueda
-- leerla (las constraints se chequean por integridad, no por RLS).
alter table public.estudios_validos enable row level security;

do $$
begin
  create policy "estudios_solo_consultor_lee"
    on public.estudios_validos for select to authenticated using (true);
exception when duplicate_object then null;
end $$;

do $$
begin
  create policy "estudios_solo_consultor_escribe"
    on public.estudios_validos for all to authenticated
    using (true) with check (true);
exception when duplicate_object then null;
end $$;


-- ============================================================
-- 2. NORMALIZAR Y RESPALDAR DATOS EXISTENTES
-- ============================================================
-- Funcion de normalizacion: convierte cualquier texto en un slug
-- valido (minusculas; espacios, tildes y simbolos -> guion;
-- recorta a 60). Si no logra al menos 2 caracteres, devuelve NULL.
-- Asi "Estudio XYZ", "estudio xyz" y "estudio-xyz" terminan igual.
create or replace function public.kor_slug(t text)
returns text
language sql
immutable
as $func$
  select case when length(s) >= 2 then left(s, 60) else null end
  from (
    select regexp_replace(
             regexp_replace(lower(coalesce(t, '')), '[^a-z0-9]+', '-', 'g'),
             '(^-+)|(-+$)', '', 'g') as s
  ) q;
$func$;

-- (a) Filas SIN estudio o cuyo texto no produce un slug usable son
-- datos de prueba sin valor: estorban para activar la llave foranea.
-- Si quieres conservar alguna, comenta estas lineas y revisala a mano.
delete from public.respuestas        where public.kor_slug(estudio) is null;
delete from public.respuestas_clima  where public.kor_slug(estudio) is null;
delete from public.auditoria_madurez where public.kor_slug(estudio) is null;

-- (b) Normaliza el estudio de las filas que quedan (solo si cambia,
-- para no tocar filas que ya tienen FK valida).
update public.respuestas        set estudio = public.kor_slug(estudio)
  where estudio is distinct from public.kor_slug(estudio);
update public.respuestas_clima  set estudio = public.kor_slug(estudio)
  where estudio is distinct from public.kor_slug(estudio);
update public.auditoria_madurez set estudio = public.kor_slug(estudio)
  where estudio is distinct from public.kor_slug(estudio);

-- (c) Registra en la lista blanca todos los slugs ya normalizados,
-- para que el FK no rechace ninguna fila existente.
insert into public.estudios_validos (codigo, etiqueta, activo)
select distinct estudio, '(backfill prueba)', true from public.respuestas
on conflict (codigo) do nothing;
insert into public.estudios_validos (codigo, etiqueta, activo)
select distinct estudio, '(backfill prueba)', true from public.respuestas_clima
on conflict (codigo) do nothing;
insert into public.estudios_validos (codigo, etiqueta, activo)
select distinct estudio, '(backfill prueba)', true from public.auditoria_madurez
on conflict (codigo) do nothing;


-- ============================================================
-- 3. LLAVE FORANEA + NOT NULL (el candado principal)
-- ============================================================
-- A partir de aqui, ninguna respuesta entra si su estudio no esta
-- registrado en estudios_validos. Es lo que mata el spam de bots:
-- no conocen ningun slug valido.

-- respuestas (qBLG-W)
alter table public.respuestas alter column estudio set not null;
do $$
begin
  alter table public.respuestas
    add constraint fk_respuestas_estudio
    foreign key (estudio) references public.estudios_validos (codigo);
exception when duplicate_object then null;
end $$;

-- respuestas_clima (IMCOC-W)
alter table public.respuestas_clima alter column estudio set not null;
do $$
begin
  alter table public.respuestas_clima
    add constraint fk_clima_estudio
    foreign key (estudio) references public.estudios_validos (codigo);
exception when duplicate_object then null;
end $$;

-- auditoria_madurez (Pista C, solo-consultor; FK por consistencia del cruce)
alter table public.auditoria_madurez alter column estudio set not null;
do $$
begin
  alter table public.auditoria_madurez
    add constraint fk_auditoria_estudio
    foreign key (estudio) references public.estudios_validos (codigo);
exception when duplicate_object then null;
end $$;


-- ============================================================
-- 4. CHECK DE ESTRUCTURA Y LONGITUD
-- ============================================================
-- PostgreSQL no permite subconsultas dentro de un CHECK, asi que
-- contamos las claves del JSON con esta funcion auxiliar (si es
-- valida dentro de un CHECK por ser inmutable).
create or replace function public.kor_njsonkeys(j jsonb)
returns integer
language sql
immutable
as $func$
  select count(*)::int from jsonb_object_keys(j);
$func$;

-- ---- respuestas (qBLG-W: 55 items) ----
do $$
begin
  alter table public.respuestas add constraint chk_resp_items_objeto
    check (jsonb_typeof(items) = 'object');
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas add constraint chk_resp_items_conteo
    check (public.kor_njsonkeys(items) between 50 and 70);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas add constraint chk_resp_tamano
    check (length(items::text) <= 8000);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas add constraint chk_resp_textos
    check (
      char_length(estudio)              <= 60
      and char_length(coalesce(codigo,     '')) <= 40
      and char_length(coalesce(rol,        '')) <= 60
      and char_length(coalesce(tiempo,     '')) <= 40
      and char_length(coalesce(plataforma, '')) <= 60
    );
exception when duplicate_object then null;
end $$;

-- ---- respuestas_clima (IMCOC-W: ~43 numerados + ~9 contextuales) ----
do $$
begin
  alter table public.respuestas_clima add constraint chk_clima_items_objeto
    check (jsonb_typeof(items) = 'object');
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas_clima add constraint chk_clima_items_conteo
    check (public.kor_njsonkeys(items) between 40 and 70);
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas_clima add constraint chk_clima_abiertas_objeto
    check (abiertas is null or jsonb_typeof(abiertas) = 'object');
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas_clima add constraint chk_clima_tamano
    check (
      length(items::text) <= 8000
      and length(coalesce(abiertas::text, '')) <= 6000
    );
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.respuestas_clima add constraint chk_clima_textos
    check (
      char_length(estudio)                         <= 60
      and char_length(coalesce(codigo,           '')) <= 40
      and char_length(coalesce(rol,              '')) <= 60
      and char_length(coalesce(sede,             '')) <= 60
      and char_length(coalesce(tiempo,           '')) <= 40
      and char_length(coalesce(fecha_aplicacion, '')) <= 20
    );
exception when duplicate_object then null;
end $$;

-- ---- auditoria_madurez (solo-consultor; limites generosos) ----
do $$
begin
  alter table public.auditoria_madurez add constraint chk_aud_niveles_objeto
    check (jsonb_typeof(niveles) = 'object');
exception when duplicate_object then null;
end $$;

do $$
begin
  alter table public.auditoria_madurez add constraint chk_aud_tamano
    check (
      length(niveles::text)                       <= 4000
      and length(coalesce(evidencias::text, ''))  <= 8000
      and length(coalesce(prioridades::text, '')) <= 2000
      and char_length(coalesce(narrativa, ''))    <= 6000
    );
exception when duplicate_object then null;
end $$;


-- ============================================================
-- 5. TRIGGER: interruptor "activo" + anti-flood
-- ============================================================
-- Hace DOS cosas que la llave foranea por si sola no puede:
--   a) Interruptor de apagado: si el estudio esta activo = false,
--      rechaza el envio. (El FK solo verifica que el slug exista,
--      no que siga abierto; por eso este candado es necesario.)
--   b) Anti-flood: aunque alguien adivine un slug activo, al pasar
--      el techo de filas el insert se rechaza.
-- Aplica solo a las tablas publicas (clima y bienestar); la
-- auditoria es solo-consultor y no necesita este candado.
create or replace function public.fn_guardia_estudio()
returns trigger
language plpgsql
as $func$
declare
  v_tope   constant integer := 500;  -- <<< AJUSTA AQUI el techo por estudio
  v_activo boolean;
  v_n      integer;
begin
  -- a) el estudio existe y esta abierto?
  select activo into v_activo
    from public.estudios_validos where codigo = new.estudio;
  if v_activo is null then
    raise exception 'El estudio % no esta registrado en la lista blanca.', new.estudio
      using errcode = 'check_violation';
  elsif v_activo = false then
    raise exception 'El estudio % esta cerrado: no acepta respuestas.', new.estudio
      using errcode = 'check_violation';
  end if;

  -- b) queda cupo?
  execute format('select count(*) from %I where estudio = $1', tg_table_name)
    into v_n using new.estudio;
  if v_n >= v_tope then
    raise exception 'Tope de respuestas alcanzado para el estudio % (max %).', new.estudio, v_tope
      using errcode = 'check_violation';
  end if;

  return new;
end $func$;

drop trigger if exists trg_tope_respuestas on public.respuestas;
drop trigger if exists trg_guardia_respuestas on public.respuestas;
create trigger trg_guardia_respuestas
  before insert on public.respuestas
  for each row execute function public.fn_guardia_estudio();

drop trigger if exists trg_tope_clima on public.respuestas_clima;
drop trigger if exists trg_guardia_clima on public.respuestas_clima;
create trigger trg_guardia_clima
  before insert on public.respuestas_clima
  for each row execute function public.fn_guardia_estudio();


-- ============================================================
-- 6. LISTO. Antes de tu primer trabajo de campo real, registra
--    el estudio (si no, sus respuestas seran rechazadas):
--
--    insert into public.estudios_validos (codigo, etiqueta)
--    values ('estudio-norte', 'Estudio Norte - piloto Cali');
--
--    Y al cerrar el campo, apagalo para dejar de aceptar envios:
--
--    update public.estudios_validos set activo = false
--    where codigo = 'estudio-norte';
-- ============================================================
