--
-- PostgreSQL database dump
--

\restrict dkxDuUe4QacpqjYu0gmbVuwIOie9mh6rhKg5XUgdh2hKFh9HgIgc0v9ELsfZREf

-- Dumped from database version 14.19 (Ubuntu 14.19-0ubuntu0.22.04.1)
-- Dumped by pg_dump version 14.19 (Ubuntu 14.19-0ubuntu0.22.04.1)

SET statement_timeout = 0;
SET lock_timeout = 0;
SET idle_in_transaction_session_timeout = 0;
SET client_encoding = 'UTF8';
SET standard_conforming_strings = on;
SELECT pg_catalog.set_config('search_path', '', false);
SET check_function_bodies = false;
SET xmloption = content;
SET client_min_messages = warning;
SET row_security = off;

--
-- Name: api; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA api;


--
-- Name: dict; Type: SCHEMA; Schema: -; Owner: -
--

CREATE SCHEMA dict;


--
-- Name: pg_trgm; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pg_trgm WITH SCHEMA public;


--
-- Name: EXTENSION pg_trgm; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pg_trgm IS 'text similarity measurement and index searching based on trigrams';


--
-- Name: pgcrypto; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA public;


--
-- Name: EXTENSION pgcrypto; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION pgcrypto IS 'cryptographic functions';


--
-- Name: vector; Type: EXTENSION; Schema: -; Owner: -
--

CREATE EXTENSION IF NOT EXISTS vector WITH SCHEMA public;


--
-- Name: EXTENSION vector; Type: COMMENT; Schema: -; Owner: -
--

COMMENT ON EXTENSION vector IS 'vector data type and ivfflat and hnsw access methods';


--
-- Name: artifact_value_type_t; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.artifact_value_type_t AS ENUM (
    'text',
    'json',
    'int',
    'float',
    'bool',
    'binary'
);


--
-- Name: doc_format_t; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.doc_format_t AS ENUM (
    'text',
    'markdown',
    'yaml',
    'json',
    'toml',
    'html'
);


--
-- Name: msg_role_t; Type: TYPE; Schema: public; Owner: -
--

CREATE TYPE public.msg_role_t AS ENUM (
    'system',
    'user',
    'assistant',
    'tool'
);


--
-- Name: prompt_get(text); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.prompt_get(_key text) RETURNS text
    LANGUAGE sql STABLE
    AS $$
  SELECT vp.prompt_text
  FROM public.v_prompts vp
  WHERE vp.prompt_key = _key
    AND coalesce(vp.is_del,false) = false
  ORDER BY vp.created DESC
  LIMIT 1
$$;


--
-- Name: prompt_set(text, text, uuid); Type: FUNCTION; Schema: api; Owner: -
--

CREATE FUNCTION api.prompt_set(_key text, _text text, _blob_meta_id uuid DEFAULT NULL::uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_meta uuid;
  v_blob uuid := COALESCE(_blob_meta_id, '00000000-0000-0000-0000-000000000000'::uuid);
BEGIN
  -- ищем последнюю активную версию по ключу
  SELECT meta_id
  INTO v_meta
  FROM public.v_prompts
  WHERE prompt_key = _key AND coalesce(is_del,false)=false
  ORDER BY created DESC
  LIMIT 1;

  IF v_meta IS NULL THEN
    -- нет активной — создаём новую строку через v_artifacts (сработает upsert)
    INSERT INTO public.v_artifacts(
      artifact_kind_code,
      artifact_subkind_code,
      artifact_content,
      artifact_content_len
    ) VALUES (
      'prompts',
      _key,
      _text,
      char_length(_text)
    ) RETURNING meta_id INTO v_meta;
  ELSE
    -- есть активная — просто обновим содержимое через v_artifacts (сработает update-часть триггера)
    UPDATE public.v_artifacts
       SET artifact_content     = _text,
           artifact_content_len = char_length(_text)
     WHERE meta_id = v_meta;
  END IF;

  RETURN v_meta;
END;
$$;


--
-- Name: is_valid_kind(text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.is_valid_kind(p_code text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT EXISTS (SELECT 1 FROM dict.artifact_kinds(p_code, NULL::text) LIMIT 1)
$$;


--
-- Name: is_valid_prompt_key(text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.is_valid_prompt_key(p_key text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT EXISTS (SELECT 1 FROM dict.prompt_keys(_key := p_key) LIMIT 1)
$$;


--
-- Name: is_valid_subkind(text, text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.is_valid_subkind(p_subcode text, p_kind_code text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT EXISTS (
    SELECT 1
    FROM dict.artifact_subkinds(p_subcode, NULL::text, p_kind_code, NULL::text)
    LIMIT 1
  )
$$;


--
-- Name: is_valid_user(text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.is_valid_user(p_name text) RETURNS boolean
    LANGUAGE sql IMMUTABLE
    AS $$
  SELECT EXISTS (SELECT 1 FROM dict.users(p_name) LIMIT 1)
$$;


--
-- Name: llms(text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.llms(_name text DEFAULT NULL::text) RETURNS TABLE(llm_name character varying, llm_key text, llm_url text, llm_model character varying, llm_interface character varying)
    LANGUAGE sql IMMUTABLE ROWS 10 PARALLEL SAFE
    AS $$
  SELECT *
  FROM (VALUES
    ('Deepseek China', 'sk-AEq_f-GecHeiKIm_Sgd0HA', 'https://hubai.loe.gg/v1', 'deepseek-chat', 'OpenAI'),
    ('GPT4o China (US gate)', 'sk-oddqnbvvtiIqXpYufTc7XA', 'https://hubai.loe.gg/v1', 'gpt-4o-fallback', 'OpenAI'),
    ('Proxy Deepseek', 'sk-2e8pUANKk7FfTQ9nhLzcpSThBOjLMez6', 'https://api.proxyapi.ru/deepseek', 'deepseek-chat', 'OpenAI'),
    ('AI Tunnel Deepseek', 'sk-aitunnel-fNkRqnAFlSftNo1cZghylFWzrP6t4R2Q', 'https://api.aitunnel.ru/v1/', 'deepseek-chat', 'OpenAI'),
    ('AI Tunnel gpt-4o', 'sk-aitunnel-fNkRqnAFlSftNo1cZghylFWzrP6t4R2Q', 'https://api.aitunnel.ru/v1/', 'gpt-4o', 'OpenAI'),
    ('GigaChat', 'NWVhNzVmNDktNjM0YS00Mjc3LWJjMzMtYTM1MDU0YjExNjFiOmVmNWUzM2I2LWYyZDQtNGNiZS04MDY0LWUxOTEzZDgwOGY3NA==', 'https://gigachat.devices.sberbank.ru/api/v1', 'GigaChat', 'GigaChat'),
    ('Local QWEN', 'no key', 'https://hubai.loe.gg/v1', 'local-llm', 'requests'),
    ('AMD Deepseek', 'sk-ede17a0facfe4d02b1aba39e65427761', 'https://llama.sndi.my/api/chat/completions', './DeepSeek-R1-UD-Q2_K_XL.gguf', 'httpx'),
    ('AMD google/gemma-3', 'sk-ede17a0facfe4d02b1aba39e65427761', 'https://llama.sndi.my/api/chat/completions', 'google/gemma-3-27b-it', 'httpx'),
    ('AMD QWEN', 'sk-ede17a0facfe4d02b1aba39e65427761', 'https://llama.sndi.my/api/chat/completions', 'Qwen3-235B-A22B-Instruct../model/Qwen3', 'httpx')
  ) AS v(llm_name, llm_key, llm_url, llm_model, llm_interface)
  WHERE _name IS NULL OR v.llm_name = _name;
$$;


--
-- Name: prompt_keys(text, text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.prompt_keys(_key text DEFAULT NULL::text, _q text DEFAULT NULL::text) RETURNS TABLE(prompt_key_key text, prompt_key_description text)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  WITH base AS (
    SELECT * FROM dict.prompt_keys_base(_key, _q)
  ),
  extra AS (
    SELECT *
    FROM (VALUES
      ('archi'::text, 'запрос архитектора'::text),
      ('prog' ::text, 'запрос программиста'::text)
    ) AS v(prompt_key_key, prompt_key_description)
    WHERE (_key IS NULL OR v.prompt_key_key = _key)
      AND (_q   IS NULL OR v.prompt_key_key ILIKE '%'||_q||'%' OR v.prompt_key_description ILIKE '%'||_q||'%')
  ),
  unioned AS (
    SELECT 1 AS pri, prompt_key_key, prompt_key_description FROM base
    UNION ALL
    SELECT 2 AS pri, prompt_key_key, prompt_key_description FROM extra
  )
  SELECT prompt_key_key, prompt_key_description
  FROM (
    SELECT DISTINCT ON (prompt_key_key) *
    FROM unioned
    ORDER BY prompt_key_key, pri   -- берём сначала из base (pri=1)
  ) s
  ORDER BY prompt_key_key
$$;


--
-- Name: prompt_keys_base(text, text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.prompt_keys_base(_key text DEFAULT NULL::text, _q text DEFAULT NULL::text) RETURNS TABLE(prompt_key_key text, prompt_key_description text)
    LANGUAGE sql IMMUTABLE PARALLEL SAFE
    AS $$
  -- пустой набор
  SELECT v.prompt_key_key, v.prompt_key_description
  FROM (VALUES (NULL::text, NULL::text)) AS v(prompt_key_key, prompt_key_description)
  WHERE 1=0
$$;


--
-- Name: users(text); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.users(_name text DEFAULT NULL::text) RETURNS TABLE(user_user text, user_id integer, user_name text)
    LANGUAGE plpgsql IMMUTABLE
    AS $$
BEGIN
    RETURN QUERY
    SELECT v.user_user, v.user_id, v.user_name
    FROM (VALUES
        ('postgres'::text, 0, 'super user'::text)
    ) AS v(user_user, user_id, user_name)
    WHERE (_name IS NULL OR v.user_user = _name)
      AND v.user_user IS NOT NULL;
END;
$$;


--
-- Name: v_artifact_kinds_delete(); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.v_artifact_kinds_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.delete_record(OLD.meta_id);
    RETURN OLD;
END;
$$;


--
-- Name: v_artifact_kinds_upsert(); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.v_artifact_kinds_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_meta_id uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Проверка обязательных полей
        IF NEW.artifact_kind_code IS NULL THEN
            RAISE EXCEPTION 'artifact_kind_code is required';
        END IF;
        IF NEW.artifact_kind_name IS NULL THEN
            RAISE EXCEPTION 'artifact_kind_name is required';
        END IF;

        -- Проверка на дубли
        PERFORM 1 FROM dict.t_kinds
        WHERE kind_code = NEW.artifact_kind_code
           OR kind_name = NEW.artifact_kind_name;
        IF FOUND THEN
            RAISE EXCEPTION 'artifact_kind_code or artifact_kind_name already exists';
        END IF;

        -- Создаём meta_id
        v_meta_id := public.create_record();

        -- Вставка в таблицу
        INSERT INTO dict.t_kinds (meta_id, kind_code, kind_name)
        VALUES (v_meta_id, NEW.artifact_kind_code, NEW.artifact_kind_name);

        -- Возвращаем meta_id в результат
        NEW.meta_id := v_meta_id;
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        -- Запрещаем менять meta_id
        IF NEW.meta_id IS DISTINCT FROM OLD.meta_id THEN
            RAISE EXCEPTION 'meta_id cannot be changed';
        END IF;

        -- Обновляем мета-информацию
        PERFORM public.update_record(OLD.meta_id);

        -- Обновляем запись
        UPDATE dict.t_kinds
        SET 
            kind_code = COALESCE(NEW.artifact_kind_code, kind_code),
            kind_name = COALESCE(NEW.artifact_kind_name, kind_name)
        WHERE meta_id = OLD.meta_id;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: v_artifact_subkinds_delete(); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.v_artifact_subkinds_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.delete_record(OLD.meta_id);
    RETURN OLD;
END;
$$;


--
-- Name: v_artifact_subkinds_upsert(); Type: FUNCTION; Schema: dict; Owner: -
--

CREATE FUNCTION dict.v_artifact_subkinds_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_kind_meta_id uuid;
    v_meta_id      uuid;
BEGIN
    -- Определяем kind_meta_id
    IF TG_OP = 'INSERT' THEN
        -- По коду или имени вида
        IF NEW.artifact_kind_code IS NOT NULL THEN
            SELECT k.meta_id INTO v_kind_meta_id
            FROM dict.t_kinds k
            JOIN public.v_record_meta m ON m.id = k.meta_id
            WHERE k.kind_code = NEW.artifact_kind_code
              AND m.deleted_at IS NULL;
        ELSIF NEW.artifact_kind_name IS NOT NULL THEN
            SELECT k.meta_id INTO v_kind_meta_id
            FROM dict.t_kinds k
            JOIN public.v_record_meta m ON m.id = k.meta_id
            WHERE k.kind_name = NEW.artifact_kind_name
              AND m.deleted_at IS NULL;
        END IF;

        IF v_kind_meta_id IS NULL THEN
            RAISE EXCEPTION 'Cannot resolve artifact_kind: code=% or name=% not found or deleted',
                NEW.artifact_kind_code, NEW.artifact_kind_name;
        END IF;
    ELSIF TG_OP = 'UPDATE' THEN
        -- При обновлении: если меняется kind, ищем по коду/имени
        IF (NEW.artifact_kind_code IS NOT NULL AND NEW.artifact_kind_code IS DISTINCT FROM OLD.artifact_kind_code)
           OR (NEW.artifact_kind_name IS NOT NULL AND NEW.artifact_kind_name IS DISTINCT FROM OLD.artifact_kind_name)
        THEN
            IF NEW.artifact_kind_code IS NOT NULL THEN
                SELECT k.meta_id INTO v_kind_meta_id
                FROM dict.t_kinds k
                JOIN public.v_record_meta m ON m.id = k.meta_id
                WHERE k.kind_code = NEW.artifact_kind_code
                  AND m.deleted_at IS NULL;
            ELSIF NEW.artifact_kind_name IS NOT NULL THEN
                SELECT k.meta_id INTO v_kind_meta_id
                FROM dict.t_kinds k
                JOIN public.v_record_meta m ON m.id = k.meta_id
                WHERE k.kind_name = NEW.artifact_kind_name
                  AND m.deleted_at IS NULL;
            END IF;

            IF v_kind_meta_id IS NULL THEN
                RAISE EXCEPTION 'Cannot resolve new artifact_kind: code=% or name=% not found or deleted',
                    NEW.artifact_kind_code, NEW.artifact_kind_name;
            END IF;
        ELSE
            -- Сохраняем старый kind_meta_id
            v_kind_meta_id := OLD.kind_meta_id;
        END IF;
    END IF;

    IF TG_OP = 'INSERT' THEN
        -- Проверка обязательных полей
        IF NEW.artifact_subkind_code IS NULL THEN
            RAISE EXCEPTION 'artifact_subkind_code is required';
        END IF;
        IF NEW.artifact_subkind_name IS NULL THEN
            RAISE EXCEPTION 'artifact_subkind_name is required';
        END IF;

        -- Проверка дублей
        PERFORM 1 FROM dict.t_sub_kinds s
        JOIN public.v_record_meta m ON m.id = s.meta_id
        WHERE (s.sub_kind_code = NEW.artifact_subkind_code
            OR (s.sub_kind_name = NEW.artifact_subkind_name AND s.kind_meta_id = v_kind_meta_id))
          AND m.deleted_at IS NULL;
        IF FOUND THEN
            RAISE EXCEPTION 'artifact_subkind_code or (name+kind) already exists';
        END IF;

        -- Создаём meta_id
        v_meta_id := public.create_record();

        -- Вставляем
        INSERT INTO dict.t_sub_kinds (meta_id, sub_kind_code, sub_kind_name, kind_meta_id)
        VALUES (v_meta_id, NEW.artifact_subkind_code, NEW.artifact_subkind_name, v_kind_meta_id);

        NEW.meta_id := v_meta_id;
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        -- Запрещаем менять meta_id
        IF NEW.meta_id IS DISTINCT FROM OLD.meta_id THEN
            RAISE EXCEPTION 'meta_id cannot be changed';
        END IF;

        PERFORM public.update_record(OLD.meta_id);

        UPDATE dict.t_sub_kinds
        SET 
            sub_kind_code = COALESCE(NEW.artifact_subkind_code, sub_kind_code),
            sub_kind_name = COALESCE(NEW.artifact_subkind_name, sub_kind_name),
            kind_meta_id  = COALESCE(v_kind_meta_id, kind_meta_id)
        WHERE meta_id = OLD.meta_id;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: apply_artifact_defaults(text, jsonb); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.apply_artifact_defaults(p_subkind_code text, p_content_json jsonb) RETURNS jsonb
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_defaults jsonb;
BEGIN
  SELECT subkind_defaults INTO v_defaults
  FROM dict.artifact_subkinds
  WHERE artifact_subkind_code = p_subkind_code;

  IF v_defaults IS NULL OR p_content_json IS NULL THEN
    RETURN p_content_json;
  END IF;

  -- "defaults ⊙ content" (content имеет приоритет)
  RETURN COALESCE(v_defaults, '{}'::jsonb) || p_content_json;
END $$;


--
-- Name: create_record(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.create_record() RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_id uuid;
BEGIN
    INSERT INTO public.v_record_meta (is_del)
    VALUES (FALSE)
    RETURNING id INTO new_id;

    RETURN new_id;
END;
$$;


--
-- Name: delete_record(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.delete_record(p_meta_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    affected integer;
BEGIN
    -- Работаем через ВЬЮ, чтобы соблюсти общий контракт
    UPDATE public.v_record_meta
       SET is_del = true,
           updated = now()
     WHERE id = p_meta_id
       AND is_del = false;  -- не трогаем уже «удалённые»

    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected = 0 THEN
        RAISE EXCEPTION 'record_meta with id % not found or already soft-deleted', p_meta_id
            USING ERRCODE = 'P0002'; -- no_data_found
    END IF;

    RETURN p_meta_id;
END;
$$;


--
-- Name: dump_table_ddl(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dump_table_ddl(target_table_name text) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    result text := '';
    table_oid oid;
    schema_name text;
    rec_view record;
    rec_trigger record;
BEGIN
    -- Получаем OID и схему таблицы
    SELECT c.oid, n.nspname 
    INTO table_oid, schema_name 
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = target_table_name 
      AND c.relkind = 'r';

    IF table_oid IS NULL THEN
        RETURN 'Таблица ' || target_table_name || ' не найдена';
    END IF;

    -- 1. DDL самой таблицы через pg_dump
    result := result || '-- TABLE: ' || schema_name || '.' || target_table_name || E'\n';
    result := result || format(
        'CREATE TABLE %I.%I (%s);',
        schema_name,
        target_table_name,
        (SELECT array_to_string(
            array_agg(
                format('%I %s%s%s',
                    a.attname,
                    format_type(a.atttypid, a.atttypmod),
                    CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END,
                    CASE WHEN d.adbin IS NOT NULL THEN ' DEFAULT ' || pg_get_expr(d.adbin, d.adrelid) ELSE '' END
                )
            ), ', '
        )
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
        WHERE a.attrelid = table_oid 
          AND a.attnum > 0 
          AND NOT a.attisdropped)
    ) || E'\n\n';

    -- 2. Поиск представлений, которые используют эту таблицу
    FOR rec_view IN
        SELECT DISTINCT v.viewname::text as view_name,
               v.definition as view_def
        FROM pg_views v
        WHERE v.definition ILIKE '%' || target_table_name || '%'
          AND v.schemaname = schema_name
    LOOP
        result := result || '-- VIEW: ' || rec_view.view_name || E'\n';
        result := result || 'CREATE VIEW ' || rec_view.view_name || ' AS ' || rec_view.view_def || ';' || E'\n\n';
    END LOOP;

    -- 3. Триггеры таблицы
    FOR rec_trigger IN
        SELECT tgname as trigger_name,
               pg_get_triggerdef(oid) as trigger_def
        FROM pg_trigger
        WHERE tgrelid = table_oid
    LOOP
        result := result || '-- TRIGGER: ' || rec_trigger.trigger_name || E'\n';
        result := result || rec_trigger.trigger_def || ';' || E'\n\n';
    END LOOP;

    RETURN result;
END;
$$;


--
-- Name: dump_table_ddl_complete(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.dump_table_ddl_complete(target_table_name text) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    result text := '';
    schema_name text;
    rec record;
BEGIN
    -- Получаем схему таблицы
    SELECT n.nspname INTO schema_name 
    FROM pg_class c
    JOIN pg_namespace n ON c.relnamespace = n.oid
    WHERE c.relname = target_table_name AND c.relkind = 'r';

    IF schema_name IS NULL THEN
        RETURN 'Таблица ' || target_table_name || ' не найдена';
    END IF;

    -- 1. DDL таблицы
    result := result || '-- TABLE: ' || schema_name || '.' || target_table_name || E'\n';
    
    -- Формируем CREATE TABLE вручную
    result := result || format('CREATE TABLE %I.%I (', schema_name, target_table_name);
    
    -- Получаем столбцы таблицы
    FOR rec IN
        SELECT 
            a.attname,
            format_type(a.atttypid, a.atttypmod) as data_type,
            CASE WHEN a.attnotnull THEN ' NOT NULL' ELSE '' END as not_null,
            COALESCE(pg_get_expr(d.adbin, d.adrelid), '') as default_value
        FROM pg_attribute a
        LEFT JOIN pg_attrdef d ON a.attrelid = d.adrelid AND a.attnum = d.adnum
        WHERE a.attrelid = (schema_name || '.' || target_table_name)::regclass
          AND a.attnum > 0 
          AND NOT a.attisdropped
        ORDER BY a.attnum
    LOOP
        result := result || E'\n    ' || quote_ident(rec.attname) || ' ' || rec.data_type || rec.not_null;
        IF rec.default_value != '' THEN
            result := result || ' DEFAULT ' || rec.default_value;
        END IF;
        result := result || ',';
    END LOOP;
    
    -- Убираем последнюю запятую
    result := substring(result from 1 for length(result) - 1);
    result := result || E'\n);' || E'\n\n';

    -- 2. Индексы таблицы
    FOR rec IN
        SELECT pg_get_indexdef(i.indexrelid) as index_def
        FROM pg_index i
        JOIN pg_class c ON c.oid = i.indrelid
        WHERE c.relname = target_table_name
          AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = schema_name)
    LOOP
        result := result || rec.index_def || ';' || E'\n';
    END LOOP;
    result := result || E'\n';

    -- 3. Триггеры таблицы (ищем триггеры, связанные с этой таблицей)
    FOR rec IN
        SELECT 
            t.tgname as trigger_name,
            pg_get_triggerdef(t.oid) as trigger_def
        FROM pg_trigger t
        JOIN pg_class c ON t.tgrelid = c.oid
        WHERE c.relname = target_table_name
          AND c.relnamespace = (SELECT oid FROM pg_namespace WHERE nspname = schema_name)
    LOOP
        result := result || '-- TRIGGER: ' || rec.trigger_name || E'\n';
        result := result || rec.trigger_def || ';' || E'\n\n';
    END LOOP;

    -- 4. Представления, зависящие от этой таблицы
    FOR rec IN
        SELECT 
            schemaname || '.' || viewname as view_name,
            'CREATE OR REPLACE VIEW ' || schemaname || '.' || viewname || ' AS ' || definition as view_def
        FROM pg_views
        WHERE definition ILIKE '%' || target_table_name || '%'
          AND schemaname = schema_name
    LOOP
        result := result || '-- VIEW: ' || rec.view_name || E'\n';
        result := result || rec.view_def || ';' || E'\n\n';
    END LOOP;

    RETURN result;
END;
$$;


--
-- Name: ensure_prompt_ids(text, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.ensure_prompt_ids(p_pkey text, p_lang text, p_variant text, OUT key_id bigint, OUT lang_id bigint, OUT variant_id bigint) RETURNS record
    LANGUAGE plpgsql
    AS $$
BEGIN
  INSERT INTO prompt_key(pkey) VALUES (p_pkey)
    ON CONFLICT (pkey) DO UPDATE SET pkey = EXCLUDED.pkey
    RETURNING id INTO key_id;

  INSERT INTO prompt_lang(code) VALUES (p_lang)
    ON CONFLICT (code) DO UPDATE SET code = EXCLUDED.code
    RETURNING id INTO lang_id;

  INSERT INTO prompt_variant(name) VALUES (p_variant)
    ON CONFLICT (name) DO UPDATE SET name = EXCLUDED.name
    RETURNING id INTO variant_id;
END; $$;


--
-- Name: exec_sql_script(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.exec_sql_script(p_sql text) RETURNS void
    LANGUAGE plpgsql
    AS $_$
DECLARE
  i int := 1;
  len int := length(p_sql);
  ch text;
  stmt text := '';

  in_squote boolean := false;
  in_dquote boolean := false;
  in_line_comment boolean := false;
  in_block_comment boolean := false;
  in_dollar boolean := false;
  dollar_tag text := NULL;

  ahead text;
  m text[];
BEGIN
  WHILE i <= len LOOP
    ch := substr(p_sql, i, 1);

    IF in_block_comment THEN
      stmt := stmt || ch;
      IF ch = '*' AND i < len AND substr(p_sql, i+1, 1) = '/' THEN
        stmt := stmt || '/';
        in_block_comment := false;
        i := i + 2; CONTINUE;
      END IF;
      i := i + 1; CONTINUE;
    END IF;

    IF in_squote THEN
      stmt := stmt || ch;
      IF ch = '''' THEN
        IF i < len AND substr(p_sql, i+1, 1) = '''' THEN
          stmt := stmt || ''''; i := i + 2; CONTINUE;
        ELSE
          in_squote := false; i := i + 1; CONTINUE;
        END IF;
      END IF;
      i := i + 1; CONTINUE;
    END IF;

    IF in_dquote THEN
      stmt := stmt || ch;
      IF ch = '"' THEN
        IF i < len AND substr(p_sql, i+1, 1) = '"' THEN
          stmt := stmt || '"'; i := i + 2; CONTINUE;
        ELSE
          in_dquote := false; i := i + 1; CONTINUE;
        END IF;
      END IF;
      i := i + 1; CONTINUE;
    END IF;

    IF in_dollar THEN
      stmt := stmt || ch;
      IF ch = '$' THEN
        IF length(stmt) >= length(dollar_tag) AND right(stmt, length(dollar_tag)) = dollar_tag THEN
          in_dollar := false;
          dollar_tag := NULL;
        END IF;
      END IF;
      i := i + 1; CONTINUE;
    END IF;

    IF in_line_comment THEN
      stmt := stmt || ch;
      IF ch = E'\n' THEN
        in_line_comment := false;
      END IF;
      i := i + 1; CONTINUE;
    END IF;

    IF ch = '''' THEN
      in_squote := true; stmt := stmt || ch; i := i + 1; CONTINUE;
    ELSIF ch = '"' THEN
      in_dquote := true; stmt := stmt || ch; i := i + 1; CONTINUE;
    ELSIF ch = '-' AND i < len AND substr(p_sql, i+1, 1) = '-' THEN
      in_line_comment := true; stmt := stmt || '--'; i := i + 2; CONTINUE;
    ELSIF ch = '/' AND i < len AND substr(p_sql, i+1, 1) = '*' THEN
      in_block_comment := true; stmt := stmt || '/*'; i := i + 2; CONTINUE;
    ELSIF ch = '$' THEN
      ahead := substr(p_sql, i);
      SELECT regexp_match(ahead, '^\$([A-Za-z_][A-Za-z0-9_]*)?\$') INTO m;
      IF m IS NOT NULL THEN
        in_dollar := true;
        IF m[1] IS NULL THEN
          dollar_tag := '$$';
        ELSE
          dollar_tag := '$' || m[1] || '$';
        END IF;
        stmt := stmt || dollar_tag;
        i := i + length(dollar_tag);
        CONTINUE;
      END IF;
    END IF;

    IF ch = ';' THEN
      stmt := btrim(stmt);
      IF stmt <> '' THEN
        EXECUTE stmt;
      END IF;
      stmt := '';
      i := i + 1; CONTINUE;
    END IF;

    stmt := stmt || ch;
    i := i + 1;
  END LOOP;

  stmt := btrim(stmt);
  IF stmt <> '' THEN
    EXECUTE stmt;
  END IF;
END;
$_$;


--
-- Name: export_table_schema(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.export_table_schema(p_table text) RETURNS text
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_schema text := 'public';
    v_table  text := p_table;
    v_sql    text := '';
    v_line   text;
BEGIN
    -- 1. CREATE TABLE (берём готовое выражение из pg_get_tabledef)
    SELECT pg_get_tabledef(c.oid)
    INTO v_line
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE c.relname = v_table
      AND n.nspname = v_schema
      AND c.relkind = 'r'; -- обычная таблица
    IF v_line IS NOT NULL THEN
        v_sql := v_sql || v_line || E';\n\n';
    END IF;

    -- 2. VIEW, которые ссылаются на таблицу
    FOR v_line IN
        SELECT pg_get_viewdef(c.oid, true)
        FROM pg_class c
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relkind = 'v'
          AND n.nspname = v_schema
          AND pg_get_viewdef(c.oid, true) LIKE '%' || v_table || '%'
    LOOP
        v_sql := v_sql || 'CREATE OR REPLACE VIEW ' || v_line || E';\n\n';
    END LOOP;

    -- 3. Триггеры и их функции
    FOR v_line IN
        SELECT pg_get_triggerdef(t.oid, true)
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = v_table
          AND n.nspname = v_schema
          AND NOT t.tgisinternal
    LOOP
        v_sql := v_sql || v_line || E';\n\n';
    END LOOP;

    -- 4. Функции-триггеры (их текст)
    FOR v_line IN
        SELECT pg_get_functiondef(p.oid)
        FROM pg_proc p
        JOIN pg_trigger t ON t.tgfoid = p.oid
        JOIN pg_class c ON c.oid = t.tgrelid
        WHERE c.relname = v_table
    LOOP
        v_sql := v_sql || v_line || E';\n\n';
    END LOOP;

    RETURN v_sql;
END;
$$;


--
-- Name: gen_child_view_with_parent(text, text, text, text, text, text, integer, text, integer, integer); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gen_child_view_with_parent(p_child_base text, p_parent_base text, p_fk_col text, p_parent_cols text, p_lookup_cols text DEFAULT NULL::text, p_parent_lookup_col text DEFAULT NULL::text, p_make_drop integer DEFAULT 0, p_schema text DEFAULT 'public'::text, p_apply integer DEFAULT 0, p_cascade_parent_delete integer DEFAULT 0) RETURNS text
    LANGUAGE plpgsql
    AS $_$
DECLARE
    -- имена объектов
    child_tb   text := 'tb__' || p_child_base;
    child_view text := 'v__'  || p_child_base;
    parent_tb  text := 'tb__' || p_parent_base;

    fn_ins text := child_view || '_insert';
    fn_upd text := child_view || '_update';
    fn_del text := child_view || '_delete';

    trg_ins text := 'trg_' || child_view || '_ins';
    trg_upd text := 'trg_' || child_view || '_upd';
    trg_del text := 'trg_' || child_view || '_del';

    ddl text := '';

    -- FK: нормализация (логическое -> физическое по префиксу дочерней сущности)
    fk_col        text := btrim(p_fk_col);
    child_base_s  text := CASE WHEN right(p_child_base,1)='s' AND length(p_child_base)>1
                               THEN substr(p_child_base,1,length(p_child_base)-1)
                               ELSE p_child_base END;
    child_prefix  text := lower(child_base_s) || '_';
    fk_col_pref   text;

    -- дочерние поля
    child_cols_select text := '';  -- ', t.%I' для SELECT
    child_cols_only   text := '';  -- ', %I' без meta_id и без FK
    child_cols_set    text := '';  -- ', %I = NEW.%I' для UPDATE дочери
    child_vals_only   text := '';  -- ', NEW.%I' для INSERT дочери

    -- родительские поля
    parent_cols_arr   text[];
    parent_cols_norm  text := '';  -- ', p.%I' для SELECT
    parent_cols_set   text := '';  -- ', %I = NEW.%I' для UPDATE родителя
    parent_cols_list  text := '';  -- ', %I'  для INSERT родителя
    parent_vals_list  text := '';  -- ', NEW.%I' для INSERT родителя

    -- поиск родителя
    use_single_lookup boolean := (p_parent_lookup_col IS NOT NULL AND btrim(p_parent_lookup_col) <> '');
    parent_lookup_col text := NULL;

    lookup_cols_arr     text[];     -- legacy
    lookup_cond_legacy  text := ''; -- 'col IS NOT NULL AND p.col = NEW.col ...'
    lookup_any_present  text := ''; -- 'NEW.col IS NOT NULL OR ...'

    -- meta-поля (публичные)
    meta_fields_public text := '';
    meta_field_name    text;

    rec record;

    -- для p_apply
    create_view_sql   text;
    create_fn_ins_sql text;
    create_fn_upd_sql text;
    create_fn_del_sql text;

    child_update_set text;

    -- тексты для сообщений (без %)
    amb_prefix text;        -- 'Ambiguous parent by <col>, '
    amb_suffix text;        -- ' records match in <schema>.<parent_tb>'
    need_either_msg text;   -- 'Either NEW.<fk> or NEW.<lookup> must be provided'
BEGIN
    -- Проверка наличия таблиц
    PERFORM 1 FROM information_schema.tables WHERE table_schema=p_schema AND table_name=child_tb;
    IF NOT FOUND THEN RAISE EXCEPTION 'Child table %.% not found', p_schema, child_tb; END IF;

    PERFORM 1 FROM information_schema.tables WHERE table_schema=p_schema AND table_name=parent_tb;
    IF NOT FOUND THEN RAISE EXCEPTION 'Parent table %.% not found', p_schema, parent_tb; END IF;

    -- Нормализация FK: если точного имени нет — пробуем физическое с префиксом
    PERFORM 1 FROM information_schema.columns
     WHERE table_schema=p_schema AND table_name=child_tb AND column_name=fk_col;
    IF NOT FOUND THEN
        fk_col_pref := child_prefix
                     || regexp_replace(lower(fk_col), '\s+', '_', 'g');
        fk_col_pref := regexp_replace(fk_col_pref, '[^a-z0-9_]', '_', 'g');
        fk_col_pref := regexp_replace(fk_col_pref, '_{2,}', '_', 'g');

        PERFORM 1 FROM information_schema.columns
         WHERE table_schema=p_schema AND table_name=child_tb AND column_name=fk_col_pref;
        IF FOUND THEN
            fk_col := fk_col_pref;
        ELSE
            RAISE EXCEPTION 'Child FK column "%" not found in %.% (also tried "%")',
              p_fk_col, p_schema, child_tb, fk_col_pref;
        END IF;
    END IF;

    -- Дочерние колонки (кроме meta_id)
    FOR rec IN
        SELECT column_name
        FROM information_schema.columns
        WHERE table_schema=p_schema AND table_name=child_tb
          AND column_name <> 'meta_id'
        ORDER BY ordinal_position
    LOOP
        child_cols_select := child_cols_select || format(', t.%I', rec.column_name);
        IF rec.column_name <> fk_col THEN
            child_cols_only := child_cols_only || format(', %I', rec.column_name);
            child_cols_set  := child_cols_set  || format(', %I = NEW.%I', rec.column_name, rec.column_name);
        END IF;
    END LOOP;

    -- Значения для INSERT ребёнка
    IF child_cols_only <> '' THEN
        child_vals_only := replace(child_cols_only, ', ', ', NEW.');
    ELSE
        child_vals_only := '';
    END IF;

    -- Родительские колонки + валидация lookup
    parent_cols_arr := string_to_array(coalesce(p_parent_cols,''), ',');
    IF array_length(parent_cols_arr,1) IS NULL THEN
        RAISE EXCEPTION 'p_parent_cols must not be empty';
    END IF;

    IF use_single_lookup THEN
        parent_lookup_col := btrim(p_parent_lookup_col);
        PERFORM 1 FROM information_schema.columns
         WHERE table_schema=p_schema AND table_name=parent_tb AND column_name=parent_lookup_col;
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parent lookup column "%" not found in %.%', parent_lookup_col, p_schema, parent_tb;
        END IF;

        -- гарантируем наличие lookup-колонки в parent_cols_arr
        IF NOT EXISTS (
            SELECT 1 FROM unnest(parent_cols_arr) AS u(c) WHERE btrim(u.c)=parent_lookup_col
        ) THEN
            parent_cols_arr := array_append(parent_cols_arr, parent_lookup_col);
        END IF;
    END IF;

    FOR i IN 1..array_length(parent_cols_arr,1) LOOP
        parent_cols_arr[i] := btrim(parent_cols_arr[i]);
        PERFORM 1 FROM information_schema.columns
         WHERE table_schema=p_schema AND table_name=parent_tb AND column_name=parent_cols_arr[i];
        IF NOT FOUND THEN
            RAISE EXCEPTION 'Parent column "%" not found in %.%', parent_cols_arr[i], p_schema, parent_tb;
        END IF;

        parent_cols_norm := parent_cols_norm || format(', p.%I', parent_cols_arr[i]);
        parent_cols_set  := parent_cols_set  || format(', %I = NEW.%I', parent_cols_arr[i], parent_cols_arr[i]);
        parent_cols_list := parent_cols_list || format(', %I', parent_cols_arr[i]);
        parent_vals_list := parent_vals_list || format(', NEW.%I', parent_cols_arr[i]);
    END LOOP;

    -- Legacy наборный поиск
    IF NOT use_single_lookup THEN
        IF p_lookup_cols IS NULL OR btrim(p_lookup_cols) = '' THEN
            lookup_cols_arr := ARRAY[parent_cols_arr[1]];
        ELSE
            lookup_cols_arr := string_to_array(p_lookup_cols, ',');
            FOR i IN 1..array_length(lookup_cols_arr,1) LOOP
                lookup_cols_arr[i] := btrim(lookup_cols_arr[i]);
                PERFORM 1 FROM information_schema.columns
                 WHERE table_schema=p_schema AND table_name=parent_tb AND column_name=lookup_cols_arr[i];
                IF NOT FOUND THEN
                    RAISE EXCEPTION 'Lookup column "%" not found in %.%', lookup_cols_arr[i], p_schema, parent_tb;
                END IF;
            END LOOP;
        END IF;

        FOR i IN 1..array_length(lookup_cols_arr,1) LOOP
            lookup_cond_legacy := lookup_cond_legacy ||
              CASE WHEN lookup_cond_legacy='' THEN format('%1$I IS NOT NULL AND p.%1$I = NEW.%1$I', lookup_cols_arr[i])
                   ELSE format(' AND %1$I IS NOT NULL AND p.%1$I = NEW.%1$I', lookup_cols_arr[i]) END;

            lookup_any_present := lookup_any_present ||
              CASE WHEN lookup_any_present='' THEN format('NEW.%I IS NOT NULL', lookup_cols_arr[i])
                   ELSE format(' OR NEW.%I IS NOT NULL', lookup_cols_arr[i]) END;
        END LOOP;
    END IF;

    -- meta-поля (публичные)
    FOR meta_field_name IN
        SELECT a.attname::text
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'v_record_meta' AND n.nspname = p_schema
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> ALL(ARRAY['id','created','updated','is_del'])
        ORDER BY a.attnum
    LOOP
        meta_fields_public := meta_fields_public ||
          CASE WHEN meta_fields_public='' THEN format('m.%I', meta_field_name)
               ELSE format(', m.%I', meta_field_name) END;
    END LOOP;

    -- DROP'ы
    IF p_make_drop = 1 THEN
        ddl := ddl
          || format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_ins, p_schema, child_view) || E'\n'
          || format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_upd, p_schema, child_view) || E'\n'
          || format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_del, p_schema, child_view) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_ins) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_upd) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_del) || E'\n'
          || format('DROP VIEW IF EXISTS %I.%I CASCADE;', p_schema, child_view) || E'\n\n';
    END IF;

    -- VIEW
    create_view_sql := format(
      'CREATE OR REPLACE VIEW %I.%I AS
         SELECT t.meta_id%s%s%s
           FROM %I.%I t
           JOIN %I.%I p ON p.meta_id = t.%I
           JOIN %I.v_record_meta m ON m.id = t.meta_id;',
      p_schema, child_view,
      child_cols_select,
      parent_cols_norm,
      CASE WHEN meta_fields_public<>'' THEN ', '||meta_fields_public ELSE '' END,
      p_schema, child_tb,
      p_schema, parent_tb, fk_col,
      p_schema
    );
    ddl := ddl || create_view_sql || E'\n\n';

    -- Сообщения для EXCEPTION (без %)
    IF use_single_lookup THEN
        amb_prefix := 'Ambiguous parent by '||parent_lookup_col||', ';
        amb_suffix := ' records match in '||p_schema||'.'||parent_tb;
        need_either_msg := 'Either NEW.'||fk_col||' or NEW.'||parent_lookup_col||' must be provided';
    END IF;

    ----------------------------------------------------------------
    -- INSERT FN (single-lookup / legacy)
    ----------------------------------------------------------------
    IF use_single_lookup THEN
      create_fn_ins_sql := format($f$
CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    x_child uuid;
    x_parent uuid;
    cnt int;
BEGIN
    IF NEW.%I IS NOT NULL THEN
        x_parent := NEW.%I;
    ELSE
        IF NEW.%I IS NOT NULL THEN
            SELECT count(*) INTO cnt
            FROM %I.%I
            WHERE %I = NEW.%I;

            IF cnt = 0 THEN
                x_parent := %I.create_record();
                INSERT INTO %I.%I (meta_id%s) VALUES (x_parent%s);
            ELSIF cnt = 1 THEN
                SELECT meta_id INTO x_parent
                FROM %I.%I
                WHERE %I = NEW.%I
                LIMIT 1;
            ELSE
                RAISE EXCEPTION USING MESSAGE = %L || cnt::text || %L;
            END IF;
        ELSE
            RAISE EXCEPTION USING MESSAGE = %L;
        END IF;
    END IF;

    x_child := %I.create_record();
    INSERT INTO %I.%I (meta_id, %I%s) VALUES (x_child, x_parent%s);

    RETURN NEW;
END$$;
$f$,
        p_schema, fn_ins,
        fk_col, fk_col,
        parent_lookup_col,
        p_schema, parent_tb,
        parent_lookup_col, parent_lookup_col,
        p_schema,
        p_schema, parent_tb, parent_cols_list, parent_vals_list,
        p_schema, parent_tb, parent_lookup_col, parent_lookup_col,
        amb_prefix, amb_suffix,
        need_either_msg,
        p_schema,
        p_schema, child_tb, fk_col, child_cols_only, child_vals_only
      );
    ELSE
      -- legacy: поиск по набору полей
      create_fn_ins_sql := format($f$
CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    x_child uuid;
    x_parent uuid;
BEGIN
    IF NEW.%I IS NOT NULL THEN
        x_parent := NEW.%I;
    ELSE
        SELECT p.meta_id INTO x_parent
        FROM %I.%I p
        WHERE %s
        LIMIT 1;

        IF x_parent IS NULL THEN
            x_parent := %I.create_record();
            INSERT INTO %I.%I (meta_id%s) VALUES (x_parent%s);
        END IF;
    END IF;

    x_child := %I.create_record();
    INSERT INTO %I.%I (meta_id, %I%s) VALUES (x_child, x_parent%s);

    RETURN NEW;
END$$;
$f$,
        p_schema, fn_ins,
        fk_col, fk_col,
        p_schema, parent_tb, lookup_cond_legacy,
        p_schema, p_schema, parent_tb, parent_cols_list, parent_vals_list,
        p_schema,
        p_schema, child_tb, fk_col, child_cols_only, child_vals_only
      );
    END IF;
    ddl := ddl || create_fn_ins_sql || E'\n\n';

    ----------------------------------------------------------------
    -- UPDATE FN (single-lookup / legacy)
    ----------------------------------------------------------------
    child_update_set := CASE
        WHEN child_cols_set <> '' THEN ltrim(child_cols_set, ', ') || ', ' || format('%I = new_parent', fk_col)
        ELSE format('%I = new_parent', fk_col)
    END;

    IF use_single_lookup THEN
      create_fn_upd_sql := format($f$
CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    new_parent uuid;
    cnt int;
BEGIN
    IF NEW.%I IS NOT NULL THEN
        new_parent := NEW.%I;
    ELSIF NEW.%I IS NOT NULL THEN
        SELECT count(*) INTO cnt
        FROM %I.%I
        WHERE %I = NEW.%I;

        IF cnt = 0 THEN
            new_parent := %I.create_record();
            INSERT INTO %I.%I (meta_id%s) VALUES (new_parent%s);
        ELSIF cnt > 1 THEN
            RAISE EXCEPTION USING MESSAGE = %L || cnt::text || %L;
        ELSE
            SELECT meta_id INTO new_parent
            FROM %I.%I
            WHERE %I = NEW.%I
            LIMIT 1;

            PERFORM %I.update_record(new_parent);
            UPDATE %I.%I SET %s WHERE meta_id = new_parent;
        END IF;
    ELSE
        new_parent := OLD.%I;
    END IF;

    PERFORM %I.update_record(OLD.meta_id);
    UPDATE %I.%I SET %s WHERE meta_id = OLD.meta_id;

    RETURN NEW;
END$$;
$f$,
        p_schema, fn_upd,
        fk_col, fk_col,
        parent_lookup_col,
        p_schema, parent_tb,
        parent_lookup_col, parent_lookup_col,
        p_schema, p_schema, parent_tb, parent_cols_list, parent_vals_list,
        amb_prefix, amb_suffix,
        p_schema, parent_tb, parent_lookup_col, parent_lookup_col,
        p_schema, p_schema, parent_tb, ltrim(parent_cols_set, ', '),
        fk_col,
        p_schema, p_schema, child_tb, child_update_set
      );
    ELSE
      create_fn_upd_sql := format($f$
CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
    new_parent uuid;
BEGIN
    IF NEW.%I IS NOT NULL THEN
        new_parent := NEW.%I;
    ELSIF %s THEN
        SELECT p.meta_id INTO new_parent
        FROM %I.%I p
        WHERE %s
        LIMIT 1;

        IF new_parent IS NULL THEN
            new_parent := %I.create_record();
            INSERT INTO %I.%I (meta_id%s) VALUES (new_parent%s);
        ELSE
            PERFORM %I.update_record(new_parent);
            UPDATE %I.%I SET %s WHERE meta_id = new_parent;
        END IF;
    ELSE
        new_parent := OLD.%I;
    END IF;

    PERFORM %I.update_record(OLD.meta_id);
    UPDATE %I.%I SET %s WHERE meta_id = OLD.meta_id;

    RETURN NEW;
END$$;
$f$,
        p_schema, fn_upd,
        fk_col, fk_col,
        COALESCE(NULLIF(lookup_any_present,''),'FALSE'),
        p_schema, parent_tb, lookup_cond_legacy,
        p_schema, p_schema, parent_tb, parent_cols_list, parent_vals_list,
        p_schema, parent_tb, ltrim(parent_cols_set, ', '),
        fk_col,
        p_schema, child_tb, child_update_set
      );
    END IF;
    ddl := ddl || create_fn_upd_sql || E'\n\n';

    -- DELETE FN
    create_fn_del_sql := format($f$
CREATE OR REPLACE FUNCTION %I.%I() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
    PERFORM %I.delete_record(OLD.meta_id);

    %s

    RETURN OLD;
END$$;
$f$,
      p_schema, fn_del,
      p_schema,
      CASE WHEN p_cascade_parent_delete = 1 THEN
        format($x$
DO $$
DECLARE cnt int;
BEGIN
  SELECT count(*) INTO cnt FROM %I.%I WHERE %I = OLD.%I AND meta_id <> OLD.meta_id;
  IF cnt = 0 THEN
    PERFORM %I.delete_record(OLD.%I);
  END IF;
END$$;$x$,
          p_schema, child_tb, fk_col, fk_col, p_schema, fk_col)
      ELSE 'NULL; -- no cascade'
      END
    );
    ddl := ddl || create_fn_del_sql || E'\n\n';

    -- Триггеры
ddl := ddl
  || format('CREATE TRIGGER %I INSTEAD OF INSERT ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
            trg_ins, p_schema, child_view, p_schema, fn_ins) || E'\n'
  || format('CREATE TRIGGER %I INSTEAD OF UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
            trg_upd, p_schema, child_view, p_schema, fn_upd) || E'\n'
  || format('CREATE TRIGGER %I INSTEAD OF DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
            trg_del, p_schema, child_view, p_schema, fn_del) || E'\n';

    -- На всякий случай схлопнуть серии кавычек
    ddl := regexp_replace(ddl, '("){2,}', '"', 'g');

    -- Применить по флагу
    IF p_apply = 1 THEN
        IF p_make_drop = 1 THEN
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_ins, p_schema, child_view);
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_upd, p_schema, child_view);
            EXECUTE format('DROP TRIGGER IF EXISTS %I ON %I.%I;', trg_del, p_schema, child_view);
            EXECUTE format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_ins);
            EXECUTE format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_upd);
            EXECUTE format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_del);
            EXECUTE format('DROP VIEW IF EXISTS %I.%I CASCADE;', p_schema, child_view);
        END IF;

        EXECUTE create_view_sql;
        EXECUTE create_fn_ins_sql;
        EXECUTE create_fn_upd_sql;
        EXECUTE create_fn_del_sql;

        EXECUTE format('CREATE TRIGGER %I INSTEAD OF INSERT ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                       trg_ins, p_schema, child_view, p_schema, fn_ins);
        EXECUTE format('CREATE TRIGGER %I INSTEAD OF UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                       trg_upd, p_schema, child_view, p_schema, fn_upd);
        EXECUTE format('CREATE TRIGGER %I INSTEAD OF DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                       trg_del, p_schema, child_view, p_schema, fn_del);
    END IF;

    RETURN ddl;
END;
$_$;


--
-- Name: gen_meta_ddl_v2(regclass, text, text, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gen_meta_ddl_v2(p_template_tb regclass, p_new_base text, p_fields text DEFAULT NULL::text, p_make_drop integer DEFAULT 0, p_join_key text DEFAULT 'id'::text, p_schema text DEFAULT 'public'::text) RETURNS text
    LANGUAGE plpgsql
    AS $_$
DECLARE
    ddl              text := '';
    template_tb_name text;
    new_tb           text;
    new_view         text;

    -- префикс для физических колонок (единственное число)
    new_base_s  text;
    new_prefix  text;

    -- сборка DDL
    create_table_sql text;
    view_user_cols   text := '';
    insert_cols      text := '';
    insert_vals      text := '';
    update_assign    text := '';

    -- парсер p_fields
    s           text; len int; i int; ch text;
    paren int := 0; in_squote boolean := false; in_dquote boolean := false;
    token text := ''; field_def text;
    logical_name text; field_spec text; has_nullness boolean;
    raw_name text; arr text[];

    -- контроль имён (логических и физических)
    names_seen   text := ',';    -- ',logical1,logical2,'
    phys_seen    text := ',';    -- ',phys1,phys2,'
    name_key     text;
    phys_base    text;
    phys_name    text;
    suffix       int;

    -- meta поля
    meta_field_name text;
    meta_fields     text := '';
    forbidden_fields text[] := ARRAY['id','created','updated','is_del'];

    -- функции/триггеры
    fn_ins text; fn_upd text; fn_del text;
    trg_ins text; trg_upd text; trg_del text;

    -- готовый процитированный алиас для SQL (через quote_ident)
    alias_sql text;
BEGIN
    IF p_new_base IS NULL OR btrim(p_new_base) = '' THEN
        RAISE EXCEPTION 'p_new_base is empty';
    END IF;

    SELECT relname::text INTO template_tb_name FROM pg_class WHERE oid = p_template_tb;
    IF template_tb_name IS NULL THEN
        RAISE EXCEPTION 'Template table not found';
    END IF;

    -- у шаблона должен быть meta_id
    PERFORM 1 FROM pg_attribute a WHERE a.attrelid = p_template_tb AND a.attname = 'meta_id';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Template "%" must contain column meta_id', template_tb_name;
    END IF;

    -- запрет meta_id в пользовательских полях
    IF p_fields IS NOT NULL AND p_fields ~* '(^|,)\s*meta_id(\s|,|$)' THEN
        RAISE EXCEPTION 'p_fields must not contain "meta_id"';
    END IF;

    new_tb   := 'tb__' || p_new_base;
    new_view := 'v__'  || p_new_base;

    fn_ins := new_view || '_insert';
    fn_upd := new_view || '_update';
    fn_del := new_view || '_delete';

    trg_ins := 'trg_' || new_view || '_ins';
    trg_upd := 'trg_' || new_view || '_upd';
    trg_del := 'trg_' || new_view || '_del';

    new_base_s := CASE WHEN right(p_new_base,1)='s' AND length(p_new_base)>1
                       THEN substr(p_new_base,1,length(p_new_base)-1)
                       ELSE p_new_base END;
    new_prefix := lower(new_base_s) || '_';

    ddl := ddl || format('-- generated by gen_meta_ddl_v2 on %s', now()::timestamptz) || E'\n\n';

    IF p_make_drop = 1 THEN
        ddl := ddl
          || format('DROP VIEW IF EXISTS %I.%I CASCADE;', p_schema, new_view) || E'\n'
          || format('DROP TABLE IF EXISTS %I.%I CASCADE;', p_schema, new_tb)   || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_ins) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_upd) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_del) || E'\n\n';
    END IF;

    ----------------------------------------------------------------
    -- CREATE TABLE: meta_id + безопасные физические колонки
    ----------------------------------------------------------------
    create_table_sql := format('CREATE TABLE %I.%I (meta_id uuid NOT NULL', p_schema, new_tb);

    IF p_fields IS NOT NULL AND btrim(p_fields) <> '' THEN
        -- разбиваем p_fields по верхнеуровневым запятым
        s := p_fields || ','; len := length(s); i := 1;
        WHILE i <= len LOOP
            ch := substr(s, i, 1);

            IF in_squote THEN
                token := token || ch;
                IF ch = '''' THEN
                    IF i < len AND substr(s, i+1, 1) = '''' THEN token := token || ''''; i := i + 1;
                    ELSE in_squote := false; END IF;
                END IF; i := i + 1; CONTINUE;
            ELSIF in_dquote THEN
                token := token || ch;
                IF ch = '"' THEN
                    IF i < len AND substr(s, i+1, 1) = '"' THEN token := token || '"'; i := i + 1;
                    ELSE in_dquote := false; END IF;
                END IF; i := i + 1; CONTINUE;
            ELSE
                IF ch = '''' THEN in_squote := true; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = '"' THEN in_dquote := true; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = '(' THEN paren := paren + 1; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = ')' THEN paren := paren - 1; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = ',' AND paren = 0 THEN
                    field_def := btrim(token); token := '';

                    IF field_def <> '' THEN
                        -- 1) логическое имя + спецификация (получаем имя БЕЗ внешних кавычек)
                        IF substr(field_def,1,1) = '"' THEN
                            arr := regexp_match(field_def, '^\s*"((?:[^"]|"")+)"\s+(.*)\s*$');
                            IF arr IS NULL OR array_length(arr,1) < 2 THEN
                                RAISE EXCEPTION 'Bad field specification (quoted name expected): "%"', field_def;
                            END IF;
                            raw_name    := arr[1];                       -- содержимое без внешних кавычек
                            logical_name := replace(raw_name, '""', '"'); -- схлопнуть удвоенные внутри
                            field_spec  := btrim(arr[2]);
                        ELSE
                            arr := regexp_match(field_def, '^\s*(\S+)\s+(.*)\s*$');
                            IF arr IS NULL OR array_length(arr,1) < 2 THEN
                                RAISE EXCEPTION 'Bad field specification: "%" (expected "name type")', field_def;
                            END IF;
                            logical_name := arr[1];                      -- без кавычек
                            field_spec   := btrim(arr[2]);
                        END IF;

                        -- 2) убрать любые оставшиеся кавычки из логического имени (на всякий случай)
                        logical_name := replace(btrim(logical_name), '"', '');

                        IF lower(logical_name) = 'meta_id' THEN
                            RAISE EXCEPTION 'p_fields must not contain "meta_id"';
                        END IF;

                        -- уникальность логических имён
                        name_key := lower(logical_name);
                        IF position(','||name_key||',' in names_seen) > 0 THEN
                            RAISE EXCEPTION 'Duplicate field name: "%"', logical_name;
                        END IF;
                        names_seen := names_seen || name_key || ',';

                        -- nullability по умолчанию
                        has_nullness := field_spec ~* '\mNOT\s+NULL\M' OR field_spec ~* '\mNULL\M';
                        IF NOT has_nullness THEN
                            field_spec := field_spec || ' NOT NULL';
                        END IF;

                        -- 3) физическое имя (санитизация)
                        phys_base := lower(logical_name);
                        phys_base := regexp_replace(phys_base, '\s+', '_', 'g');     -- пробелы -> _
                        phys_base := regexp_replace(phys_base, '[^a-z0-9_]', '_', 'g');
                        phys_base := regexp_replace(phys_base, '_{2,}', '_', 'g');   -- схлопнуть
                        phys_base := regexp_replace(phys_base, '^_+|_+$', '', 'g');  -- обрезать края
                        IF phys_base = '' THEN phys_base := 'col'; END IF;

                        phys_name := new_prefix || phys_base;

                        -- уникальность физ. имён
                        suffix := 1;
                        WHILE position(','||phys_name||',' in phys_seen) > 0 LOOP
                            suffix := suffix + 1;
                            phys_name := new_prefix || phys_base || '_' || suffix::text;
                        END LOOP;
                        phys_seen := phys_seen || phys_name || ',';

                        -- 4) заранее процитированный алиас (только здесь, один раз)
                        alias_sql := quote_ident(logical_name);

                        -- 5) CREATE TABLE / VIEW / триггеры
                        create_table_sql := create_table_sql
                          || format(', %I %s', phys_name, field_spec);

                        -- во VIEW подставляем алиас как %s (готовый, из quote_ident)
                        view_user_cols := view_user_cols
                          || format(', t.%I AS %s', phys_name, alias_sql);

                        insert_cols   := insert_cols   || format(', %I', phys_name);
                        insert_vals   := insert_vals   || format(', NEW.%s', alias_sql);
                        update_assign := update_assign || format(', %I = NEW.%s', phys_name, alias_sql);
                    END IF;

                    i := i + 1; CONTINUE;
                ELSE
                    token := token || ch; i := i + 1; CONTINUE;
                END IF;
            END IF;
        END LOOP;
    END IF;

    create_table_sql := create_table_sql || ' );';
    ddl := ddl || create_table_sql || E'\n\n';

    ----------------------------------------------------------------
    -- meta-поля из v_record_meta
    ----------------------------------------------------------------
    FOR meta_field_name IN
        SELECT a.attname::text
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'v_record_meta'
          AND n.nspname = p_schema
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> ALL(forbidden_fields)
        ORDER BY a.attnum
    LOOP
        meta_fields := meta_fields
          || CASE WHEN meta_fields='' THEN format('m.%I', meta_field_name)
                  ELSE format(', m.%I', meta_field_name) END;
    END LOOP;

    ----------------------------------------------------------------
    -- VIEW
    ----------------------------------------------------------------
    ddl := ddl || format(
      'CREATE OR REPLACE VIEW %1$I.%2$I AS
         SELECT t.meta_id%3$s%4$s
           FROM %1$I.%5$I t
           JOIN %1$I.v_record_meta m ON m.%6$I = t.meta_id;',
      p_schema, new_view,
      view_user_cols,
      CASE WHEN meta_fields <> '' THEN ', '||meta_fields ELSE '' END,
      new_tb, p_join_key
    ) || E'\n\n';

    ----------------------------------------------------------------
    -- TRIGGER FUNCTIONS (INSERT/UPDATE/DELETE-soft)
    ----------------------------------------------------------------
    ddl := ddl || format($x$
      CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
      LANGUAGE plpgsql AS $b$
      DECLARE x uuid;
      BEGIN
          x := %1$I.create_record();
          INSERT INTO %1$I.%3$I (meta_id%4$s) VALUES (x%5$s);
          RETURN NEW;
      END;$b$;$x$,
      p_schema, fn_ins, new_tb, insert_cols, insert_vals) || E'\n\n';

    IF btrim(update_assign) = '' THEN
      ddl := ddl || format($x$
        CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
        LANGUAGE plpgsql AS $b$
        BEGIN
            PERFORM %1$I.update_record(OLD.meta_id);
            RETURN NEW;
        END;$b$;$x$,
        p_schema, fn_upd) || E'\n\n';
    ELSE
      ddl := ddl || format($x$
        CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
        LANGUAGE plpgsql AS $b$
        BEGIN
            PERFORM %1$I.update_record(OLD.meta_id);
            UPDATE %1$I.%3$I SET %4$s WHERE meta_id = OLD.meta_id;
            RETURN NEW;
        END;$b$;$x$,
        p_schema, fn_upd, new_tb, ltrim(update_assign, ', ')) || E'\n\n';
    END IF;

    ddl := ddl || format($x$
      CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
      LANGUAGE plpgsql AS $b$
      BEGIN
          PERFORM %1$I.delete_record(OLD.meta_id);
          RETURN OLD;
      END;$b$;$x$,
      p_schema, fn_del) || E'\n\n';

    ----------------------------------------------------------------
    -- TRIGГЕРЫ (тихий drop + create)
    ----------------------------------------------------------------
    ddl := ddl || format($x$
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class   c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = %L AND c.relname = %L AND n.nspname = %L
  ) THEN
    EXECUTE 'DROP TRIGGER ' || quote_ident(%L) || ' ON %I.%I';
  END IF;
END$$;
$x$, trg_ins, new_view, p_schema, trg_ins, p_schema, new_view);

    ddl := ddl || format($x$
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class   c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = %L AND c.relname = %L AND n.nspname = %L
  ) THEN
    EXECUTE 'DROP TRIGGER ' || quote_ident(%L) || ' ON %I.%I';
  END IF;
END$$;
$x$, trg_upd, new_view, p_schema, trg_upd, p_schema, new_view);

    ddl := ddl || format($x$
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class   c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = %L AND c.relname = %L AND n.nspname = %L
  ) THEN
    EXECUTE 'DROP TRIGGER ' || quote_ident(%L) || ' ON %I.%I';
  END IF;
END$$;
$x$, trg_del, new_view, p_schema, trg_del, p_schema, new_view);

    ddl := ddl
      || format('CREATE TRIGGER %I INSTEAD OF INSERT ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                trg_ins, p_schema, new_view, p_schema, fn_ins) || E'\n'
      || format('CREATE TRIGGER %I INSTEAD OF UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                trg_upd, p_schema, new_view, p_schema, fn_upd) || E'\n'
      || format('CREATE TRIGGER %I INSTEAD OF DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                trg_del, p_schema, new_view, p_schema, fn_del) || E'\n';

    RETURN ddl;
END;
$_$;


--
-- Name: gen_meta_ddl_v3(regclass, text, text, integer, text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.gen_meta_ddl_v3(p_template_tb regclass, p_new_base text, p_fields text DEFAULT NULL::text, p_make_drop integer DEFAULT 0, p_join_key text DEFAULT 'id'::text, p_schema text DEFAULT 'public'::text) RETURNS text
    LANGUAGE plpgsql
    AS $_$
DECLARE
    ddl              text := '';
    template_tb_name text;
    new_tb           text;
    new_view         text;

    -- префикс для физических колонок (единственное число)
    new_base_s  text;
    new_prefix  text;

    -- сборка DDL
    create_table_sql text;
    view_user_cols   text := '';  -- будет вида: ', '||format('t.%I', phys_name)||' AS '||quote_ident(alias)
    insert_cols      text := '';
    insert_vals      text := '';  -- ', NEW.'||quote_ident(alias)
    update_assign    text := '';  -- ', '||format('%I', phys_name)||' = NEW.'||quote_ident(alias)

    -- парсер p_fields
    s           text; len int; i int; ch text;
    paren int := 0; in_squote boolean := false; in_dquote boolean := false;
    token text := ''; field_def text;
    logical_name text; field_spec text; has_nullness boolean;
    raw_name text; arr text[];

    -- контроль имён (логических и физических)
    names_seen   text := ',';    -- ',logical1,logical2,'
    phys_seen    text := ',';    -- ',phys1,phys2,'
    name_key     text;
    phys_base    text;
    phys_name    text;
    suffix       int;

    -- meta поля
    meta_field_name text;
    meta_fields     text := '';
    forbidden_fields text[] := ARRAY['id','created','updated','is_del'];

    -- функции/триггеры
    fn_ins text; fn_upd text; fn_del text;
    trg_ins text; trg_upd text; trg_del text;

    -- финальный алиас (НЕ процитированный; цитуем ТОЛЬКО через quote_ident при подстановке)
    alias_id text;
BEGIN
    IF p_new_base IS NULL OR btrim(p_new_base) = '' THEN
        RAISE EXCEPTION 'p_new_base is empty';
    END IF;

    SELECT relname::text INTO template_tb_name FROM pg_class WHERE oid = p_template_tb;
    IF template_tb_name IS NULL THEN
        RAISE EXCEPTION 'Template table not found';
    END IF;

    -- у шаблона должен быть meta_id
    PERFORM 1 FROM pg_attribute a WHERE a.attrelid = p_template_tb AND a.attname = 'meta_id';
    IF NOT FOUND THEN
        RAISE EXCEPTION 'Template "%" must contain column meta_id', template_tb_name;
    END IF;

    -- запрет meta_id в пользовательских полях
    IF p_fields IS NOT NULL AND p_fields ~* '(^|,)\s*meta_id(\s|,|$)' THEN
        RAISE EXCEPTION 'p_fields must not contain "meta_id"';
    END IF;

    new_tb   := 'tb__' || p_new_base;
    new_view := 'v__'  || p_new_base;

    fn_ins := new_view || '_insert';
    fn_upd := new_view || '_update';
    fn_del := new_view || '_delete';

    trg_ins := 'trg_' || new_view || '_ins';
    trg_upd := 'trg_' || new_view || '_upd';
    trg_del := 'trg_' || new_view || '_del';

    new_base_s := CASE WHEN right(p_new_base,1)='s' AND length(p_new_base)>1
                       THEN substr(p_new_base,1,length(p_new_base)-1)
                       ELSE p_new_base END;
    new_prefix := lower(new_base_s) || '_';

    ddl := ddl || format('-- generated by gen_meta_ddl_v3 on %s', now()::timestamptz) || E'\n\n';

    IF p_make_drop = 1 THEN
        ddl := ddl
          || format('DROP VIEW IF EXISTS %I.%I CASCADE;', p_schema, new_view) || E'\n'
          || format('DROP TABLE IF EXISTS %I.%I CASCADE;', p_schema, new_tb)   || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_ins) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_upd) || E'\n'
          || format('DROP FUNCTION IF EXISTS %I.%I() CASCADE;', p_schema, fn_del) || E'\n\n';
    END IF;

    ----------------------------------------------------------------
    -- CREATE TABLE: meta_id + безопасные физические колонки
    ----------------------------------------------------------------
    create_table_sql := format('CREATE TABLE %I.%I (meta_id uuid NOT NULL', p_schema, new_tb);

    IF p_fields IS NOT NULL AND btrim(p_fields) <> '' THEN
        -- разбиваем p_fields по верхнеуровневым запятым
        s := p_fields || ','; len := length(s); i := 1;
        WHILE i <= len LOOP
            ch := substr(s, i, 1);

            IF in_squote THEN
                token := token || ch;
                IF ch = '''' THEN
                    IF i < len AND substr(s, i+1, 1) = '''' THEN token := token || ''''; i := i + 1;
                    ELSE in_squote := false; END IF;
                END IF; i := i + 1; CONTINUE;
            ELSIF in_dquote THEN
                token := token || ch;
                IF ch = '"' THEN
                    IF i < len AND substr(s, i+1, 1) = '"' THEN token := token || '"'; i := i + 1;
                    ELSE in_dquote := false; END IF;
                END IF; i := i + 1; CONTINUE;
            ELSE
                IF ch = '''' THEN in_squote := true; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = '"' THEN in_dquote := true; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = '(' THEN paren := paren + 1; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = ')' THEN paren := paren - 1; token := token || ch; i := i + 1; CONTINUE;
                ELSIF ch = ',' AND paren = 0 THEN
                    field_def := btrim(token); token := '';

                    IF field_def <> '' THEN
                        -- 1) логическое имя + спецификация (получаем имя БЕЗ внешних кавычек)
                        IF substr(field_def,1,1) = '"' THEN
                            arr := regexp_match(field_def, '^\s*"((?:[^"]|"")+)"\s+(.*)\s*$');
                            IF arr IS NULL OR array_length(arr,1) < 2 THEN
                                RAISE EXCEPTION 'Bad field specification (quoted name expected): "%"', field_def;
                            END IF;
                            logical_name := replace(arr[1], '""', '"');   -- внутри "" -> "
                            field_spec   := btrim(arr[2]);
                        ELSE
                            arr := regexp_match(field_def, '^\s*(\S+)\s+(.*)\s*$');
                            IF arr IS NULL OR array_length(arr,1) < 2 THEN
                                RAISE EXCEPTION 'Bad field specification: "%" (expected "name type")', field_def;
                            END IF;
                            logical_name := arr[1];
                            field_spec   := btrim(arr[2]);
                        END IF;

                        -- Жёсткая деквотация логического имени
                        logical_name := btrim(logical_name);
                        IF left(logical_name,1) = '"' AND right(logical_name,1) = '"' AND length(logical_name) >= 2 THEN
                            logical_name := substr(logical_name, 2, length(logical_name)-2);
                        END IF;
                        logical_name := replace(logical_name, '"', ''); -- вообще убираем любые "

                        IF lower(logical_name) = 'meta_id' THEN
                            RAISE EXCEPTION 'p_fields must not contain "meta_id"';
                        END IF;

                        -- уникальность логических имён
                        name_key := lower(logical_name);
                        IF position(','||name_key||',' in names_seen) > 0 THEN
                            RAISE EXCEPTION 'Duplicate field name: "%"', logical_name;
                        END IF;
                        names_seen := names_seen || name_key || ',';

                        -- nullability по умолчанию
                        has_nullness := field_spec ~* '\mNOT\s+NULL\M' OR field_spec ~* '\mNULL\M';
                        IF NOT has_nullness THEN
                            field_spec := field_spec || ' NOT NULL';
                        END IF;

                        -- 2) физическое имя (санитизация)
                        phys_base := lower(logical_name);
                        phys_base := regexp_replace(phys_base, '\s+', '_', 'g');     -- пробелы -> _
                        phys_base := regexp_replace(phys_base, '[^a-z0-9_]', '_', 'g');
                        phys_base := regexp_replace(phys_base, '_{2,}', '_', 'g');   -- схлопнуть
                        phys_base := regexp_replace(phys_base, '^_+|_+$', '', 'g');  -- обрезать края
                        IF phys_base = '' THEN phys_base := 'col'; END IF;

                        phys_name := new_prefix || phys_base;

                        -- уникальность физ. имён
                        suffix := 1;
                        WHILE position(','||phys_name||',' in phys_seen) > 0 LOOP
                            suffix := suffix + 1;
                            phys_name := new_prefix || phys_base || '_' || suffix::text;
                        END LOOP;
                        phys_seen := phys_seen || phys_name || ',';

                        -- 3) алиас как ИДЕНТИФИКАТОР (не процитированный); реальное цитирование — ТОЛЬКО quote_ident()
                        alias_id := logical_name;

                        -- 4) CREATE TABLE / VIEW / триггеры
                        create_table_sql := create_table_sql || format(', %I %s', phys_name, field_spec);

                        -- VIEW: форматируем только phys_name, алиас добавляем отдельной конкатенацией с quote_ident()
                        view_user_cols := view_user_cols
                          || ', ' || format('t.%I', phys_name) || ' AS ' || quote_ident(alias_id);

                        insert_cols   := insert_cols   || format(', %I', phys_name);
                        insert_vals   := insert_vals   || ', NEW.' || quote_ident(alias_id);
                        update_assign := update_assign || ', ' || format('%I', phys_name) || ' = NEW.' || quote_ident(alias_id);
                    END IF;

                    i := i + 1; CONTINUE;
                ELSE
                    token := token || ch; i := i + 1; CONTINUE;
                END IF;
            END IF;
        END LOOP;
    END IF;

    create_table_sql := create_table_sql || ' );';
    ddl := ddl || create_table_sql || E'\n\n';

    ----------------------------------------------------------------
    -- meta-поля из v_record_meta
    ----------------------------------------------------------------
    FOR meta_field_name IN
        SELECT a.attname::text
        FROM pg_attribute a
        JOIN pg_class c ON c.oid = a.attrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE c.relname = 'v_record_meta'
          AND n.nspname = p_schema
          AND a.attnum > 0 AND NOT a.attisdropped
          AND a.attname <> ALL(forbidden_fields)
        ORDER BY a.attnum
    LOOP
        meta_fields := meta_fields
          || CASE WHEN meta_fields='' THEN format('m.%I', meta_field_name)
                  ELSE format(', m.%I', meta_field_name) END;
    END LOOP;

    ----------------------------------------------------------------
    -- VIEW
    ----------------------------------------------------------------
    ddl := ddl || format(
      'CREATE OR REPLACE VIEW %1$I.%2$I AS
         SELECT t.meta_id%3$s%4$s
           FROM %1$I.%5$I t
           JOIN %1$I.v_record_meta m ON m.%6$I = t.meta_id;',
      p_schema, new_view,
      view_user_cols,
      CASE WHEN meta_fields <> '' THEN ', '||meta_fields ELSE '' END,
      new_tb, p_join_key
    ) || E'\n\n';

    ----------------------------------------------------------------
    -- TRIGGER FUNCTIONS (INSERT/UPDATE/DELETE-soft)
    ----------------------------------------------------------------
    ddl := ddl || format($x$
      CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
      LANGUAGE plpgsql AS $b$
      DECLARE x uuid;
      BEGIN
          x := %1$I.create_record();
          INSERT INTO %1$I.%3$I (meta_id%4$s) VALUES (x%5$s);
          RETURN NEW;
      END;$b$;$x$,
      p_schema, fn_ins, new_tb, insert_cols, insert_vals) || E'\n\n';

    IF btrim(update_assign) = '' THEN
      ddl := ddl || format($x$
        CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
        LANGUAGE plpgsql AS $b$
        BEGIN
            PERFORM %1$I.update_record(OLD.meta_id);
            RETURN NEW;
        END;$b$;$x$,
        p_schema, fn_upd) || E'\n\n';
    ELSE
      ddl := ddl || format($x$
        CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
        LANGUAGE plpgsql AS $b$
        BEGIN
            PERFORM %1$I.update_record(OLD.meta_id);
            UPDATE %1$I.%3$I SET %4$s WHERE meta_id = OLD.meta_id;
            RETURN NEW;
        END;$b$;$x$,
        p_schema, fn_upd, new_tb, ltrim(update_assign, ', ')) || E'\n\n';
    END IF;

    ddl := ddl || format($x$
      CREATE OR REPLACE FUNCTION %1$I.%2$I() RETURNS trigger
      LANGUAGE plpgsql AS $b$
      BEGIN
          PERFORM %1$I.delete_record(OLD.meta_id);
          RETURN OLD;
      END;$b$;$x$,
      p_schema, fn_del) || E'\n\n';

    ----------------------------------------------------------------
    -- TRIGГЕРЫ (тихий drop + create)
    ----------------------------------------------------------------
    ddl := ddl || format($x$
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class   c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = %L AND c.relname = %L AND n.nspname = %L
  ) THEN
    EXECUTE 'DROP TRIGGER ' || quote_ident(%L) || ' ON %I.%I';
  END IF;
END$$;
$x$, trg_ins, new_view, p_schema, trg_ins, p_schema, new_view);

    ddl := ddl || format($x$
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class   c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = %L AND c.relname = %L AND n.nspname = %L
  ) THEN
    EXECUTE 'DROP TRIGGER ' || quote_ident(%L) || ' ON %I.%I';
  END IF;
END$$;
$x$, trg_upd, new_view, p_schema, trg_upd, p_schema, new_view);

    ddl := ddl || format($x$
DO $$
BEGIN
  IF EXISTS (
    SELECT 1
    FROM pg_trigger t
    JOIN pg_class   c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname = %L AND c.relname = %L AND n.nspname = %L
  ) THEN
    EXECUTE 'DROP TRIGGER ' || quote_ident(%L) || ' ON %I.%I';
  END IF;
END$$;
$x$, trg_del, new_view, p_schema, trg_del, p_schema, new_view);

    ddl := ddl
      || format('CREATE TRIGGER %I INSTEAD OF INSERT ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                trg_ins, p_schema, new_view, p_schema, fn_ins) || E'\n'
      || format('CREATE TRIGGER %I INSTEAD OF UPDATE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                trg_upd, p_schema, new_view, p_schema, fn_upd) || E'\n'
      || format('CREATE TRIGGER %I INSTEAD OF DELETE ON %I.%I FOR EACH ROW EXECUTE FUNCTION %I.%I();',
                trg_del, p_schema, new_view, p_schema, fn_del) || E'\n';

    RETURN ddl;
END;
$_$;


--
-- Name: get_agent_sub_kinds(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_agent_sub_kinds(agent_name text) RETURNS TABLE(sub_kind_code text, sub_kind_name text, sub_kind_type text, sub_kind_default_value text, in_out text, meta_id uuid, val text, result text)
    LANGUAGE plpgsql
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        t.sub_kind_code,
        t.sub_kind_name,
        t.sub_kind_type,
        t.sub_kind_default_value,
        t.in_out,
        t.meta_id,
        t.val,
        COALESCE(t.val, t.sub_kind_default_value) as result
    FROM
    (
        SELECT
            *,
            (SELECT user_content FROM v_user_docs WHERE user_title = tt.meta_id::text LIMIT 1) as val
        FROM
        (
            SELECT  
                sk.sub_kind_code,
                sk.sub_kind_name,
                sk.sub_kind_type,
                COALESCE(sk.sub_kind_default_value, '') as sub_kind_default_value,
                'input' as in_out,
                sk.meta_id
            FROM public.v_sub_kinds sk
            WHERE sk.sub_kind_value LIKE '%' || agent_name || '%' AND sk.kind_code = 'inputs'
            
            UNION ALL
            
            SELECT  
                sk.sub_kind_code,
                sk.sub_kind_name,
                sk.sub_kind_type,
                COALESCE(sk.sub_kind_default_value, '') as sub_kind_default_value,
                'output' as in_out,
                sk.meta_id
            FROM public.v_sub_kinds sk
            WHERE sk.sub_kind_value LIKE '%' || agent_name || '%' AND sk.kind_code = 'outputs'
            
            UNION ALL
            
            SELECT  
                sk.sub_kind_code,
                sk.sub_kind_name,
                sk.sub_kind_type,
                COALESCE(sk.sub_kind_default_value, '') as sub_kind_default_value,
                'global' as in_out,
                sk.meta_id
            FROM public.v_sub_kinds sk
            WHERE sk.kind_code = 'globals'
        ) tt
    ) t;
END;
$$;


--
-- Name: get_prompt_cache(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_prompt_cache(p_provider text, p_prompt text) RETURNS TABLE(response_json jsonb, response_raw text, tokens_used integer, old_answer text)
    LANGUAGE plpgsql STABLE
    AS $$
BEGIN
    RETURN QUERY
    SELECT
        pc.response_json,
        pc.response_raw,
        pc.tokens_used,
        pc.old_answer
    FROM prompt_cache pc
    WHERE pc.provider = p_provider
      AND pc.prompt_hash = MD5(p_prompt)
    ORDER BY pc.created_at DESC
    LIMIT 1;
END;
$$;


--
-- Name: get_table_dependencies(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_table_dependencies(p_table text) RETURNS TABLE(section text, info jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
  t_reg    regclass;
  t_oid    oid;
  t_schema text;
  t_rel    text;
BEGIN
  t_reg := to_regclass(p_table);
  IF t_reg IS NULL THEN
    RAISE EXCEPTION 'Relation "%" not found (check schema/search_path)', p_table;
  END IF;

  t_oid := t_reg::oid;

  SELECT n.nspname, c.relname
  INTO t_schema, t_rel
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = t_oid;

  -- 0) Общая сводка
  RETURN QUERY
  SELECT 'table_info',
         jsonb_build_object(
           'schema', t_schema,
           'name',   t_rel,
           'oid',    t_oid,
           'relkind', c.relkind,
           'owner',   pg_get_userbyid(c.relowner),
           'tablespace', ts.spcname,
           'persistence', c.relpersistence,
           'row_security', c.relrowsecurity,
           'reloptions', COALESCE(to_jsonb(c.reloptions), '[]'::jsonb)
         )
  FROM pg_class c
  LEFT JOIN pg_tablespace ts ON ts.oid = c.reltablespace
  WHERE c.oid = t_oid;

  -- 1) Колонки
  RETURN QUERY
  SELECT 'columns',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'attnum', a.attnum,
             'column_name', a.attname,
             'data_type', pg_catalog.format_type(a.atttypid, a.atttypmod),
             'is_nullable', NOT a.attnotnull,
             'default', pg_get_expr(ad.adbin, ad.adrelid),
             'collation', coll.collname
           )
           ORDER BY a.attnum
         ), '[]'::jsonb)
  FROM pg_attribute a
  LEFT JOIN pg_attrdef ad   ON ad.adrelid = a.attrelid AND ad.adnum = a.attnum
  LEFT JOIN pg_collation coll ON coll.oid = a.attcollation
  WHERE a.attrelid = t_oid
    AND a.attnum > 0
    AND NOT a.attisdropped;

  -- 2) Индексы
  RETURN QUERY
  SELECT 'indexes',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'index_name', ic.relname,
             'is_primary', ix.indisprimary,
             'is_unique',  ix.indisunique,
             'is_valid',   ix.indisvalid,
             'is_ready',   ix.indisready,
             'is_clustered', ix.indisclustered,
             'def', pg_get_indexdef(ix.indexrelid)
           )
           ORDER BY ic.relname
         ), '[]'::jsonb)
  FROM pg_index ix
  JOIN pg_class ic ON ic.oid = ix.indexrelid
  WHERE ix.indrelid = t_oid;

  -- 3) Констрейнты (свои и входящие)
  RETURN QUERY
  SELECT 'constraints',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'constraint_name', c.conname,
             'type', CASE c.contype
                        WHEN 'p' THEN 'PRIMARY KEY'
                        WHEN 'u' THEN 'UNIQUE'
                        WHEN 'f' THEN 'FOREIGN KEY'
                        WHEN 'c' THEN 'CHECK'
                        WHEN 't' THEN 'TRIGGER'
                        ELSE c.contype::text
                      END,
             'defined_on', CASE WHEN c.conrelid = t_oid THEN 'this_table' ELSE ns_con.nspname||'.'||rel_con.relname END,
             'references', CASE WHEN c.contype = 'f'
                                THEN ns_ref.nspname||'.'||rel_ref.relname
                                ELSE NULL END,
             'definition', pg_get_constraintdef(c.oid, true)
           )
           ORDER BY c.conname
         ), '[]'::jsonb)
  FROM pg_constraint c
  LEFT JOIN pg_class rel_con ON rel_con.oid = c.conrelid
  LEFT JOIN pg_namespace ns_con ON ns_con.oid = rel_con.relnamespace
  LEFT JOIN pg_class rel_ref ON rel_ref.oid = c.confrelid
  LEFT JOIN pg_namespace ns_ref ON ns_ref.oid = rel_ref.relnamespace
  WHERE c.conrelid = t_oid
     OR c.confrelid = t_oid;

  -- 4) Триггеры на таблице
  RETURN QUERY
  SELECT 'triggers',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'trigger_name', t.tgname,
             'enabled', t.tgenabled,
             'function', p.proname,
             'def', pg_get_triggerdef(t.oid, true)
           )
           ORDER BY t.tgname
         ), '[]'::jsonb)
  FROM pg_trigger t
  JOIN pg_proc p ON p.oid = t.tgfoid
  WHERE t.tgrelid = t_oid
    AND NOT t.tgisinternal;

  -- 5) Зависимые вьюхи (прямые)
  RETURN QUERY
  SELECT 'dependent_views',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'view_name', ns.nspname || '.' || c.relname,
             'relkind', c.relkind,
             'definition', pg_get_viewdef(c.oid, true)
           )
           ORDER BY ns.nspname, c.relname
         ), '[]'::jsonb)
  FROM (
    -- обычные вьюхи через pg_rewrite
    SELECT DISTINCT r.ev_class AS view_oid
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    WHERE d.refobjid = t_oid
    UNION
    -- материализованные вьюхи — зависимость идёт напрямую на pg_class
    SELECT DISTINCT d.objid AS view_oid
    FROM pg_depend d
    JOIN pg_class mv ON mv.oid = d.objid AND mv.relkind = 'm'
    WHERE d.refobjid = t_oid
  ) x
  JOIN pg_class c ON c.oid = x.view_oid AND c.relkind IN ('v','m')
  JOIN pg_namespace ns ON ns.oid = c.relnamespace;

  -- 6) Триггеры на зависимых вьюхах (прямых)
  RETURN QUERY
  SELECT 'dependent_view_triggers',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'view_name', ns.nspname||'.'||c.relname,
             'trigger_name', t.tgname,
             'enabled', t.tgenabled,
             'def', pg_get_triggerdef(t.oid, true)
           )
           ORDER BY ns.nspname, c.relname, t.tgname
         ), '[]'::jsonb)
  FROM (
    SELECT DISTINCT r.ev_class AS view_oid
    FROM pg_depend d
    JOIN pg_rewrite r ON r.oid = d.objid
    WHERE d.refobjid = t_oid
    UNION
    SELECT DISTINCT d.objid AS view_oid
    FROM pg_depend d
    JOIN pg_class mv ON mv.oid = d.objid AND mv.relkind = 'm'
    WHERE d.refobjid = t_oid
  ) x
  JOIN pg_trigger t ON t.tgrelid = x.view_oid AND NOT t.tgisinternal
  JOIN pg_class c ON c.oid = x.view_oid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace;

  -- 7) Rules
  RETURN QUERY
  SELECT 'rules',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'rule_name', r.rulename,
             'def', pg_get_ruledef(r.oid, true)
           )
           ORDER BY r.rulename
         ), '[]'::jsonb)
  FROM pg_rewrite r
  WHERE r.ev_class = t_oid;

  -- 8) RLS-политики
  RETURN QUERY
  SELECT 'row_policies',
         COALESCE(jsonb_agg(to_jsonb(p) ORDER BY p.policyname), '[]'::jsonb)
  FROM pg_policies p
  WHERE p.schemaname = t_schema AND p.tablename = t_rel;

  -- 9) GRANTS
  RETURN QUERY
  SELECT 'grants',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'grantee', grantee,
             'privilege', privilege_type,
             'is_grantable', is_grantable
           )
           ORDER BY grantee, privilege_type
         ), '[]'::jsonb)
  FROM information_schema.table_privileges
  WHERE table_schema = t_schema AND table_name = t_rel;

  -- 10) Владение секвенсами
  RETURN QUERY
  SELECT 'owned_sequences',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'sequence', ns.nspname||'.'||seq.relname
           )
           ORDER BY ns.nspname, seq.relname
         ), '[]'::jsonb)
  FROM pg_depend dep
  JOIN pg_class  seq ON seq.oid = dep.objid AND seq.relkind = 'S'
  JOIN pg_namespace ns ON ns.oid = seq.relnamespace
  WHERE dep.refobjid = t_oid
    AND dep.deptype IN ('a','i');

  -- 11) Партиционирование
  RETURN QUERY
  WITH parent AS (
    SELECT ns.nspname||'.'||c2.relname AS parent_name
    FROM pg_inherits i
    JOIN pg_class c2 ON c2.oid = i.inhparent
    JOIN pg_namespace ns ON ns.oid = c2.relnamespace
    WHERE i.inhrelid = t_oid
    LIMIT 1
  ),
  children AS (
    SELECT COALESCE(jsonb_agg(ns.nspname||'.'||c3.relname ORDER BY ns.nspname, c3.relname), '[]'::jsonb) AS kids
    FROM pg_inherits i
    JOIN pg_class c3 ON c3.oid = i.inhrelid
    JOIN pg_namespace ns ON ns.oid = c3.relnamespace
    WHERE i.inhparent = t_oid
  )
  SELECT 'partitioning',
         jsonb_build_object(
           'parent', (SELECT parent_name FROM parent),
           'children', (SELECT kids FROM children)
         );

  --------------------------------------------------------------------
  -- 12) Зависимые вьюхи/матвью РЕКУРСИВНО (вся цепочка «вверх»)
  --------------------------------------------------------------------
  RETURN QUERY
  WITH RECURSIVE vt AS (
    -- прямые зависимые
    SELECT DISTINCT v.oid AS view_oid,
           v.relkind,
           v.relnamespace,
           v.relname,
           ARRAY[t_oid::oid, v.oid] AS path
    FROM (
      -- обычные вьюхи через rewrite
      SELECT v1.oid
      FROM pg_depend d1
      JOIN pg_rewrite r1 ON r1.oid = d1.objid
      JOIN pg_class v1 ON v1.oid = r1.ev_class AND v1.relkind = 'v'
      WHERE d1.refobjid = t_oid
      UNION
      -- материализованные вьюхи напрямую
      SELECT mv1.oid
      FROM pg_depend d1
      JOIN pg_class mv1 ON mv1.oid = d1.objid AND mv1.relkind = 'm'
      WHERE d1.refobjid = t_oid
    ) s
    JOIN pg_class v ON v.oid = s.oid

    UNION ALL

    -- поднимаемся выше: ищем вьюхи, зависящие от ранее найденных
    SELECT DISTINCT v2.oid,
           v2.relkind,
           v2.relnamespace,
           v2.relname,
           vt.path || v2.oid
    FROM vt
    JOIN (
      SELECT d2.refobjid, v3.oid
      FROM pg_depend d2
      JOIN pg_rewrite r2 ON r2.oid = d2.objid
      JOIN pg_class v3 ON v3.oid = r2.ev_class AND v3.relkind = 'v'
      UNION
      SELECT d2.refobjid, mv3.oid
      FROM pg_depend d2
      JOIN pg_class mv3 ON mv3.oid = d2.objid AND mv3.relkind = 'm'
    ) dep ON dep.refobjid = vt.view_oid
    JOIN pg_class v2 ON v2.oid = dep.oid
    WHERE NOT v2.oid = ANY (vt.path)
  )
  SELECT 'dependent_views_recursive',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'view_name', ns.nspname||'.'||c.relname,
             'relkind', c.relkind,
             'depth', array_length(vt.path,1) - 1,
             'via', (
               SELECT jsonb_agg(ns2.nspname||'.'||c2.relname ORDER BY p.ord)
               FROM unnest(vt.path) WITH ORDINALITY AS p(oid, ord)
               JOIN pg_class c2 ON c2.oid = p.oid
               JOIN pg_namespace ns2 ON ns2.oid = c2.relnamespace
             ),
             'definition', pg_get_viewdef(c.oid, true)
           )
           ORDER BY array_length(vt.path,1), ns.nspname, c.relname
         ), '[]'::jsonb)
  FROM vt
  JOIN pg_class c ON c.oid = vt.view_oid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace;

  --------------------------------------------------------------------
  -- 13) Триггеры на зависимых вьюхах РЕКУРСИВНО
  --------------------------------------------------------------------
  RETURN QUERY
  WITH RECURSIVE vt AS (
    SELECT DISTINCT v.oid AS view_oid,
           ARRAY[t_oid::oid, v.oid] AS path
    FROM (
      SELECT v1.oid
      FROM pg_depend d1
      JOIN pg_rewrite r1 ON r1.oid = d1.objid
      JOIN pg_class v1 ON v1.oid = r1.ev_class AND v1.relkind = 'v'
      WHERE d1.refobjid = t_oid
      UNION
      SELECT mv1.oid
      FROM pg_depend d1
      JOIN pg_class mv1 ON mv1.oid = d1.objid AND mv1.relkind = 'm'
      WHERE d1.refobjid = t_oid
    ) s
    JOIN pg_class v ON v.oid = s.oid

    UNION ALL

    SELECT DISTINCT v2.oid,
           vt.path || v2.oid
    FROM vt
    JOIN (
      SELECT d2.refobjid, v3.oid
      FROM pg_depend d2
      JOIN pg_rewrite r2 ON r2.oid = d2.objid
      JOIN pg_class v3 ON v3.oid = r2.ev_class AND v3.relkind = 'v'
      UNION
      SELECT d2.refobjid, mv3.oid
      FROM pg_depend d2
      JOIN pg_class mv3 ON mv3.oid = d2.objid AND mv3.relkind = 'm'
    ) dep ON dep.refobjid = vt.view_oid
    JOIN pg_class v2 ON v2.oid = dep.oid
    WHERE NOT v2.oid = ANY (vt.path)
  )
  SELECT 'dependent_view_triggers_recursive',
         COALESCE(jsonb_agg(
           jsonb_build_object(
             'view_name', ns.nspname||'.'||c.relname,
             'trigger_name', t.tgname,
             'enabled', t.tgenabled,
             'def', pg_get_triggerdef(t.oid, true),
             'depth', array_length(vt.path,1) - 1,
             'via', (
               SELECT jsonb_agg(ns2.nspname||'.'||c2.relname ORDER BY p.ord)
               FROM unnest(vt.path) WITH ORDINALITY AS p(oid, ord)
               JOIN pg_class c2 ON c2.oid = p.oid
               JOIN pg_namespace ns2 ON ns2.oid = c2.relnamespace
             )
           )
           ORDER BY array_length(vt.path,1), ns.nspname, c.relname, t.tgname
         ), '[]'::jsonb)
  FROM vt
  JOIN pg_trigger t ON t.tgrelid = vt.view_oid AND NOT t.tgisinternal
  JOIN pg_class c ON c.oid = vt.view_oid
  JOIN pg_namespace ns ON ns.oid = c.relnamespace;

END;
$$;


--
-- Name: get_table_dependencies_json(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_table_dependencies_json(p_table text) RETURNS jsonb
    LANGUAGE sql STABLE
    AS $$
WITH sections AS (
  -- если p_table не найден, базовая функция выбросит исключение
  SELECT COALESCE(jsonb_object_agg(section, info), '{}'::jsonb) AS obj
  FROM get_table_dependencies(p_table)
),
resolved AS (
  SELECT n.nspname AS schema, c.relname AS name, c.oid AS oid
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.oid = to_regclass(p_table)
),
meta AS (
  SELECT jsonb_build_object(
    'input', p_table,
    'resolved', r.schema||'.'||r.name,
    'oid', r.oid,
    'db', current_database(),
    'server_version_num', current_setting('server_version_num'),
    'search_path', current_setting('search_path', true),
    'generated_at', now()
  ) AS obj
  FROM resolved r
)
SELECT jsonb_build_object(
  'meta',     (SELECT obj FROM meta),
  'sections', (SELECT obj FROM sections)
);
$$;


--
-- Name: get_table_dependencies_recursive(text, integer, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.get_table_dependencies_recursive(table_name text, max_depth integer DEFAULT 10, output_format text DEFAULT 'sections'::text) RETURNS TABLE(result jsonb)
    LANGUAGE plpgsql
    AS $$
DECLARE
    table_oid OID;
    table_regclass REGCLASS;
    result_json JSONB;
BEGIN
    -- Проверяем существование таблицы и получаем OID
    table_regclass := to_regclass(table_name);
    IF table_regclass IS NULL THEN
        RAISE EXCEPTION 'Table "%" does not exist', table_name;
    END IF;
    
    table_oid := table_regclass::OID;

    -- Собираем все данные в один JSON объект
    SELECT jsonb_build_object(
        'table_info', (
            SELECT jsonb_build_object(
                'schema_name', ns.nspname,
                'table_name', c.relname,
                'table_type', CASE c.relkind
                    WHEN 'r' THEN 'table'
                    WHEN 'p' THEN 'partitioned table'
                    WHEN 'v' THEN 'view'
                    WHEN 'm' THEN 'materialized view'
                    ELSE c.relkind::TEXT
                END,
                'owner', pg_get_userbyid(c.relowner),
                'tablespace', ts.spcname,
                'reloptions', c.reloptions,
                'has_indexes', c.relhasindex,
                'has_rules', c.relhasrules,
                'has_triggers', c.relhastriggers
            )
            FROM pg_class c
            JOIN pg_namespace ns ON c.relnamespace = ns.oid
            LEFT JOIN pg_tablespace ts ON c.reltablespace = ts.oid
            WHERE c.oid = table_oid
        ),
        
        'table_structure', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'column_name', a.attname,
                'ordinal_position', a.attnum,
                'data_type', pg_catalog.format_type(a.atttypid, a.atttypmod),
                'is_nullable', NOT a.attnotnull,
                'default', pg_get_expr(d.adbin, d.adrelid),
                'is_identity', a.attidentity <> ''::"char",
                'identity_generation', CASE a.attidentity 
                    WHEN 'a' THEN 'ALWAYS' 
                    WHEN 'd' THEN 'BY DEFAULT' 
                    ELSE NULL 
                END,
                'is_generated', a.attgenerated <> ''::"char"
            ) ORDER BY a.attnum), '[]'::JSONB)
            FROM pg_attribute a
            LEFT JOIN pg_attrdef d ON d.adrelid = a.attrelid AND d.adnum = a.attnum
            WHERE a.attrelid = table_oid
              AND a.attnum > 0
              AND NOT a.attisdropped
        ),
        
        'indexes', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'schema_name', ns.nspname,
                'index_name', ci.relname,
                'index_type', am.amname,
                'is_unique', i.indisunique,
                'is_primary', i.indisprimary,
                'is_valid', i.indisvalid,
                'index_definition', pg_get_indexdef(i.indexrelid)
            ) ORDER BY ci.relname), '[]'::JSONB)
            FROM pg_index i
            JOIN pg_class ci ON i.indexrelid = ci.oid
            JOIN pg_namespace ns ON ci.relnamespace = ns.oid
            JOIN pg_am am ON ci.relam = am.oid
            WHERE i.indrelid = table_oid
        ),
        
        'outgoing_constraints', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'constraint_name', c.conname,
                'constraint_type', CASE c.contype
                    WHEN 'p' THEN 'PRIMARY KEY'
                    WHEN 'u' THEN 'UNIQUE'
                    WHEN 'f' THEN 'FOREIGN KEY'
                    WHEN 'c' THEN 'CHECK'
                    WHEN 't' THEN 'TRIGGER'
                    WHEN 'x' THEN 'EXCLUSION'
                    ELSE 'OTHER'
                END,
                'definition', pg_get_constraintdef(c.oid),
                'referenced_table', CASE WHEN c.contype = 'f' THEN 
                    (SELECT ns.nspname || '.' || tc.relname 
                     FROM pg_class tc JOIN pg_namespace tns ON tc.relnamespace = tns.oid 
                     WHERE tc.oid = c.confrelid)
                ELSE NULL END
            ) ORDER BY c.conname), '[]'::JSONB)
            FROM pg_constraint c
            WHERE c.conrelid = table_oid
        ),
        
        'incoming_constraints', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'constraint_name', c.conname,
                'schema_name', ns.nspname,
                'table_name', tc.relname,
                'constraint_type', CASE c.contype
                    WHEN 'f' THEN 'FOREIGN KEY'
                    ELSE c.contype::TEXT
                END,
                'definition', pg_get_constraintdef(c.oid)
            ) ORDER BY ns.nspname, tc.relname, c.conname), '[]'::JSONB)
            FROM pg_constraint c
            JOIN pg_class tc ON c.conrelid = tc.oid
            JOIN pg_namespace ns ON tc.relnamespace = ns.oid
            WHERE c.confrelid = table_oid
        ),
        
        'triggers', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'trigger_name', t.tgname,
                'enabled_state', CASE t.tgenabled
                    WHEN 'O' THEN 'origin'
                    WHEN 'D' THEN 'disabled'
                    WHEN 'R' THEN 'replica'
                    WHEN 'A' THEN 'always'
                    ELSE t.tgenabled::TEXT
                END,
                'event_manipulation', TRIM(LEADING 'TRIGGER ' FROM pg_get_triggerdef(t.oid)),
                'function_name', p.proname,
                'function_schema', nsp.nspname
            ) ORDER BY t.tgname), '[]'::JSONB)
            FROM pg_trigger t
            JOIN pg_proc p ON t.tgfoid = p.oid
            JOIN pg_namespace nsp ON p.pronamespace = nsp.oid
            WHERE t.tgrelid = table_oid
              AND NOT t.tgisinternal
        ),
        
        'recursive_view_dependencies', (
            WITH RECURSIVE view_dependencies AS (
                -- Базовый случай: прямые зависимости от исходной таблицы
                SELECT 
                    d.objid as rewrite_oid,
                    c.oid as view_oid,
                    ns.nspname as view_schema,
                    c.relname as view_name,
                    c.relkind,
                    1 as depth,
                    ARRAY[table_oid] as path
                FROM pg_depend d
                JOIN pg_rewrite r ON d.objid = r.oid
                JOIN pg_class c ON r.ev_class = c.oid
                JOIN pg_namespace ns ON c.relnamespace = ns.oid
                WHERE d.refobjid = table_oid
                  AND c.relkind IN ('v', 'm')
                  AND c.oid != table_oid
                
                UNION ALL
                
                -- Рекурсивная часть: зависимости представлений от других представлений
                SELECT 
                    d.objid as rewrite_oid,
                    c.oid as view_oid,
                    ns.nspname as view_schema,
                    c.relname as view_name,
                    c.relkind,
                    vd.depth + 1,
                    vd.path || c.oid
                FROM pg_depend d
                JOIN pg_rewrite r ON d.objid = r.oid
                JOIN pg_class c ON r.ev_class = c.oid
                JOIN pg_namespace ns ON c.relnamespace = ns.oid
                JOIN view_dependencies vd ON d.refobjid = vd.view_oid
                WHERE c.relkind IN ('v', 'm')
                  AND c.oid != table_oid
                  AND NOT c.oid = ANY(vd.path)
                  AND vd.depth < max_depth
            ),
            view_details AS (
                SELECT DISTINCT
                    vd.view_oid,
                    vd.view_schema,
                    vd.view_name,
                    vd.relkind,
                    vd.depth,
                    pg_get_viewdef(vd.view_oid) as view_definition
                FROM view_dependencies vd
            )
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'schema_name', vd.view_schema,
                'view_name', vd.view_name,
                'view_type', CASE vd.relkind
                    WHEN 'v' THEN 'view'
                    WHEN 'm' THEN 'materialized view'
                    ELSE vd.relkind::TEXT
                END,
                'depth', vd.depth,
                'view_definition', vd.view_definition
            ) ORDER BY vd.depth, vd.view_schema, vd.view_name), '[]'::JSONB)
            FROM view_details vd
        ),
        
        'view_triggers', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'view_schema', ns.nspname,
                'view_name', c.relname,
                'trigger_name', t.tgname,
                'enabled_state', CASE t.tgenabled
                    WHEN 'O' THEN 'origin'
                    WHEN 'D' THEN 'disabled'
                    WHEN 'R' THEN 'replica'
                    WHEN 'A' THEN 'always'
                    ELSE t.tgenabled::TEXT
                END,
                'trigger_definition', pg_get_triggerdef(t.oid),
                'function_name', p.proname,
                'function_schema', nsp.nspname
            ) ORDER BY ns.nspname, c.relname, t.tgname), '[]'::JSONB)
            FROM pg_depend d
            JOIN pg_rewrite r ON d.objid = r.oid
            JOIN pg_class c ON r.ev_class = c.oid
            JOIN pg_namespace ns ON c.relnamespace = ns.oid
            JOIN pg_trigger t ON t.tgrelid = c.oid
            JOIN pg_proc p ON t.tgfoid = p.oid
            JOIN pg_namespace nsp ON p.pronamespace = nsp.oid
            WHERE d.refobjid = table_oid
              AND c.relkind IN ('v', 'm')
              AND NOT t.tgisinternal
        ),
        
        'rls_policies', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'policy_name', pol.polname,
                'roles', pol.polroles,
                'cmd', pol.polcmd,
                'qual', pg_get_expr(pol.polqual, pol.polrelid),
                'with_check', pg_get_expr(pol.polwithcheck, pol.polrelid)
            ) ORDER BY pol.polname), '[]'::JSONB)
            FROM pg_policy pol
            WHERE pol.polrelid = table_oid
        ),
        
        'grants', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'grantee', tp.grantee,
                'privilege_type', tp.privilege_type,
                'is_grantable', tp.is_grantable
            ) ORDER BY tp.grantee, tp.privilege_type), '[]'::JSONB)
            FROM information_schema.table_privileges tp
            WHERE tp.table_name = (SELECT relname FROM pg_class WHERE oid = table_oid)
              AND tp.table_schema = (SELECT nspname FROM pg_namespace WHERE oid = (SELECT relnamespace FROM pg_class WHERE oid = table_oid))
        ),
        
        'sequences', (
            SELECT jsonb_agg(seq_info) FROM (
                SELECT jsonb_build_object(
                    'column_name', a.attname,
                    'sequence_schema', ss.nspname,
                    'sequence_name', sc.relname,
                    'is_identity', a.attidentity <> ''::"char"
                ) as seq_info
                FROM pg_attribute a
                JOIN pg_class sc ON a.attrelid = table_oid AND a.atttypid = sc.oid AND sc.relkind = 'S'
                JOIN pg_namespace ss ON sc.relnamespace = ss.oid
                WHERE a.attrelid = table_oid
                
                UNION ALL
                
                SELECT jsonb_build_object(
                    'column_name', a.attname,
                    'sequence_schema', ss.nspname,
                    'sequence_name', sc.relname,
                    'is_identity', TRUE
                ) as seq_info
                FROM pg_depend d
                JOIN pg_class sc ON d.objid = sc.oid AND sc.relkind = 'S'
                JOIN pg_namespace ss ON sc.relnamespace = ss.oid
                JOIN pg_attribute a ON d.refobjid = a.attrelid AND d.refobjsubid = a.attnum
                WHERE d.refobjid = table_oid AND d.deptype = 'a'
            ) seq_data
        ),
        
        'rules', (
            SELECT COALESCE(jsonb_agg(jsonb_build_object(
                'rule_name', r.rulename,
                'definition', pg_get_ruledef(r.oid)
            ) ORDER BY r.rulename), '[]'::JSONB)
            FROM pg_rewrite r
            WHERE r.ev_class = table_oid
              AND r.rulename <> '_RETURN'
        ),
        
        'partitioning', (
            SELECT jsonb_build_object(
                'is_partitioned', (SELECT relkind = 'p' FROM pg_class WHERE oid = table_oid),
                'partitions', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'partition_name', cp.relname,
                    'partition_schema', nsp.nspname,
                    'partition_bound', pg_get_expr(ci.relpartbound, ci.oid)
                ) ORDER BY cp.relname)
                FROM pg_inherits i
                JOIN pg_class cp ON i.inhrelid = cp.oid
                JOIN pg_namespace nsp ON cp.relnamespace = nsp.oid
                JOIN pg_class ci ON i.inhrelid = ci.oid
                WHERE i.inhparent = table_oid), '[]'::JSONB),
                'parent_tables', COALESCE((SELECT jsonb_agg(jsonb_build_object(
                    'parent_name', cp.relname,
                    'parent_schema', nsp.nspname
                ) ORDER BY cp.relname)
                FROM pg_inherits i
                JOIN pg_class cp ON i.inhparent = cp.oid
                JOIN pg_namespace nsp ON cp.relnamespace = nsp.oid
                WHERE i.inhrelid = table_oid), '[]'::JSONB)
            )
        )
    ) INTO result_json;

    -- Возвращаем результат в зависимости от формата
    IF output_format = 'json' THEN
        RETURN QUERY SELECT result_json;
    ELSE
        -- Формат 'sections' - как в предыдущих версиях
        RETURN QUERY 
        SELECT jsonb_build_object('section', 'table_info', 'info', result_json->'table_info')
        UNION ALL
        SELECT jsonb_build_object('section', 'table_structure', 'info', result_json->'table_structure')
        UNION ALL
        SELECT jsonb_build_object('section', 'indexes', 'info', result_json->'indexes')
        UNION ALL
        SELECT jsonb_build_object('section', 'outgoing_constraints', 'info', result_json->'outgoing_constraints')
        UNION ALL
        SELECT jsonb_build_object('section', 'incoming_constraints', 'info', result_json->'incoming_constraints')
        UNION ALL
        SELECT jsonb_build_object('section', 'triggers', 'info', result_json->'triggers')
        UNION ALL
        SELECT jsonb_build_object('section', 'recursive_view_dependencies', 'info', result_json->'recursive_view_dependencies')
        UNION ALL
        SELECT jsonb_build_object('section', 'view_triggers', 'info', result_json->'view_triggers')
        UNION ALL
        SELECT jsonb_build_object('section', 'rls_policies', 'info', result_json->'rls_policies')
        UNION ALL
        SELECT jsonb_build_object('section', 'grants', 'info', result_json->'grants')
        UNION ALL
        SELECT jsonb_build_object('section', 'sequences', 'info', result_json->'sequences')
        UNION ALL
        SELECT jsonb_build_object('section', 'rules', 'info', result_json->'rules')
        UNION ALL
        SELECT jsonb_build_object('section', 'partitioning', 'info', result_json->'partitioning');
    END IF;

END;
$$;


--
-- Name: pcache_assistant_content(text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.pcache_assistant_content(resp text) RETURNS text
    LANGUAGE plpgsql IMMUTABLE PARALLEL SAFE
    AS $$
DECLARE
  j jsonb;
  c text;
BEGIN
  IF resp IS NULL THEN
    RETURN NULL;
  END IF;

  -- Пытаемся распарсить JSON; если не получилось — возвращаем как есть.
  BEGIN
    j := resp::jsonb;
  EXCEPTION WHEN others THEN
    RETURN resp;
  END;

  -- Пробуем стандартные пути OpenAI-стиля:
  c := COALESCE(
         j #>> '{choices,0,message,content}',
         j #>> '{choices,0,text}',
         j ->> 'content'
       );

  RETURN COALESCE(c, resp);
END;
$$;


--
-- Name: set_prompt_defaults(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.set_prompt_defaults() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    IF NEW.created_at IS NULL THEN
        NEW.created_at := NOW();
    END IF;

    IF NEW.prompt_hash IS NULL OR NEW.prompt_hash = '' THEN
        NEW.prompt_hash := md5(NEW.prompt);
    END IF;

    RETURN NEW;
END;
$$;


--
-- Name: tb_pcaches_set_updated(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tb_pcaches_set_updated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      NEW.updated := now();
      RETURN NEW;
    END;
    $$;


--
-- Name: tg_mark_updated_call_update_record(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_mark_updated_call_update_record() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.update_record(OLD.meta_id);
  RETURN NEW;
END $$;


--
-- Name: tg_record_meta_updated(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_record_meta_updated() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    BEGIN
      NEW.meta_updated := now();
      RETURN NEW;
    END
    $$;


--
-- Name: tg_soft_delete_call_delete_record(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_soft_delete_call_delete_record() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL; -- отменяем физический delete
END $$;


--
-- Name: tg_v_chat_groups_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_chat_groups_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END $$;


--
-- Name: tg_v_chat_groups_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_chat_groups_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_uid     integer;
  v_meta_id uuid;
BEGIN
  -- user_id по текущему логину
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unknown current_user %', current_user;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_meta_id := COALESCE(NEW.meta_id, public.create_record());

    INSERT INTO public.t_chat_groups(meta_id, user_id, parent_meta, group_name)
    VALUES (v_meta_id, v_uid, NEW.parent_meta, NEW.group_name);

    -- вернуть строку с корректным meta_id
    NEW.meta_id := v_meta_id;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.t_chat_groups
       SET parent_meta = NEW.parent_meta,
           group_name  = NEW.group_name
     WHERE meta_id = OLD.meta_id;

    PERFORM public.update_record(OLD.meta_id);
    RETURN NEW;
  END IF;

  RETURN NULL;
END $$;


--
-- Name: tg_v_chat_messages_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_chat_messages_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END $$;


--
-- Name: tg_v_chat_messages_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_chat_messages_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_uid       integer;
  v_meta_id   uuid;
  v_bytes     bytea;
  v_len       bigint;
  v_sha256    text;
  v_threshold integer := 4096;
  v_blob_meta uuid;
  v_inline    text;
  v_blob_id   uuid;
  v_seq       bigint;
BEGIN
  -- пользователь
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unknown current_user %', current_user;
  END IF;

  -- готовим контент из NEW.content
  v_bytes  := convert_to(COALESCE(NEW.content, ''), 'UTF8');
  v_len    := octet_length(v_bytes);
  v_sha256 := encode(digest(v_bytes, 'sha256'), 'hex');

  IF v_len <= v_threshold THEN
    v_inline  := NEW.content;
    v_blob_id := NULL;
  ELSE
    v_blob_meta := public.create_record();
    INSERT INTO public.t_blobs(meta_id, blob_sha256, blob_bytes_len, blob_content)
    VALUES (v_blob_meta, v_sha256, v_len, v_bytes);
    v_inline  := NULL;
    v_blob_id := v_blob_meta;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_meta_id := COALESCE(NEW.meta_id, public.create_record());

    -- 🔒 сериализация по сессии (адвизори-лок на текстовое представление UUID)
    PERFORM pg_advisory_xact_lock(hashtext(NEW.session_meta::text));
    -- безопасный расчёт seq без агрегата + FOR UPDATE
    SELECT COALESCE((
      SELECT t.seq
      FROM public.t_chat_messages t
      WHERE t.session_meta = NEW.session_meta
      ORDER BY t.seq DESC
      LIMIT 1
    ), 0) + 1
    INTO v_seq;

    INSERT INTO public.t_chat_messages(
      meta_id, session_meta, user_id, role, content_format,
      content_inline, blob_meta_id, content_len, content_sha256,
      seq, token_count, metadata
    ) VALUES (
      v_meta_id, NEW.session_meta, v_uid, NEW.role, NEW.content_format,
      v_inline, v_blob_id, v_len, v_sha256,
      v_seq, NEW.token_count, COALESCE(NEW.metadata,'{}'::jsonb)
    );

    PERFORM public.update_record(v_meta_id);
    PERFORM public.update_record(NEW.session_meta);
    UPDATE public.t_chat_sessions
       SET last_message_at = now(),
           total_tokens    = COALESCE(total_tokens,0) + COALESCE(NEW.token_count,0)
     WHERE meta_id = NEW.session_meta;

    NEW.meta_id := v_meta_id;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.t_chat_messages
       SET role           = NEW.role,
           content_format = NEW.content_format,
           token_count    = NEW.token_count,
           metadata       = COALESCE(NEW.metadata,'{}'::jsonb)
     WHERE meta_id = OLD.meta_id;

    PERFORM public.update_record(OLD.meta_id);
    RETURN NEW;
  END IF;

  RETURN NULL;
END $$;


--
-- Name: tg_v_chat_sessions_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_chat_sessions_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END $$;


--
-- Name: tg_v_chat_sessions_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_chat_sessions_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_uid     integer;
  v_meta_id uuid;
BEGIN
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unknown current_user %', current_user;
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_meta_id := COALESCE(NEW.meta_id, public.create_record());

    INSERT INTO public.t_chat_sessions(meta_id, user_id, group_meta, title, last_message_at, total_tokens)
    VALUES (v_meta_id, v_uid, NEW.group_meta, COALESCE(NEW.title, 'Новый чат'), NEW.last_message_at, COALESCE(NEW.total_tokens, 0));

    NEW.meta_id := v_meta_id;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.t_chat_sessions
       SET group_meta      = NEW.group_meta,
           title           = NEW.title,
           last_message_at = NEW.last_message_at,
           total_tokens    = COALESCE(NEW.total_tokens, 0)
     WHERE meta_id = OLD.meta_id;

    PERFORM public.update_record(OLD.meta_id);
    RETURN NEW;
  END IF;

  RETURN NULL;
END $$;


--
-- Name: tg_v_user_docs_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_user_docs_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END
$$;


--
-- Name: tg_v_user_docs_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_user_docs_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_bytes     bytea;
  v_len       bigint;
  v_sha256    text;
  v_threshold integer := 4096;
  v_blob_meta uuid;
  v_meta      uuid;
BEGIN
  IF NEW.user_content IS NULL THEN
    RAISE EXCEPTION 'user_content must not be NULL';
  END IF;

  v_bytes := convert_to(NEW.user_content, 'UTF8');
  v_len   := octet_length(v_bytes);
  v_sha256 := encode(digest(v_bytes, 'sha256'), 'hex');

  IF v_len > v_threshold THEN
    SELECT meta_id INTO v_blob_meta FROM public.t_blobs WHERE blob_sha256 = v_sha256;
    IF v_blob_meta IS NULL THEN
      v_blob_meta := public.create_record();
      INSERT INTO public.t_blobs(meta_id, blob_sha256, blob_bytes_len, blob_content)
      VALUES (v_blob_meta, v_sha256, v_len, v_bytes);
    END IF;
  END IF;

  v_meta := public.create_record();

  INSERT INTO public.t_user_docs(
    meta_id, user_id, user_title, user_lang_iso,
    user_content_format, user_content_inline,
    blob_meta_id, user_content_len, user_sha256
  ) VALUES (
    v_meta, NEW.user_id, NEW.user_title, NEW.user_lang_iso,
    COALESCE(NEW.user_content_format, 'text'::doc_format_t),
    CASE WHEN v_len <= v_threshold THEN NEW.user_content ELSE NULL END,
    CASE WHEN v_len  > v_threshold THEN v_blob_meta     ELSE NULL END,
    v_len, v_sha256
  );

  RETURN NULL;
END $$;


--
-- Name: tg_v_user_docs_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_user_docs_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_bytes     bytea;
  v_len       bigint;
  v_sha256    text;
  v_threshold integer := 4096;
  v_blob_meta uuid;
  v_set_inline text;
  v_set_blob   uuid;
BEGIN
  IF NEW.user_content IS DISTINCT FROM OLD.user_content THEN
    IF NEW.user_content IS NULL THEN
      v_set_inline := NULL;
      v_set_blob   := NULL;
      v_len        := 0;
      v_sha256     := '';
    ELSE
      v_bytes := convert_to(NEW.user_content, 'UTF8');
      v_len   := octet_length(v_bytes);
      v_sha256 := encode(digest(v_bytes, 'sha256'), 'hex');

      IF v_len > v_threshold THEN
        SELECT meta_id INTO v_blob_meta FROM public.t_blobs WHERE blob_sha256 = v_sha256;
        IF v_blob_meta IS NULL THEN
          v_blob_meta := public.create_record();
          INSERT INTO public.t_blobs(meta_id, blob_sha256, blob_bytes_len, blob_content)
          VALUES (v_blob_meta, v_sha256, v_len, v_bytes);
        END IF;
        v_set_inline := NULL;
        v_set_blob   := v_blob_meta;
      ELSE
        v_set_inline := NEW.user_content;
        v_set_blob   := NULL;
      END IF;
    END IF;

    UPDATE public.t_user_docs
       SET user_content_inline = v_set_inline,
           blob_meta_id        = v_set_blob,
           user_content_len    = v_len,
           user_sha256         = v_sha256
     WHERE meta_id = OLD.meta_id;
  END IF;

  UPDATE public.t_user_docs
     SET user_id             = COALESCE(NEW.user_id, public.t_user_docs.user_id),
         user_title          = COALESCE(NEW.user_title, public.t_user_docs.user_title),
         user_lang_iso       = COALESCE(NEW.user_lang_iso, public.t_user_docs.user_lang_iso),
         user_content_format = COALESCE(NEW.user_content_format, public.t_user_docs.user_content_format)
   WHERE meta_id = OLD.meta_id;

  PERFORM public.update_record(OLD.meta_id);
  RETURN NULL;
END $$;


--
-- Name: tg_v_user_docs_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.tg_v_user_docs_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_uid       integer;              -- текущий пользователь (из v_users по current_user)
  v_bytes     bytea;
  v_len       bigint;
  v_sha256    text;
  v_threshold integer := 4096;      -- порог inline (байты UTF-8)
  v_blob_meta uuid;
  v_meta      uuid;
  v_set_inline text;
  v_set_blob   uuid;
BEGIN
  -- A) Найти user_id текущего Postgres-пользователя
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;

  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'v_user_docs: current_user "%" не найден в v_users', current_user;
  END IF;

  -- B) Контент (если передан/меняется)
  IF (TG_OP = 'INSERT' AND NEW.user_content IS NULL)
     OR (TG_OP = 'UPDATE' AND NEW.user_content IS DISTINCT FROM OLD.user_content) THEN

    IF TG_OP = 'UPDATE' AND NEW.user_content IS NULL THEN
      -- явное зануление
      v_set_inline := NULL;
      v_set_blob   := NULL;
      v_len        := 0;
      v_sha256     := '';
    ELSE
      v_bytes  := convert_to(NEW.user_content, 'UTF8');
      v_len    := octet_length(v_bytes);
      v_sha256 := encode(digest(v_bytes, 'sha256'), 'hex');

      IF v_len > v_threshold THEN
        SELECT meta_id INTO v_blob_meta FROM public.t_blobs WHERE blob_sha256 = v_sha256;
        IF v_blob_meta IS NULL THEN
          v_blob_meta := public.create_record();
          INSERT INTO public.t_blobs(meta_id, blob_sha256, blob_bytes_len, blob_content)
          VALUES (v_blob_meta, v_sha256, v_len, v_bytes);
        END IF;
        v_set_inline := NULL;
        v_set_blob   := v_blob_meta;
      ELSE
        v_set_inline := NEW.user_content;
        v_set_blob   := NULL;
      END IF;
    END IF;
  ELSE
  	v_set_inline := NEW.user_content;
  END IF;

  -- C) Ветвление по операции
  IF TG_OP = 'INSERT' THEN
    v_meta := public.create_record();

    INSERT INTO public.t_user_docs(
      meta_id, user_id, user_title, user_lang_iso,
      user_content_format, user_content_inline,
      blob_meta_id, user_content_len, user_sha256
    ) VALUES (
      v_meta, v_uid, NEW.user_title, NEW.user_lang_iso,
      COALESCE(NEW.user_content_format, 'text'::doc_format_t),
      v_set_inline,
      v_set_blob,
      COALESCE(v_len, 0),
      COALESCE(v_sha256, '')
    );

    RETURN NULL;

  ELSIF TG_OP = 'UPDATE' THEN
    -- запретить изменение владельца
    IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
      RAISE EXCEPTION 'v_user_docs: изменение user_id запрещено';
    END IF;

    -- контент (если менялся)
    IF NEW.user_content IS DISTINCT FROM OLD.user_content THEN
      UPDATE public.t_user_docs
         SET user_content_inline = v_set_inline,
             blob_meta_id        = v_set_blob,
             user_content_len    = COALESCE(v_len, user_content_len),
             user_sha256         = COALESCE(v_sha256, user_sha256)
       WHERE meta_id = OLD.meta_id;
    END IF;

    -- метаданные
    UPDATE public.t_user_docs
       SET user_title          = COALESCE(NEW.user_title, public.t_user_docs.user_title),
           user_lang_iso       = COALESCE(NEW.user_lang_iso, public.t_user_docs.user_lang_iso),
           user_content_format = COALESCE(NEW.user_content_format, public.t_user_docs.user_content_format)
     WHERE meta_id = OLD.meta_id;

    PERFORM public.update_record(OLD.meta_id);
    RETURN NULL;
  END IF;

  RAISE EXCEPTION 'v_user_docs: неподдерживаемая операция %', TG_OP;
END
$$;


--
-- Name: touch_updated_at(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.touch_updated_at() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN NEW.updated_at = now(); RETURN NEW; END; $$;


--
-- Name: trg_prompts_rw_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_prompts_rw_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  k_id BIGINT; l_id BIGINT; v_id BIGINT;
BEGIN
  -- ⬇️ исправлено
  SELECT * INTO k_id, l_id, v_id
  FROM ensure_prompt_ids(OLD.pkey, OLD.lang, OLD.variant);

  DELETE FROM prompt_active
   WHERE key_id=k_id AND lang_id=l_id AND variant_id=v_id;

  -- историю версий не трогаем
  RETURN NULL; -- для INSTEAD OF DELETE возвращаем NULL
END; $$;


--
-- Name: trg_prompts_rw_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_prompts_rw_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  k_id BIGINT; l_id BIGINT; v_id BIGINT;
  new_version INT; new_ver_id BIGINT;
  make_active BOOLEAN;
BEGIN
  IF NEW.pkey IS NULL OR NEW.lang IS NULL OR NEW.variant IS NULL THEN
    RAISE EXCEPTION 'pkey/lang/variant required on INSERT';
  END IF;
  IF NEW.body IS NULL THEN
    RAISE EXCEPTION 'body required on INSERT';
  END IF;

  -- ⬇️ исправлено: SELECT * INTO ... FROM ensure_prompt_ids(...)
  SELECT * INTO k_id, l_id, v_id
  FROM ensure_prompt_ids(NEW.pkey, NEW.lang, NEW.variant);

  IF NEW.version IS NULL THEN
    SELECT COALESCE(MAX(version),0)+1
      INTO new_version
      FROM prompt_version
     WHERE key_id=k_id AND lang_id=l_id AND variant_id=v_id;
  ELSE
    new_version := NEW.version;
  END IF;

  INSERT INTO prompt_version(key_id,lang_id,variant_id,version,body,metadata,created_by)
  VALUES (k_id,l_id,v_id,new_version,NEW.body,COALESCE(NEW.metadata,'{}'::jsonb),current_user)
  RETURNING id INTO new_ver_id;

  make_active := COALESCE(NEW.is_active, TRUE);
  IF make_active THEN
    INSERT INTO prompt_active(key_id,lang_id,variant_id,version_id)
    VALUES (k_id,l_id,v_id,new_ver_id)
    ON CONFLICT (key_id,lang_id,variant_id)
    DO UPDATE SET version_id = EXCLUDED.version_id;
  END IF;

  -- для INSERT ... RETURNING на view вернём актуальные значения
  NEW.id := new_ver_id;
  NEW.version := new_version;
  NEW.is_active := make_active;
  RETURN NEW;
END; $$;


--
-- Name: trg_prompts_rw_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_prompts_rw_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  k_id BIGINT; l_id BIGINT; v_id BIGINT;
  target_ver_id BIGINT;
  next_version INT; new_ver_id BIGINT;
  body_changed BOOLEAN := (NEW.body IS DISTINCT FROM OLD.body);
  meta_changed BOOLEAN := (NEW.metadata IS DISTINCT FROM OLD.metadata);
BEGIN
  IF NEW.pkey  IS DISTINCT FROM OLD.pkey
     OR NEW.lang IS DISTINCT FROM OLD.lang
     OR NEW.variant IS DISTINCT FROM OLD.variant THEN
    RAISE EXCEPTION 'pkey/lang/variant are immutable on UPDATE';
  END IF;

  -- ⬇️ исправлено
  SELECT * INTO k_id, l_id, v_id
  FROM ensure_prompt_ids(OLD.pkey, OLD.lang, OLD.variant);

  -- 1) изменили body/metadata → создаём НОВУЮ версию (immutability)
  IF body_changed OR meta_changed THEN
    SELECT COALESCE(MAX(version),0)+1
      INTO next_version
      FROM prompt_version
     WHERE key_id=k_id AND lang_id=l_id AND variant_id=v_id;

    INSERT INTO prompt_version(key_id,lang_id,variant_id,version,body,metadata,created_by)
    VALUES (k_id,l_id,v_id,next_version,NEW.body,COALESCE(NEW.metadata,'{}'::jsonb),current_user)
    RETURNING id INTO new_ver_id;

    IF COALESCE(NEW.is_active, TRUE) THEN
      INSERT INTO prompt_active(key_id,lang_id,variant_id,version_id)
      VALUES (k_id,l_id,v_id,new_ver_id)
      ON CONFLICT (key_id,lang_id,variant_id)
      DO UPDATE SET version_id = EXCLUDED.version_id;
      NEW.is_active := TRUE;
    END IF;

    NEW.id := new_ver_id;
    NEW.version := next_version;
    RETURN NEW;
  END IF;

  -- 2) поменяли только version → переключаем активную
  IF NEW.version IS DISTINCT FROM OLD.version THEN
    SELECT id INTO target_ver_id
      FROM prompt_version
     WHERE key_id=k_id AND lang_id=l_id AND variant_id=v_id AND version=NEW.version;

    IF target_ver_id IS NULL THEN
      RAISE EXCEPTION 'Version % not found for %.%.%', NEW.version, OLD.pkey, OLD.lang, OLD.variant;
    END IF;

    INSERT INTO prompt_active(key_id,lang_id,variant_id,version_id)
    VALUES (k_id,l_id,v_id,target_ver_id)
    ON CONFLICT (key_id,lang_id,variant_id)
    DO UPDATE SET version_id = EXCLUDED.version_id;

    NEW.id := target_ver_id;
    NEW.is_active := TRUE;
    RETURN NEW;
  END IF;

  -- 3) поменяли только is_active → включить/выключить активность
  IF NEW.is_active IS DISTINCT FROM OLD.is_active THEN
    IF NEW.is_active THEN
      INSERT INTO prompt_active(key_id,lang_id,variant_id,version_id)
      VALUES (k_id,l_id,v_id,OLD.id)
      ON CONFLICT (key_id,lang_id,variant_id)
      DO UPDATE SET version_id = EXCLUDED.version_id;
    ELSE
      DELETE FROM prompt_active
       WHERE key_id=k_id AND lang_id=l_id AND variant_id=v_id;
    END IF;
    RETURN NEW;
  END IF;

  -- ничего важного не меняли → вернуть как есть
  RETURN NEW;
END; $$;


--
-- Name: trg_v__kind_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__kind_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            PERFORM public.delete_record(OLD.meta_id);
            DELETE FROM tb__kind WHERE meta_id = OLD.meta_id;
            RETURN OLD;
        END;
        $$;


--
-- Name: trg_v__kind_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__kind_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        DECLARE
            x_meta_id uuid;
        BEGIN
            x_meta_id := public.create_record();
            INSERT INTO tb__kind(meta_id, kind_name)
            VALUES (x_meta_id, NEW.name);
            RETURN NEW;
        END;
        $$;


--
-- Name: trg_v__kind_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__kind_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            PERFORM public.update_record(OLD.meta_id);
            UPDATE tb__kind SET  kind_name = NEW.name WHERE meta_id = OLD.meta_id;
            RETURN NEW;
        END;
        $$;


--
-- Name: trg_v__llms_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__llms_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.meta_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v__llms requires meta_id';
  END IF;

 PERFORM public.delete_record(OLD.meta_id);
  
  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v__llms_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__llms_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_meta_id   uuid;
BEGIN
  -- базовая вставка в таблицу
  
  INSERT INTO public.tb__llms (llm_name, llm_key, llm_url, llm_model, llm_interface, meta_id)
  VALUES (NEW.llm_name, NEW.llm_key, NEW.llm_url, NEW.llm_model, NEW.llm_interface, public.create_record())
  RETURNING meta_id
    INTO v_meta_id;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__llms_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__llms_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_rows integer;
BEGIN

  select public.update_record(OLD.meta_id);

  UPDATE public.tb__llms t
     SET llm_name      = COALESCE(NEW.llm_name, t.llm_name),
         llm_key       = COALESCE(NEW.llm_key, t.llm_key),
         llm_url       = COALESCE(NEW.llm_url, t.llm_url),
         llm_model     = COALESCE(NEW.llm_model, t.llm_model),
         llm_interface = COALESCE(NEW.llm_interface, t.llm_interface)
   WHERE t.meta_id = OLD.meta_id;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'llm_id % not found or soft-deleted', NEW.llm_id;
  END IF;

  -- вернуть актуальную строку
  SELECT *
    INTO NEW
    FROM public.v__llms v
   WHERE t.meta_id = OLD.meta_id
   LIMIT 1;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__pcaches_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__pcaches_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.meta_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v__pcaches requires meta_id';
  END IF;

 PERFORM public.delete_record(OLD.meta_id);
  
  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v__pcaches_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__pcaches_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_hash        text;
  v_existing_id uuid;
  v_new_id      uuid;
  x_meta_id uuid;
BEGIN

  v_hash := md5(NEW.pcache_prompt);
  
  SELECT t.meta_id
    INTO v_existing_id
    FROM public.v__pcaches t
   WHERE t.pcache_prompt_hash = v_hash
   LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    NEW.meta_id          := v_existing_id;
    NEW.pcache_prompt_hash := v_hash;
    RETURN NEW;
  END IF;

  -- вставка

  x_meta_id := public.create_record();
  
  INSERT INTO public.tb__pcaches (
    meta_id,
    pcache_prompt,
    pcache_prompt_hash,
    pcache_response,
    pcache_tokens_used
  ) VALUES (
    x_meta_id,
    NEW.pcache_prompt,
    v_hash,
    NEW.pcache_response,
    NEW.pcache_tokens_used
  )
  RETURNING meta_id INTO v_new_id;

  NEW.meta_id          := v_new_id;
  NEW.pcache_prompt_hash := v_hash;
  RETURN NEW;
END;
$$;


--
-- Name: trg_v__pcaches_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__pcaches_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_hash        text;
  v_existing_id uuid;
  v_new_id      uuid;
  x_meta_id uuid;
BEGIN

  v_hash := md5(NEW.pcache_prompt);
  
  SELECT t.meta_id
    INTO v_existing_id
    FROM public.v__pcaches t
   WHERE t.pcache_prompt_hash = v_hash
   LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    RETURN NEW;
  END IF;

  UPDATE public.tb__pcaches t
     SET pcache_prompt = NEW.pcache_prompt,
	     pcache_prompt_hash = v_hash,
		 pcache_response = NEW.pcache_response,
		 pcache_tokens_used = NEW.pcache_tokens_used
   WHERE t.meta_id = OLD.meta_id;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__prompt_keys_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__prompt_keys_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.meta_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v__prompts requires meta_id';
  END IF;

 PERFORM public.delete_record(OLD.meta_id);
  
  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v__prompt_keys_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__prompt_keys_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_meta_id   uuid;
BEGIN
  -- базовая вставка в таблицу
  
IF EXISTS (
    SELECT 1 FROM v__prompt_keys WHERE prompt_key_key = NEW.prompt_key_key
) THEN
    -- Запись существует
    RAISE NOTICE 'Запись с ключом % уже существует', NEW.prompt_key_key;
    -- Делай что нужно: RAISE EXCEPTION, RETURN NULL и т.д.
ELSE
  
  INSERT INTO public.tb__prompt_keys (prompt_key_key,meta_id)
  VALUES (NEW.prompt_key_key, public.create_record())
  RETURNING meta_id
    INTO v_meta_id;
END IF;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__prompt_keys_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__prompt_keys_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lower text;
BEGIN
  IF NEW.prompt_key_key IS NULL OR btrim(NEW.prompt_key_key) = '' THEN
    RAISE EXCEPTION 'prompt_key_key cannot be NULL/empty';
  END IF;

  v_lower := lower(btrim(NEW.prompt_key_key));

  PERFORM public.update_record(OLD.meta_id);

  UPDATE public.tb__prompt_keys t
     SET prompt_key_key = NEW.prompt_key_key
   WHERE t.meta_id = OLD.meta_id;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__prompts_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__prompts_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.meta_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v__prompts requires meta_id';
  END IF;

 PERFORM public.delete_record(OLD.meta_id);
  
  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v__prompts_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__prompts_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_meta_id   uuid;
  x_meta_id   uuid;
BEGIN
  -- базовая вставка в таблицу
  
  insert into public.v__prompt_keys (prompt_key_key) values (NEW.prompt_key_key);
  SELECT meta_id
  INTO v_meta_id
  FROM public.v__prompt_keys
  WHERE prompt_key_key = NEW.prompt_key_key
  LIMIT 1;
    
  RAISE NOTICE 'v_meta_id: % ', v_meta_id;
  
  x_meta_id := public.create_record();
  
  INSERT INTO public.tb__prompts (prompt_key_id,prompt_body, prompt_metadata,meta_id)
  VALUES (v_meta_id,NEW.prompt_body, NEW.prompt_metadata, x_meta_id);

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__prompts_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__prompts_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
declare
	v_meta_id uuid;
BEGIN

  insert into public.v__prompt_keys (prompt_key_key) values (NEW.prompt_key_key);
  SELECT meta_id
  INTO v_meta_id
  FROM public.v__prompt_keys
  WHERE prompt_key_key = NEW.prompt_key_key
  LIMIT 1;
  
    
  RAISE NOTICE 'v_meta_id: % ', v_meta_id;
  	
  UPDATE public.tb__prompts t
     SET prompt_body = NEW.prompt_body,
	     prompt_metadata = NEW.prompt_metadata,
         prompt_key_id = v_meta_id
   WHERE t.meta_id = OLD.meta_id;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v__unu_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__unu_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.meta_id IS NULL THEN
    RAISE EXCEPTION 'DELETE requires meta_id';
  END IF;

 PERFORM public.delete_record(OLD.meta_id);
  
  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v__users_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__users_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.meta_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v_users requires meta_id';
  END IF;

 PERFORM public.delete_record(OLD.meta_id);
  
  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v__users_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__users_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id bigint;
  v_lower text;
BEGIN
  IF NEW.user_user IS NULL OR btrim(NEW.user_user) = '' THEN
    RAISE EXCEPTION 'INSERT into v_users requires non-empty user_user';
  END IF;

  v_lower := lower(btrim(NEW.user_user));

  -- если есть активный с тем же user_user -> ошибка (уникальность)
  IF EXISTS (
      SELECT 1 FROM public.v__users 
       WHERE lower(user_user) = v_lower
  ) THEN
    RAISE EXCEPTION 'user_user ""%"" already exists', NEW.user_user;
  END IF;

    -- обычная вставка
  INSERT INTO public.tb__users (user_user, meta_id)
  VALUES (NEW.user_user, public.create_record())
  RETURNING meta_id INTO v_id;

  NEW.meta_id := v_id;
  RETURN NEW;
END;
$$;


--
-- Name: trg_v__users_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v__users_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lower text;
BEGIN
  IF NEW.user_user IS NULL OR btrim(NEW.user_user) = '' THEN
    RAISE EXCEPTION 'user_user cannot be NULL/empty';
  END IF;

  v_lower := lower(btrim(NEW.user_user));

  select public.update_record(OLD.meta_id);

  UPDATE public.tb_users t
     SET user_user = NEW.user_user
   WHERE t.meta_id = OLD.meta_id;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v_llms__ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_llms__ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_meta_id   uuid;
BEGIN
  -- базовая вставка в таблицу
  
  INSERT INTO public.tb__llms (llm_name, llm_key, llm_url, llm_model, llm_interface, meta_id)
  VALUES (NEW.llm_name, NEW.llm_key, NEW.llm_url, NEW.llm_model, NEW.llm_interface, public.create_record())
  RETURNING meta_id
    INTO v_meta_id;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v_llms_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_llms_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.llm_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v_llms requires llm_id';
  END IF;

  UPDATE public.tb_llms
     SET is_del = TRUE,
         updated = now()
   WHERE llm_id = OLD.llm_id;

  RETURN NULL; -- INSTEAD OF DELETE
END;
$$;


--
-- Name: trg_v_llms_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_llms_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_new_id   bigint;
  v_created  timestamptz;
  v_updated  timestamptz;
BEGIN
  -- базовая вставка в таблицу
  
  INSERT INTO public.tb_llms (llm_name, llm_key, llm_url, llm_model, llm_interface, meta_id)
  VALUES (NEW.llm_name, NEW.llm_key, NEW.llm_url, NEW.llm_model, NEW.llm_interface, public.create_record())
  RETURNING llm_id, created, updated
    INTO v_new_id, v_created, v_updated;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v_llms_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_llms_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_rows integer;
BEGIN

  UPDATE public.tb_llms t
     SET llm_name      = COALESCE(NEW.llm_name, t.llm_name),
         llm_key       = COALESCE(NEW.llm_key, t.llm_key),
         llm_url       = COALESCE(NEW.llm_url, t.llm_url),
         llm_model     = COALESCE(NEW.llm_model, t.llm_model),
         llm_interface = COALESCE(NEW.llm_interface, t.llm_interface),
         updated       = now()
   WHERE t.llm_id = NEW.llm_id
     AND t.is_del = FALSE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'llm_id % not found or soft-deleted', NEW.llm_id;
  END IF;

  -- вернуть актуальную строку
  SELECT *
    INTO NEW
    FROM public.v_llms v
   WHERE v.llm_id = NEW.llm_id
   LIMIT 1;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v_pcaches_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_pcaches_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.pcache_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v_pcaches requires pcache_id';
  END IF;

  UPDATE public.tb_pcaches
     SET is_del = TRUE
   WHERE pcache_id = OLD.pcache_id;

  RETURN NULL; -- INSTEAD OF DELETE
END;
$$;


--
-- Name: trg_v_pcaches_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_pcaches_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_hash        text;
  v_existing_id bigint;
  v_new_id      bigint;
BEGIN
  -- обязательные поля
  IF NEW.pcache_provider IS NULL OR btrim(NEW.pcache_provider) = '' THEN
    RAISE EXCEPTION 'pcache_provider is required';
  END IF;

  -- определить/посчитать hash
  IF NEW.pcache_prompt_hash IS NOT NULL AND btrim(NEW.pcache_prompt_hash) <> '' THEN
    v_hash := NEW.pcache_prompt_hash;
  ELSIF NEW.pcache_prompt IS NOT NULL THEN
    v_hash := md5(NEW.pcache_prompt);
  ELSE
    RAISE EXCEPTION 'provide pcache_prompt or pcache_prompt_hash';
  END IF;

  -- идемпотентность (пара provider + hash среди живых)
  SELECT t.pcache_id
    INTO v_existing_id
    FROM public.tb_pcaches t
   WHERE t.pcache_provider    = NEW.pcache_provider
     AND t.pcache_prompt_hash = v_hash
     AND t.is_del = FALSE
   LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    NEW.pcache_id          := v_existing_id;
    NEW.pcache_prompt_hash := v_hash;
    RETURN NEW;
  END IF;

  -- вставка
  INSERT INTO public.tb_pcaches (
    pcache_provider,
    pcache_prompt_hash,
    pcache_prompt,
    pcache_response_json,
    pcache_response_raw,
    pcache_tokens_used,
    pcache_agent_id,
    is_del
  ) VALUES (
    NEW.pcache_provider,
    v_hash,
    NEW.pcache_prompt,
    COALESCE(NEW.pcache_response_json, '{}'::jsonb),
    NEW.pcache_response_raw,
    NEW.pcache_tokens_used,
    NEW.pcache_agent_id,
    FALSE
  )
  RETURNING pcache_id INTO v_new_id;

  NEW.pcache_id          := v_new_id;
  NEW.pcache_prompt_hash := v_hash;
  RETURN NEW;
END;
$$;


--
-- Name: trg_v_pcaches_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_pcaches_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_hash text;
  v_rows integer;
BEGIN
  IF NEW.pcache_id IS NULL THEN
    RAISE EXCEPTION 'UPDATE v_pcaches requires pcache_id';
  END IF;

  -- вычислить итоговый hash
  IF NEW.pcache_prompt_hash IS NOT NULL AND NEW.pcache_prompt_hash IS DISTINCT FROM OLD.pcache_prompt_hash THEN
    v_hash := NEW.pcache_prompt_hash;
  ELSIF NEW.pcache_prompt IS NOT NULL AND NEW.pcache_prompt IS DISTINCT FROM OLD.pcache_prompt THEN
    v_hash := md5(NEW.pcache_prompt);
  ELSE
    v_hash := OLD.pcache_prompt_hash;
  END IF;

  UPDATE public.tb_pcaches t
     SET pcache_provider      = COALESCE(NEW.pcache_provider, t.pcache_provider),
         pcache_prompt_hash   = v_hash,
         pcache_prompt        = COALESCE(NEW.pcache_prompt, t.pcache_prompt),
         pcache_response_json = COALESCE(NEW.pcache_response_json, t.pcache_response_json),
         pcache_response_raw  = COALESCE(NEW.pcache_response_raw, t.pcache_response_raw),
         pcache_tokens_used   = COALESCE(NEW.pcache_tokens_used, t.pcache_tokens_used),
         pcache_agent_id      = COALESCE(NEW.pcache_agent_id, t.pcache_agent_id)
   WHERE t.pcache_id = NEW.pcache_id
     AND t.is_del = FALSE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'pcache_id % not found or soft-deleted', NEW.pcache_id;
  END IF;

  NEW.pcache_prompt_hash := v_hash;
  RETURN NEW;
END;
$$;


--
-- Name: trg_v_prompt_keys_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_prompt_keys_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.prompt_key_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v_prompt_keys requires prompt_key_id';
  END IF;

  UPDATE public.tb_prompt_keys
     SET is_del = TRUE
   WHERE prompt_key_id = OLD.prompt_key_id;

  RETURN NULL;  -- для INSTEAD OF DELETE
END;
$$;


--
-- Name: trg_v_prompt_keys_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_prompt_keys_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user_id       bigint;
  v_key_id        bigint;
  v_existing_id   bigint;
BEGIN
  IF NEW.prompt_key_key IS NULL OR btrim(NEW.prompt_key_key) = '' THEN
    RAISE EXCEPTION 'INSERT into v_prompt_keys requires non-empty prompt_key_key';
  END IF;

  -- Определяем user_id: приоритет NEW.user_id, иначе ищем по NEW.user_user
  IF NEW.user_id IS NOT NULL THEN
    v_user_id := NEW.user_id;
    -- Подтянем user_user, если не задан
    IF NEW.user_user IS NULL THEN
      SELECT u.user_user
        INTO NEW.user_user
        FROM public.v_users u
       WHERE u.user_id = v_user_id
       LIMIT 1;
    END IF;

  ELSIF NEW.user_user IS NOT NULL THEN
    SELECT u.user_id
      INTO v_user_id
      FROM public.v_users u
     WHERE u.user_user = NEW.user_user
     LIMIT 1;

    IF v_user_id IS NULL THEN
      -- создаём пользователя через view (сработает INSTEAD OF INSERT на v_users)
      INSERT INTO public.v_users (user_user) VALUES (NEW.user_user);
      SELECT u.user_id
        INTO v_user_id
        FROM public.v_users u
       WHERE u.user_user = NEW.user_user
       LIMIT 1;
    END IF;

  ELSE
    RAISE EXCEPTION 'INSERT into v_prompt_keys requires user_id or user_user';
  END IF;

  -- Если уже есть активная такая запись (idempotent insert) — вернём её
  SELECT pk.prompt_key_id
    INTO v_existing_id
    FROM public.tb_prompt_keys pk
   WHERE pk.user_id = v_user_id
     AND pk.prompt_key_key = NEW.prompt_key_key
     AND pk.is_del = FALSE
   LIMIT 1;

  IF v_existing_id IS NOT NULL THEN
    NEW.prompt_key_id := v_existing_id;
    NEW.user_id       := v_user_id;
    RETURN NEW;
  END IF;

  -- Вставляем новую запись
  INSERT INTO public.tb_prompt_keys (user_id, prompt_key_key, is_del)
  VALUES (v_user_id, NEW.prompt_key_key, FALSE)
  RETURNING prompt_key_id INTO v_key_id;

  -- Сформируем возвращаемую строку View
  NEW.prompt_key_id := v_key_id;
  NEW.user_id       := v_user_id;
  RETURN NEW;
END;
$$;


--
-- Name: trg_v_prompt_keys_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_prompt_keys_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user_id  bigint;
  v_dup_id   bigint;
  v_rows     integer;
BEGIN
  IF NEW.prompt_key_id IS NULL THEN
    RAISE EXCEPTION 'UPDATE v_prompt_keys requires prompt_key_id';
  END IF;

  -- идентификатор неизменяем
  IF NEW.prompt_key_id IS DISTINCT FROM OLD.prompt_key_id THEN
    RAISE EXCEPTION 'prompt_key_id is immutable';
  END IF;

  -- определить (возможно новый) user_id
  IF NEW.user_id IS NOT NULL AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    v_user_id := NEW.user_id;

  ELSIF NEW.user_user IS NOT NULL AND NEW.user_user IS DISTINCT FROM OLD.user_user THEN
    SELECT u.user_id
      INTO v_user_id
      FROM public.v_users u
     WHERE u.user_user = NEW.user_user
     LIMIT 1;

    IF v_user_id IS NULL THEN
      -- создаём через view (сработает её INSTEAD OF INSERT)
      INSERT INTO public.v_users (user_user) VALUES (NEW.user_user);
      SELECT u.user_id
        INTO v_user_id
        FROM public.v_users u
       WHERE u.user_user = NEW.user_user
       LIMIT 1;
    END IF;

  ELSE
    v_user_id := OLD.user_id;
  END IF;

  -- если меняется ключ — валидируем
  IF NEW.prompt_key_key IS NOT NULL AND NEW.prompt_key_key IS DISTINCT FROM OLD.prompt_key_key THEN
    IF btrim(NEW.prompt_key_key) = '' THEN
      RAISE EXCEPTION 'prompt_key_key cannot be empty';
    END IF;

    -- уникальность среди активных для того же user_id
    SELECT pk.prompt_key_id
      INTO v_dup_id
      FROM public.tb_prompt_keys pk
     WHERE pk.user_id = v_user_id
       AND pk.prompt_key_key = NEW.prompt_key_key
       AND pk.is_del = FALSE
       AND pk.prompt_key_id <> NEW.prompt_key_id
     LIMIT 1;

    IF v_dup_id IS NOT NULL THEN
      RAISE EXCEPTION 'duplicate prompt_key_key "%" for user_id %', NEW.prompt_key_key, v_user_id;
    END IF;
  END IF;

  -- апдейт базовой таблицы
  UPDATE public.tb_prompt_keys t
     SET user_id        = v_user_id,
         prompt_key_key = COALESCE(NEW.prompt_key_key, t.prompt_key_key)
   WHERE t.prompt_key_id = NEW.prompt_key_id
     AND t.is_del = FALSE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'prompt_key_id % not found or soft-deleted', NEW.prompt_key_id;
  END IF;

  -- подготовим возвращаемую строку
  NEW.user_id := v_user_id;
  IF NEW.user_user IS NULL THEN
    SELECT u.user_user
      INTO NEW.user_user
      FROM public.v_users u
     WHERE u.user_id = v_user_id
     LIMIT 1;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: trg_v_prompts_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_prompts_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.prompt_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v_prompts requires prompt_id';
  END IF;

  UPDATE tb_prompts
     SET is_del = TRUE
   WHERE prompt_id = OLD.prompt_id;

  -- INSTEAD OF DELETE должен вернуть NULL
  RETURN NULL;
END;
$$;


--
-- Name: trg_v_prompts_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_prompts_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user_id        bigint;
  v_prompt_key_id  bigint;
  v_new_prompt_id  bigint;
BEGIN
  IF NEW.user_user IS NULL OR btrim(NEW.user_user) = '' THEN
    RAISE EXCEPTION 'INSERT into v_prompts requires user_user';
  END IF;
  IF NEW.prompt_key_key IS NULL OR btrim(NEW.prompt_key_key) = '' THEN
    RAISE EXCEPTION 'INSERT into v_prompts requires prompt_key_key';
  END IF;

  -- user_id по user_user (создадим пользователя при отсутствии)
  SELECT u.user_id
    INTO v_user_id
    FROM public.v_users u
   WHERE u.user_user = NEW.user_user
   LIMIT 1;

  IF v_user_id IS NULL THEN
    INSERT INTO public.v_users (user_user) VALUES (NEW.user_user);
    SELECT u.user_id
      INTO v_user_id
      FROM public.v_users u
     WHERE u.user_user = NEW.user_user
     LIMIT 1;
  END IF;

  -- prompt_key_id по prompt_key_key и пользователю (создадим при отсутствии)
  SELECT k.prompt_key_id
    INTO v_prompt_key_id
    FROM public.v_prompt_keys k
   WHERE k.user_id = v_user_id
     AND k.prompt_key_key = NEW.prompt_key_key
   LIMIT 1;

  IF v_prompt_key_id IS NULL THEN
    INSERT INTO public.v_prompt_keys (user_id, prompt_key_key)
    VALUES (v_user_id, NEW.prompt_key_key)
    RETURNING prompt_key_id INTO v_prompt_key_id;
  END IF;

  -- вставка в базовую таблицу
  INSERT INTO public.tb_prompts (user_id, prompt_key_id, prompt_metadata, prompt_body, is_del)
  VALUES (v_user_id,
          v_prompt_key_id,
          COALESCE(NEW.prompt_metadata, '{}'::jsonb),
          NEW.prompt_body,
          FALSE)
  RETURNING prompt_id INTO v_new_prompt_id;

  -- вернуть заполнённую строку view
  NEW.user_id       := v_user_id;
  NEW.prompt_key_id := v_prompt_key_id;
  NEW.prompt_id     := v_new_prompt_id;
  NEW.prompt_metadata := COALESCE(NEW.prompt_metadata, '{}'::jsonb);
  RETURN NEW;
END;
$$;


--
-- Name: trg_v_prompts_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_prompts_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_user_id        bigint;
  v_prompt_key_id  bigint;
  v_rows           integer;
BEGIN
  IF NEW.prompt_id IS NULL THEN
    RAISE EXCEPTION 'UPDATE v_prompts requires prompt_id';
  END IF;

  -- 1) вычисляем (возможного нового) владельца
  IF NEW.user_user IS DISTINCT FROM OLD.user_user THEN
    IF NEW.user_user IS NULL OR btrim(NEW.user_user) = '' THEN
      RAISE EXCEPTION 'user_user cannot be NULL/empty';
    END IF;

    SELECT u.user_id
      INTO v_user_id
      FROM public.v_users u
     WHERE u.user_user = NEW.user_user
     LIMIT 1;

    IF v_user_id IS NULL THEN
      -- создаём через view (сработает INSTEAD OF INSERT на v_users)
      INSERT INTO public.v_users (user_user) VALUES (NEW.user_user);
      SELECT u.user_id
        INTO v_user_id
        FROM public.v_users u
       WHERE u.user_user = NEW.user_user
       LIMIT 1;
    END IF;
  ELSE
    v_user_id := OLD.user_id;
  END IF;

  -- 2) вычисляем (возможный новый) prompt_key_id под этого user_id
  IF NEW.prompt_key_key IS DISTINCT FROM OLD.prompt_key_key THEN
    IF NEW.prompt_key_key IS NULL OR btrim(NEW.prompt_key_key) = '' THEN
      RAISE EXCEPTION 'prompt_key_key cannot be NULL/empty';
    END IF;

    SELECT k.prompt_key_id
      INTO v_prompt_key_id
      FROM public.v_prompt_keys k
     WHERE k.user_id = v_user_id
       AND k.prompt_key_key = NEW.prompt_key_key
     LIMIT 1;

    IF v_prompt_key_id IS NULL THEN
      -- создаём ключ для данного пользователя
      INSERT INTO public.v_prompt_keys (user_id, prompt_key_key)
      VALUES (v_user_id, NEW.prompt_key_key)
      RETURNING prompt_key_id INTO v_prompt_key_id;
    END IF;
  ELSE
    v_prompt_key_id := OLD.prompt_key_id;
  END IF;

  -- 3) обновляем базовую таблицу
  UPDATE public.tb_prompts t
     SET user_id         = v_user_id,
         prompt_key_id   = v_prompt_key_id,
         prompt_metadata = NEW.prompt_metadata,
         prompt_body     = NEW.prompt_body
   WHERE t.prompt_id = NEW.prompt_id
     AND t.is_del = FALSE;

  GET DIAGNOSTICS v_rows = ROW_COUNT;
  IF v_rows = 0 THEN
    RAISE EXCEPTION 'prompt_id % not found or soft-deleted', NEW.prompt_id;
  END IF;

  -- 4) вернуть актуальную строку view (через NEW)
  NEW.user_id       := v_user_id;
  NEW.prompt_key_id := v_prompt_key_id;
  -- NEW.user_user и NEW.prompt_key_key уже содержат целевые значения
  RETURN NEW;
END;
$$;


--
-- Name: trg_v_users_del(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_users_del() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  IF OLD.user_id IS NULL THEN
    RAISE EXCEPTION 'DELETE v_users requires user_id';
  END IF;

  UPDATE public.tb_users
     SET is_del = TRUE
   WHERE user_id = OLD.user_id;

  RETURN NULL; -- INSTEAD OF DELETE должен вернуть NULL
END;
$$;


--
-- Name: trg_v_users_ins(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_users_ins() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_id bigint;
  v_lower text;
BEGIN
  IF NEW.user_user IS NULL OR btrim(NEW.user_user) = '' THEN
    RAISE EXCEPTION 'INSERT into v_users requires non-empty user_user';
  END IF;

  v_lower := lower(btrim(NEW.user_user));

  -- если есть активный с тем же user_user -> ошибка (уникальность)
  IF EXISTS (
      SELECT 1 FROM public.v_users 
       WHERE lower(user_user) = v_lower
  ) THEN
    RAISE EXCEPTION 'user_user "%" already exists', NEW.user_user;
  END IF;

    -- обычная вставка
  INSERT INTO public.tb_users (user_user, meta_id)
  VALUES (NEW.user_user, public.create_record())
  RETURNING user_id INTO v_id;

  NEW.user_id := v_id;
  RETURN NEW;
END;
$$;


--
-- Name: trg_v_users_upd(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.trg_v_users_upd() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_lower text;
BEGIN
  IF NEW.user_id IS NULL THEN
    RAISE EXCEPTION 'UPDATE v_users requires user_id';
  END IF;
  IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'user_id is immutable';
  END IF;

  IF NEW.user_user IS NULL OR btrim(NEW.user_user) = '' THEN
    RAISE EXCEPTION 'user_user cannot be NULL/empty';
  END IF;

  v_lower := lower(btrim(NEW.user_user));

  -- проверка уникальности среди других активных пользователей
  IF EXISTS (
      SELECT 1 FROM public.tb_users t
       WHERE lower(t.user_user) = v_lower
         AND t.is_del = FALSE
         AND t.user_id <> NEW.user_id
  ) THEN
    RAISE EXCEPTION 'user_user "%" already exists', NEW.user_user;
  END IF;

  UPDATE public.tb_users t
     SET user_user = NEW.user_user
   WHERE t.user_id = NEW.user_id
     AND t.is_del = FALSE;

  RETURN NEW;
END;
$$;


--
-- Name: update_record(uuid); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.update_record(p_meta_id uuid) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
    affected integer;
BEGIN
    -- работаем через ВЬЮ, чтобы сработали INSTEAD OF-триггеры
    UPDATE public.v_record_meta
       SET updated = now()
     WHERE id = p_meta_id;

    GET DIAGNOSTICS affected = ROW_COUNT;
    IF affected = 0 THEN
        RAISE EXCEPTION 'record_meta with id % not found', p_meta_id
            USING ERRCODE = 'P0002'; -- no_data_found
    END IF;

    RETURN p_meta_id;
END;
$$;


--
-- Name: upsert_user_doc(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.upsert_user_doc(title text, content text) RETURNS bigint
    LANGUAGE plpgsql
    AS $$
DECLARE
  exists_flag boolean;
  result_count bigint;
BEGIN
  SELECT true INTO exists_flag
  FROM v_user_docs
  WHERE user_title = title
  LIMIT 1;

  IF exists_flag IS TRUE THEN
    UPDATE v_user_docs
    SET user_content = content
    WHERE user_title = title;
  ELSE
    INSERT INTO v_user_docs (user_title, user_content)
    VALUES (title, content);
  END IF;

  SELECT count(*) INTO result_count
  FROM v_user_docs
  WHERE user_title = title;
  
  RETURN result_count;
END;
$$;


--
-- Name: user_docs_insert(uuid, text, text, public.doc_format_t, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.user_docs_insert(p_user_id uuid, p_user_title text, p_user_lang_iso text, p_user_content_format public.doc_format_t, p_user_content text) RETURNS uuid
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_meta_id    uuid;
  v_blob_meta  uuid;
  v_bytes      bytea;
  v_len        bigint;
  v_sha256     text;
  v_threshold  integer := 4096; -- граница inline по байтам UTF-8
BEGIN
  IF p_user_content IS NULL THEN
    RAISE EXCEPTION 'content must not be NULL';
  END IF;

  v_bytes  := convert_to(p_user_content, 'UTF8');
  v_len    := octet_length(v_bytes);
  v_sha256 := encode(digest(v_bytes, 'sha256'), 'hex');

  -- blob (дедупликация по sha256)
  IF v_len > v_threshold THEN
    SELECT meta_id INTO v_blob_meta
    FROM public.t_blobs
    WHERE blob_sha256 = v_sha256;

    IF v_blob_meta IS NULL THEN
      v_blob_meta := public.create_record();
      INSERT INTO public.t_blobs (meta_id, blob_sha256, blob_bytes_len, blob_content)
      VALUES (v_blob_meta, v_sha256, v_len, v_bytes);
    END IF;
  END IF;

  -- meta для документа
  v_meta_id := public.create_record();

  INSERT INTO public.t_user_docs(
    meta_id, user_id, user_title, user_lang_iso,
    user_content_format, user_content_inline,
    blob_meta_id, user_content_len, user_sha256
  ) VALUES (
    v_meta_id, p_user_id, p_user_title, p_user_lang_iso,
    p_user_content_format,
    CASE WHEN v_len <= v_threshold THEN p_user_content ELSE NULL END,
    CASE WHEN v_len  > v_threshold THEN v_blob_meta     ELSE NULL END,
    v_len, v_sha256
  );

  RETURN v_meta_id;
END
$$;


--
-- Name: v__artifact_kinds_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifact_kinds_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
          PERFORM public.delete_record(OLD.meta_id);
          RETURN OLD;
      END;$$;


--
-- Name: v__artifact_kinds_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifact_kinds_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      DECLARE x uuid;
      BEGIN
          x := public.create_record();
          INSERT INTO public.tb__artifact_kinds (meta_id, artifact_kind_code, artifact_kind_name) VALUES (x, NEW.artifact_kind_code, NEW.artifact_kind_name);
          RETURN NEW;
      END;$$;


--
-- Name: v__artifact_kinds_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifact_kinds_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            PERFORM public.update_record(OLD.meta_id);
            UPDATE public.tb__artifact_kinds SET artifact_kind_code = NEW.artifact_kind_code, artifact_kind_name = NEW.artifact_kind_name WHERE meta_id = OLD.meta_id;
            RETURN NEW;
        END;$$;


--
-- Name: v__artifact_subkinds_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifact_subkinds_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.delete_record(OLD.meta_id);

    NULL; -- no cascade

    RETURN OLD;
END$$;


--
-- Name: v__artifact_subkinds_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifact_subkinds_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    x_child uuid;
    x_parent uuid;
    cnt int;
BEGIN
    IF NEW.artifact_subkind_artifact_kind_meta_id IS NOT NULL THEN
        x_parent := NEW.artifact_subkind_artifact_kind_meta_id;
    ELSE
        IF NEW.artifact_kind_code IS NOT NULL THEN
            SELECT count(*) INTO cnt
            FROM public.tb__artifact_kinds
            WHERE artifact_kind_code = NEW.artifact_kind_code;

            IF cnt = 0 THEN
                x_parent := public.create_record();
                INSERT INTO public.tb__artifact_kinds (meta_id, artifact_kind_code, artifact_kind_name) VALUES (x_parent, NEW.artifact_kind_code, NEW.artifact_kind_name);
            ELSIF cnt = 1 THEN
                SELECT meta_id INTO x_parent
                FROM public.tb__artifact_kinds
                WHERE artifact_kind_code = NEW.artifact_kind_code
                LIMIT 1;
            ELSE
                RAISE EXCEPTION USING MESSAGE = 'Ambiguous parent by artifact_kind_code, ' || cnt::text || ' records match in public.tb__artifact_kinds';
            END IF;
        ELSE
            RAISE EXCEPTION USING MESSAGE = 'Either NEW.artifact_subkind_artifact_kind_meta_id or NEW.artifact_kind_code must be provided';
        END IF;
    END IF;

    x_child := public.create_record();
    INSERT INTO public.tb__artifact_subkinds (meta_id, artifact_subkind_artifact_kind_meta_id, artifact_subkind_artifact_subkind_code, artifact_subkind_artifact_subkind_name) VALUES (x_child, x_parent, NEW.artifact_subkind_artifact_subkind_code, NEW.artifact_subkind_artifact_subkind_name);

    RETURN NEW;
END$$;


--
-- Name: v__artifact_subkinds_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifact_subkinds_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_parent uuid;
    cnt int;
BEGIN
    IF NEW.artifact_subkind_artifact_kind_meta_id IS NOT NULL THEN
        new_parent := NEW.artifact_subkind_artifact_kind_meta_id;
    ELSIF NEW.artifact_kind_code IS NOT NULL THEN
        SELECT count(*) INTO cnt
        FROM public.tb__artifact_kinds
        WHERE artifact_kind_code = NEW.artifact_kind_code;

        IF cnt = 0 THEN
            new_parent := public.create_record();
            INSERT INTO public.tb__artifact_kinds (meta_id, artifact_kind_code, artifact_kind_name) VALUES (new_parent, NEW.artifact_kind_code, NEW.artifact_kind_name);
        ELSIF cnt > 1 THEN
            RAISE EXCEPTION USING MESSAGE = 'Ambiguous parent by artifact_kind_code, ' || cnt::text || ' records match in public.tb__artifact_kinds';
        ELSE
            SELECT meta_id INTO new_parent
            FROM public.tb__artifact_kinds
            WHERE artifact_kind_code = NEW.artifact_kind_code
            LIMIT 1;

            PERFORM public.update_record(new_parent);
            UPDATE public.tb__artifact_kinds SET artifact_kind_code = NEW.artifact_kind_code, artifact_kind_name = NEW.artifact_kind_name WHERE meta_id = new_parent;
        END IF;
    ELSE
        new_parent := OLD.artifact_subkind_artifact_kind_meta_id;
    END IF;

    PERFORM public.update_record(OLD.meta_id);
    UPDATE public.tb__artifact_subkinds SET artifact_subkind_artifact_subkind_code = NEW.artifact_subkind_artifact_subkind_code, artifact_subkind_artifact_subkind_name = NEW.artifact_subkind_artifact_subkind_name, artifact_subkind_artifact_kind_meta_id = new_parent WHERE meta_id = OLD.meta_id;

    RETURN NEW;
END$$;


--
-- Name: v__artifacts_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifacts_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.delete_record(OLD.meta_id);

    NULL; -- no cascade

    RETURN OLD;
END$$;


--
-- Name: v__artifacts_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifacts_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    x_child uuid;
    x_parent uuid;
    cnt int;
BEGIN
    IF NEW.blob_meta_id IS NOT NULL THEN
        x_parent := NEW.blob_meta_id;
    ELSE
        IF NEW.blob_sha256 IS NOT NULL THEN
            SELECT count(*) INTO cnt
            FROM public.tb__blobs
            WHERE blob_sha256 = NEW.blob_sha256;

            IF cnt = 0 THEN
                x_parent := public.create_record();
                INSERT INTO public.tb__blobs (meta_id, blob_sha256, blob_bytes_len, blob_content) VALUES (x_parent, NEW.blob_sha256, NEW.blob_bytes_len, NEW.blob_content);
            ELSIF cnt = 1 THEN
                SELECT meta_id INTO x_parent
                FROM public.tb__blobs
                WHERE blob_sha256 = NEW.blob_sha256
                LIMIT 1;
            ELSE
                RAISE EXCEPTION USING MESSAGE = 'Ambiguous parent by blob_sha256, ' || cnt::text || ' records match in public.tb__blobs';
            END IF;
        ELSE
            RAISE EXCEPTION USING MESSAGE = 'Either NEW.blob_meta_id or NEW.blob_sha256 must be provided';
        END IF;
    END IF;

    x_child := public.create_record();
    INSERT INTO public.tb__artifacts (meta_id, blob_meta_id, kind_meta_id, subkind_meta_id, artifact_content, artifact_content_len) VALUES (x_child, x_parent, NEW.kind_meta_id, NEW.subkind_meta_id, NEW.artifact_content, NEW.artifact_content_len);

    RETURN NEW;
END$$;


--
-- Name: v__artifacts_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__artifacts_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    new_parent uuid;
    cnt int;
BEGIN
    IF NEW.blob_meta_id IS NOT NULL THEN
        new_parent := NEW.blob_meta_id;
    ELSIF NEW.blob_sha256 IS NOT NULL THEN
        SELECT count(*) INTO cnt
        FROM public.tb__blobs
        WHERE blob_sha256 = NEW.blob_sha256;

        IF cnt = 0 THEN
            new_parent := public.create_record();
            INSERT INTO public.tb__blobs (meta_id, blob_sha256, blob_bytes_len, blob_content) VALUES (new_parent, NEW.blob_sha256, NEW.blob_bytes_len, NEW.blob_content);
        ELSIF cnt > 1 THEN
            RAISE EXCEPTION USING MESSAGE = 'Ambiguous parent by blob_sha256, ' || cnt::text || ' records match in public.tb__blobs';
        ELSE
            SELECT meta_id INTO new_parent
            FROM public.tb__blobs
            WHERE blob_sha256 = NEW.blob_sha256
            LIMIT 1;

            PERFORM public.update_record(new_parent);
            UPDATE public.tb__blobs SET blob_sha256 = NEW.blob_sha256, blob_bytes_len = NEW.blob_bytes_len, blob_content = NEW.blob_content WHERE meta_id = new_parent;
        END IF;
    ELSE
        new_parent := OLD.blob_meta_id;
    END IF;

    PERFORM public.update_record(OLD.meta_id);
    UPDATE public.tb__artifacts SET kind_meta_id = NEW.kind_meta_id, subkind_meta_id = NEW.subkind_meta_id, artifact_content = NEW.artifact_content, artifact_content_len = NEW.artifact_content_len, blob_meta_id = new_parent WHERE meta_id = OLD.meta_id;

    RETURN NEW;
END$$;


--
-- Name: v__blobs_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__blobs_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      BEGIN
          PERFORM public.delete_record(OLD.meta_id);
          RETURN OLD;
      END;$$;


--
-- Name: v__blobs_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__blobs_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
      DECLARE x uuid;
      BEGIN
          x := public.create_record();
          INSERT INTO public.tb__blobs (meta_id, blob_sha256, blob_bytes_len, blob_content) VALUES (x, NEW.blob_sha256, NEW.blob_bytes_len, NEW.blob_content);
          RETURN NEW;
      END;$$;


--
-- Name: v__blobs_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__blobs_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
        BEGIN
            PERFORM public.update_record(OLD.meta_id);
            UPDATE public.tb__blobs SET blob_sha256 = NEW.blob_sha256, blob_bytes_len = NEW.blob_bytes_len, blob_content = NEW.blob_content WHERE meta_id = OLD.meta_id;
            RETURN NEW;
        END;$$;


--
-- Name: v__kind_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__kind_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.delete_record(OLD.meta_id);
    RETURN OLD;
END;
$$;


--
-- Name: v__kind_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__kind_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    x uuid;
BEGIN
    x := public.create_record();
    INSERT INTO public.tb__kind (
        meta_id, 
        kind_name, 
        kind_age, 
        kind_full_name, 
        kind_price, 
        kind_created_at
    ) VALUES (
        x, 
        NEW.name, 
        NEW.age, 
        NEW."full name", 
        NEW.price, 
        NEW.created_at
    );
    RETURN NEW;
END;
$$;


--
-- Name: v__kind_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__kind_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.update_record(OLD.meta_id);
    UPDATE public.tb__kind SET
        kind_name = NEW.name,
        kind_age = NEW.age,
        kind_full_name = NEW."full name",
        kind_price = NEW.price,
        kind_created_at = NEW.created_at
    WHERE meta_id = OLD.meta_id;
    RETURN NEW;
END;
$$;


--
-- Name: v__pcaches_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v__pcaches_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  x uuid;
BEGIN
  IF TG_OP = 'INSERT' THEN
    -- создаём meta и пишем строку в таблицу
    x := public.create_record();
    INSERT INTO public.t_pcaches(
      meta_id,
      pcache_prompt,
      pcache_prompt_hash,
      pcache_response,
      pcache_tokens_used
    ) VALUES (
      x,
      NEW.pcache_prompt,
      NEW.pcache_prompt_hash,
      NEW.pcache_response,
      COALESCE(NEW.pcache_tokens_used, 0)
    );

    NEW.meta_id := x;
    NEW.pcache_tokens_used := COALESCE(NEW.pcache_tokens_used, 0);
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    -- фиксируем изменение meta и обновляем строку
    PERFORM public.update_record(OLD.meta_id);

    UPDATE public.t_pcaches t
       SET pcache_prompt       = NEW.pcache_prompt,
           pcache_prompt_hash  = NEW.pcache_prompt_hash,
           pcache_response     = NEW.pcache_response,
           pcache_tokens_used  = COALESCE(NEW.pcache_tokens_used, t.pcache_tokens_used)
     WHERE t.meta_id = OLD.meta_id;

    NEW.meta_id := OLD.meta_id;
    NEW.pcache_tokens_used := COALESCE(NEW.pcache_tokens_used, OLD.pcache_tokens_used);
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: v_artifacts_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_artifacts_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN OLD;
END;
$$;


--
-- Name: v_artifacts_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_artifacts_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  x uuid;
BEGIN
  x := public.create_record();
  INSERT INTO public.t_artifacts (
    meta_id,
    artifact_kind_meta_id,
    artifact_subkind_meta_id,
    artifact_content,
    artifact_content_len,
    artifact_blob_meta_id
  )
  VALUES (
    x,
    NEW.artifact_kind_meta_id,
    NEW.artifact_subkind_meta_id,
    NEW.artifact_content,
    NEW.artifact_content_len,
    NEW.artifact_blob_meta_id
  );
  -- Пробросим meta_id наружу (полезно, если вызывающий его не задавал)
  NEW.meta_id := x;
  RETURN NEW;
END$$;


--
-- Name: v_artifacts_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_artifacts_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  PERFORM public.update_record(OLD.meta_id);

  UPDATE public.t_artifacts SET
      artifact_kind_meta_id    = NEW.artifact_kind_meta_id,
      artifact_subkind_meta_id = NEW.artifact_subkind_meta_id,
      artifact_content         = NEW.artifact_content,
      artifact_content_len     = NEW.artifact_content_len,
      artifact_blob_meta_id    = NEW.artifact_blob_meta_id
  WHERE meta_id = OLD.meta_id;

  RETURN NEW;
END$$;


--
-- Name: v_artifacts_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_artifacts_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_kind_code text;
  v_sub_code  text;
  v_len       integer;
  x uuid;
BEGIN
  -- всегда пересчитываем длину из контента (не доверяем входному числу)
  v_len := CASE
             WHEN NEW.artifact_content IS NOT NULL
             THEN char_length(NEW.artifact_content)
             ELSE NULL
           END;

  IF TG_OP = 'INSERT' THEN
    v_kind_code := COALESCE(
      NEW.artifact_kind_code,
      (SELECT ak.artifact_kind_code
         FROM dict.artifact_kinds(NULL::text, NEW.artifact_kind_name::text) ak
         LIMIT 1)
    );
    IF v_kind_code IS NULL THEN
      RAISE EXCEPTION USING MESSAGE =
        format('artifact_kind_code or artifact_kind_name must be provided/resolvable (got name=%s, code=%s)',
               NEW.artifact_kind_name, NEW.artifact_kind_code);
    END IF;

    v_sub_code := COALESCE(
      NEW.artifact_subkind_code,
      (SELECT s.artifact_subkind_code
         FROM dict.artifact_subkinds(NULL::text, NEW.artifact_subkind_name::text, v_kind_code::text, NULL::text) s
         LIMIT 1)
    );
    IF v_sub_code IS NULL THEN
      RAISE EXCEPTION USING MESSAGE =
        format('artifact_subkind_code or artifact_subkind_name must be provided/resolvable (kind=%s, subname=%s, subcode=%s)',
               v_kind_code, NEW.artifact_subkind_name, NEW.artifact_subkind_code);
    END IF;

    x := public.create_record();
    INSERT INTO public.t_artifacts(
      meta_id, artifact_kind_code, artifact_subkind_code,
      artifact_content, artifact_content_len
    ) VALUES (
      x, v_kind_code, v_sub_code,
      NEW.artifact_content, v_len
    );

    NEW.meta_id := x;
    NEW.artifact_kind_code    := v_kind_code;
    NEW.artifact_subkind_code := v_sub_code;
    NEW.artifact_content_len  := v_len;
    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    v_kind_code := COALESCE(
      NEW.artifact_kind_code,
      CASE WHEN NEW.artifact_kind_name IS DISTINCT FROM OLD.artifact_kind_name
           THEN (SELECT ak.artifact_kind_code
                   FROM dict.artifact_kinds(NULL::text, NEW.artifact_kind_name::text) ak LIMIT 1)
           ELSE OLD.artifact_kind_code END
    );
    IF v_kind_code IS NULL THEN
      v_kind_code := OLD.artifact_kind_code;
    END IF;

    v_sub_code := COALESCE(
      NEW.artifact_subkind_code,
      CASE WHEN (NEW.artifact_subkind_name IS DISTINCT FROM OLD.artifact_subkind_name)
              OR (v_kind_code IS DISTINCT FROM OLD.artifact_kind_code)
           THEN (SELECT s.artifact_subkind_code
                   FROM dict.artifact_subkinds(NULL::text, NEW.artifact_subkind_name::text, v_kind_code::text, NULL::text) s
                  LIMIT 1)
           ELSE OLD.artifact_subkind_code END
    );
    IF v_sub_code IS NULL THEN
      v_sub_code := OLD.artifact_subkind_code;
    END IF;

    PERFORM public.update_record(OLD.meta_id);

    UPDATE public.t_artifacts t
       SET artifact_kind_code     = v_kind_code,
           artifact_subkind_code  = v_sub_code,
           artifact_content       = NEW.artifact_content,
           artifact_content_len   = COALESCE(
                                      CASE WHEN NEW.artifact_content IS DISTINCT FROM OLD.artifact_content
                                           THEN char_length(NEW.artifact_content)
                                           ELSE OLD.artifact_content_len END,
                                      OLD.artifact_content_len
                                    )
     WHERE t.meta_id = OLD.meta_id;

    NEW.artifact_kind_code    := v_kind_code;
    NEW.artifact_subkind_code := v_sub_code;
    NEW.artifact_content_len  := COALESCE(
                                    CASE WHEN NEW.artifact_content IS DISTINCT FROM OLD.artifact_content
                                         THEN char_length(NEW.artifact_content)
                                         ELSE OLD.artifact_content_len END,
                                    OLD.artifact_content_len
                                  );
    RETURN NEW;
  END IF;

  RETURN NEW;
END;
$$;


--
-- Name: v_kinds_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_kinds_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
    PERFORM public.delete_record(OLD.meta_id);
    RETURN OLD;
END;
$$;


--
-- Name: v_kinds_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_kinds_upsert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE
    v_code text;
    x uuid;
BEGIN
    IF TG_OP = 'INSERT' THEN
        -- Проверяем, задан ли kind_code
        IF NEW.kind_code IS NULL THEN
            RAISE EXCEPTION USING MESSAGE = 'kind_code must be provided';
        END IF;

        -- Проверяем дубликат по коду
        IF EXISTS (SELECT 1 FROM public.t_kinds WHERE kind_code = NEW.kind_code) THEN
            RAISE EXCEPTION USING MESSAGE = format('kind_code already exists: %s', NEW.kind_code);
        END IF;

        x := public.create_record();
        INSERT INTO public.t_kinds (meta_id, kind_code, kind_name)
        VALUES (x, NEW.kind_code, NEW.kind_name);

        NEW.meta_id := x;
        RETURN NEW;

    ELSIF TG_OP = 'UPDATE' THEN
        -- Запрещаем менять kind_code
        IF NEW.kind_code IS DISTINCT FROM OLD.kind_code THEN
            RAISE EXCEPTION USING MESSAGE = 'Updating kind_code is not allowed';
        END IF;

        PERFORM public.update_record(OLD.meta_id);

        UPDATE public.t_kinds
        SET kind_name = NEW.kind_name
        WHERE meta_id = OLD.meta_id;

        RETURN NEW;
    END IF;

    RETURN NULL;
END;
$$;


--
-- Name: v_record_meta_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_record_meta_delete() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE tb_record_meta
     SET is_del = true, updated = now()
   WHERE id = OLD.id;
  RETURN OLD;
END;
$$;


--
-- Name: v_record_meta_insert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_record_meta_insert() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
DECLARE new_id uuid;
BEGIN
  INSERT INTO tb_record_meta(id, created, updated, is_del)
  VALUES (
    COALESCE(NEW.id, gen_random_uuid()),
    COALESCE(NEW.created, now()),
    COALESCE(NEW.updated, now()),
    COALESCE(NEW.is_del, false)
  )
  RETURNING id INTO new_id;

  -- возвращаем фактические значения
  SELECT id, created, updated, is_del
    INTO NEW.id, NEW.created, NEW.updated, NEW.is_del
  FROM tb_record_meta WHERE id = new_id;

  RETURN NEW;
END;
$$;


--
-- Name: v_record_meta_update(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_record_meta_update() RETURNS trigger
    LANGUAGE plpgsql
    AS $$
BEGIN
  UPDATE tb_record_meta
     SET -- created принципиально не меняем
         updated = COALESCE(NEW.updated, now()),
         is_del  = COALESCE(NEW.is_del, is_del)
   WHERE id = OLD.id;

  SELECT id, created, updated, is_del
    INTO NEW.id, NEW.created, NEW.updated, NEW.is_del
  FROM tb_record_meta WHERE id = OLD.id;

  RETURN NEW;
END;
$$;


--
-- Name: v_sub_kinds_delete(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_sub_kinds_delete() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
BEGIN
  DELETE FROM public.t_sub_kinds t
  WHERE t.meta_id = OLD.meta_id;
  RETURN OLD;
END;
$$;


--
-- Name: v_sub_kinds_upsert(); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.v_sub_kinds_upsert() RETURNS trigger
    LANGUAGE plpgsql SECURITY DEFINER
    SET search_path TO 'public', 'pg_temp'
    AS $$
DECLARE
  v_meta_id     uuid;
  v_kind_meta   uuid;
  v_code        text;
  v_row         public.v_sub_kinds%ROWTYPE;
BEGIN
  -- нормализация входных
  v_code := NULLIF(btrim(NEW.sub_kind_code), '');
  IF v_code IS NULL THEN
    RAISE EXCEPTION 'sub_kind_code must be non-empty'
      USING ERRCODE = '23514'; -- check_violation
  END IF;

  -- разрешаем прислать или kind_meta_id, или kind_code
  v_kind_meta := (SELECT k.meta_id FROM public.t_kinds k WHERE k.kind_code = NEW.kind_code);
  
  IF v_kind_meta IS NULL THEN
    RAISE EXCEPTION 'kind_meta_id or kind_code is required (and kind_code must exist in t_kinds)'
      USING ERRCODE = '22023'; -- invalid_parameter_value
  END IF;

  IF TG_OP = 'INSERT' THEN
    v_meta_id := COALESCE(NEW.meta_id, gen_random_uuid());

    IF NEW.meta_id IS NOT NULL THEN
      -- Вариант 1: прислали meta_id → upsert по PK(meta_id)
      INSERT INTO public.t_sub_kinds AS t (
        meta_id, sub_kind_code, sub_kind_name, sub_kind_value,
        sub_kind_type, kind_meta_id, sub_kind_default_value
      )
      VALUES (
        v_meta_id, v_code, NEW.sub_kind_name, NEW.sub_kind_value,
        NEW.sub_kind_type, v_kind_meta, NEW.sub_kind_default_value
      )
      ON CONFLICT (meta_id) DO UPDATE
      SET sub_kind_code          = EXCLUDED.sub_kind_code,
          sub_kind_name          = EXCLUDED.sub_kind_name,
          sub_kind_value         = EXCLUDED.sub_kind_value,
          sub_kind_type          = EXCLUDED.sub_kind_type,
          kind_meta_id           = EXCLUDED.kind_meta_id,
          sub_kind_default_value = EXCLUDED.sub_kind_default_value;
    ELSE
      -- Вариант 2: meta_id не прислали → upsert по уникальной паре (sub_kind_code, kind_meta_id)
      INSERT INTO public.t_sub_kinds AS t (
        meta_id, sub_kind_code, sub_kind_name, sub_kind_value,
        sub_kind_type, kind_meta_id, sub_kind_default_value
      )
      VALUES (
        v_meta_id, v_code, NEW.sub_kind_name, NEW.sub_kind_value,
        NEW.sub_kind_type, v_kind_meta, NEW.sub_kind_default_value
      )
      ON CONFLICT ON CONSTRAINT ux_t_sub_kinds_per_kind DO UPDATE
      SET sub_kind_name          = EXCLUDED.sub_kind_name,
          sub_kind_value         = EXCLUDED.sub_kind_value,
          sub_kind_type          = EXCLUDED.sub_kind_type,
          -- перезапишем meta_id только если ранее был NULL/несогласованный (обычно не требуется):
          meta_id                = COALESCE(t.meta_id, EXCLUDED.meta_id),
          sub_kind_default_value = EXCLUDED.sub_kind_default_value
      -- защита от ложного обновления при попытке переноса кода к другому kind (нарушит уникальность)
      WHERE t.sub_kind_code = EXCLUDED.sub_kind_code
        AND t.kind_meta_id  = EXCLUDED.kind_meta_id;
    END IF;

    SELECT * INTO v_row FROM public.v_sub_kinds WHERE meta_id = v_meta_id;
    RETURN v_row;

  ELSIF TG_OP = 'UPDATE' THEN
    -- meta_id через вью не меняем
    IF NEW.meta_id IS DISTINCT FROM OLD.meta_id THEN
      RAISE EXCEPTION 'meta_id is immutable for v_sub_kinds'
        USING ERRCODE = '22023';
    END IF;

    -- частичный апдейт: NULL в NEW не затирает старое значение
    UPDATE public.t_sub_kinds AS t
    SET
      sub_kind_code          = COALESCE(v_code,           t.sub_kind_code),
      sub_kind_name          = COALESCE(NEW.sub_kind_name, t.sub_kind_name),
      sub_kind_value         = COALESCE(NEW.sub_kind_value, t.sub_kind_value),
      sub_kind_type          = COALESCE(NEW.sub_kind_type,  t.sub_kind_type),
      kind_meta_id           = COALESCE(v_kind_meta,        t.kind_meta_id),
      sub_kind_default_value = COALESCE(NEW.sub_kind_default_value, t.sub_kind_default_value)
    WHERE t.meta_id = OLD.meta_id;

    -- если уникальность нарушена (например, переносим code к другому kind), дадим понятную ошибку
    -- (её кинет сам UPDATE с 23505, можем перехватить через EXCEPTION в вызывающем слое при желании)

    SELECT * INTO v_row FROM public.v_sub_kinds WHERE meta_id = OLD.meta_id;
    RETURN v_row;

  ELSE
    RAISE EXCEPTION 'Unsupported TG_OP: %', TG_OP;
  END IF;
END;
$$;


--
-- Name: FUNCTION v_sub_kinds_upsert(); Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON FUNCTION public.v_sub_kinds_upsert() IS 'Smart UPSERT for v_sub_kinds: accepts kind_code or kind_meta_id; partial UPDATE; passes sub_kind_default_value.';


--
-- Name: validate_artifact_content(text, text); Type: FUNCTION; Schema: public; Owner: -
--

CREATE FUNCTION public.validate_artifact_content(p_subkind_code text, p_content_text text) RETURNS void
    LANGUAGE plpgsql
    AS $$
DECLARE
  v_valtype  artifact_value_type_t;
BEGIN
  SELECT subkind_value_type
    INTO v_valtype
  FROM dict.artifact_subkinds
  WHERE artifact_subkind_code = p_subkind_code
  LIMIT 1;

  IF v_valtype IS NULL THEN
    -- неизвестный подтип — оставляем как есть
    RETURN;
  END IF;

  CASE v_valtype
    WHEN 'json' THEN
      -- проверим, что это валидный JSON
      PERFORM p_content_text::jsonb;
    WHEN 'int' THEN
      PERFORM p_content_text::bigint;
    WHEN 'float' THEN
      PERFORM p_content_text::double precision;
    WHEN 'bool' THEN
      PERFORM p_content_text::boolean;
    WHEN 'binary','text' THEN
      -- ничего, базовая проверка не нужна
      NULL;
  END CASE;
EXCEPTION
  WHEN others THEN
    RAISE EXCEPTION 'artifact content validation failed for subkind % (type %): %',
      p_subkind_code, v_valtype, SQLERRM;
END $$;


SET default_tablespace = '';

SET default_table_access_method = heap;

--
-- Name: t_blobs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_blobs (
    meta_id uuid NOT NULL,
    blob_sha256 text NOT NULL,
    blob_bytes_len bigint NOT NULL,
    blob_content bytea NOT NULL,
    CONSTRAINT ck_t_blobs_len_matches CHECK ((blob_bytes_len = octet_length(blob_content)))
);


--
-- Name: t_chat_groups; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_chat_groups (
    meta_id uuid NOT NULL,
    user_id integer NOT NULL,
    parent_meta uuid,
    group_name text NOT NULL
);


--
-- Name: t_chat_messages; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_chat_messages (
    meta_id uuid NOT NULL,
    session_meta uuid NOT NULL,
    user_id integer NOT NULL,
    role public.msg_role_t NOT NULL,
    content_format public.doc_format_t DEFAULT 'text'::public.doc_format_t NOT NULL,
    content_inline text,
    blob_meta_id uuid,
    content_len bigint DEFAULT 0 NOT NULL,
    content_sha256 text NOT NULL,
    seq bigint NOT NULL,
    token_count integer,
    metadata jsonb DEFAULT '{}'::jsonb NOT NULL
);


--
-- Name: t_chat_sessions; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_chat_sessions (
    meta_id uuid NOT NULL,
    user_id integer NOT NULL,
    group_meta uuid,
    title text DEFAULT 'Новый чат'::text NOT NULL,
    last_message_at timestamp with time zone,
    total_tokens integer DEFAULT 0 NOT NULL
);


--
-- Name: t_kinds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_kinds (
    meta_id uuid NOT NULL,
    kind_code text NOT NULL,
    kind_name text NOT NULL
);


--
-- Name: t_message_attachments; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_message_attachments (
    meta_id uuid NOT NULL,
    message_meta uuid NOT NULL,
    filename text,
    mime_type text,
    size_bytes bigint,
    blob_meta_id uuid NOT NULL,
    created timestamp with time zone DEFAULT now(),
    updated timestamp with time zone DEFAULT now()
);


--
-- Name: t_pcaches; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_pcaches (
    meta_id uuid NOT NULL,
    pcache_prompt text NOT NULL,
    pcache_prompt_hash text NOT NULL,
    pcache_response text,
    pcache_tokens_used integer DEFAULT 0
);


--
-- Name: TABLE t_pcaches; Type: COMMENT; Schema: public; Owner: -
--

COMMENT ON TABLE public.t_pcaches IS 'хранит все обращения пользователей к LLM для исключения повторного вызова LLM при одинаковых запросах';


--
-- Name: t_sub_kinds; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_sub_kinds (
    meta_id uuid NOT NULL,
    sub_kind_code text NOT NULL,
    sub_kind_name text NOT NULL,
    sub_kind_value text,
    sub_kind_type text,
    kind_meta_id uuid NOT NULL,
    sub_kind_default_value text
);


--
-- Name: t_user_docs; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.t_user_docs (
    meta_id uuid NOT NULL,
    user_id integer NOT NULL,
    user_title text,
    user_lang_iso text,
    user_content_format public.doc_format_t NOT NULL,
    user_content_inline text,
    blob_meta_id uuid,
    user_content_len bigint DEFAULT 0 NOT NULL,
    user_sha256 text NOT NULL,
    CONSTRAINT ck_user_docs_len_nonneg CHECK ((user_content_len >= 0))
);


--
-- Name: tb_record_meta; Type: TABLE; Schema: public; Owner: -
--

CREATE TABLE public.tb_record_meta (
    id uuid DEFAULT gen_random_uuid() NOT NULL,
    created timestamp with time zone DEFAULT now() NOT NULL,
    updated timestamp with time zone DEFAULT now() NOT NULL,
    is_del boolean DEFAULT false NOT NULL
);


--
-- Name: v_sub_kinds; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_sub_kinds AS
 SELECT sk.meta_id,
    sk.sub_kind_code,
    sk.sub_kind_name,
    sk.sub_kind_value,
    char_length(sk.sub_kind_value) AS sub_kind_value_len,
    sk.sub_kind_type,
    sk.kind_meta_id,
    k.kind_code,
    k.kind_name,
    sk.sub_kind_default_value
   FROM (public.t_sub_kinds sk
     LEFT JOIN public.t_kinds k ON ((k.meta_id = sk.kind_meta_id)));


--
-- Name: v_agents; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_agents AS
 SELECT v_sub_kinds.meta_id,
    v_sub_kinds.sub_kind_code,
    v_sub_kinds.sub_kind_name,
    v_sub_kinds.sub_kind_value,
    v_sub_kinds.sub_kind_value_len,
    v_sub_kinds.sub_kind_type,
    v_sub_kinds.kind_meta_id,
    v_sub_kinds.kind_code,
    v_sub_kinds.kind_name,
    v_sub_kinds.sub_kind_default_value
   FROM public.v_sub_kinds
  WHERE (v_sub_kinds.kind_code = 'agents'::text);


--
-- Name: v_record_meta; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_record_meta AS
 SELECT t.id,
    t.created,
    t.updated,
    t.is_del,
    NULL::timestamp with time zone AS deleted_at
   FROM public.tb_record_meta t
  WHERE (t.is_del = false);


--
-- Name: v_chat_groups; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_chat_groups AS
 SELECT g.meta_id,
    g.user_id,
    g.parent_meta,
    g.group_name
   FROM (public.t_chat_groups g
     JOIN public.v_record_meta m ON ((m.id = g.meta_id)));


--
-- Name: v_chat_messages; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_chat_messages AS
 SELECT m.meta_id,
    m.session_meta,
    m.user_id,
    m.role,
    m.content_format,
    m.content_len,
    m.content_sha256,
    m.seq,
    m.token_count,
    m.metadata,
        CASE
            WHEN (m.content_inline IS NOT NULL) THEN m.content_inline
            WHEN (m.blob_meta_id IS NOT NULL) THEN convert_from(b.blob_content, 'UTF8'::name)
            ELSE NULL::text
        END AS content
   FROM ((public.t_chat_messages m
     JOIN public.v_record_meta rm ON ((rm.id = m.meta_id)))
     LEFT JOIN public.t_blobs b ON ((b.meta_id = m.blob_meta_id)));


--
-- Name: v_chat_sessions; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_chat_sessions AS
 SELECT s.meta_id,
    s.user_id,
    s.group_meta,
    s.title,
    s.last_message_at,
    s.total_tokens
   FROM (public.t_chat_sessions s
     JOIN public.v_record_meta m ON ((m.id = s.meta_id)));


--
-- Name: v_kinds; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_kinds AS
 SELECT t.meta_id,
    t.kind_code,
    t.kind_name
   FROM (public.t_kinds t
     JOIN public.v_record_meta m ON ((m.id = t.meta_id)));


--
-- Name: v_message_attachments; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_message_attachments AS
 SELECT m.meta_id,
    m.message_meta,
    m.filename,
    m.mime_type,
    m.size_bytes,
    m.blob_meta_id,
    b.blob_sha256
   FROM (public.t_message_attachments m
     LEFT JOIN public.t_blobs b ON ((b.meta_id = m.blob_meta_id)));


--
-- Name: v_pcaches; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_pcaches AS
 SELECT t.meta_id,
    t.pcache_prompt,
    t.pcache_prompt_hash,
    t.pcache_response,
    t.pcache_tokens_used,
    public.pcache_assistant_content(t.pcache_response) AS pcache_content
   FROM (public.t_pcaches t
     JOIN public.v_record_meta m ON ((m.id = t.meta_id)));


--
-- Name: v_user_docs; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_user_docs AS
 SELECT d.meta_id,
    d.user_id,
    d.user_title,
    d.user_lang_iso,
    d.user_content_format,
    d.user_content_len,
    d.user_sha256,
        CASE
            WHEN (d.user_content_inline IS NOT NULL) THEN d.user_content_inline
            WHEN (d.blob_meta_id IS NOT NULL) THEN convert_from(b.blob_content, 'UTF8'::name)
            ELSE NULL::text
        END AS user_content
   FROM ((public.t_user_docs d
     JOIN public.v_record_meta m ON ((m.id = d.meta_id)))
     LEFT JOIN public.t_blobs b ON ((b.meta_id = d.blob_meta_id)))
  WHERE (m.is_del = false);


--
-- Name: v_users; Type: VIEW; Schema: public; Owner: -
--

CREATE VIEW public.v_users AS
 SELECT users.user_user,
    users.user_id,
    users.user_name
   FROM dict.users() users(user_user, user_id, user_name);


--
-- Name: t_sub_kinds pk_t_sub_kinds; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_sub_kinds
    ADD CONSTRAINT pk_t_sub_kinds PRIMARY KEY (meta_id);


--
-- Name: t_blobs t_blobs_blob_sha256_key; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_blobs
    ADD CONSTRAINT t_blobs_blob_sha256_key UNIQUE (blob_sha256);


--
-- Name: t_blobs t_blobs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_blobs
    ADD CONSTRAINT t_blobs_pkey PRIMARY KEY (meta_id);


--
-- Name: t_message_attachments t_message_attachments_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_message_attachments
    ADD CONSTRAINT t_message_attachments_pkey PRIMARY KEY (meta_id);


--
-- Name: t_user_docs t_user_docs_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_user_docs
    ADD CONSTRAINT t_user_docs_pkey PRIMARY KEY (meta_id);


--
-- Name: tb_record_meta tb_record_meta_pkey; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.tb_record_meta
    ADD CONSTRAINT tb_record_meta_pkey PRIMARY KEY (id);


--
-- Name: t_chat_messages ux_t_chat_messages_meta; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_chat_messages
    ADD CONSTRAINT ux_t_chat_messages_meta UNIQUE (meta_id);


--
-- Name: t_kinds ux_t_kinds_kind_code; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_kinds
    ADD CONSTRAINT ux_t_kinds_kind_code UNIQUE (kind_code);


--
-- Name: t_kinds ux_t_kinds_meta_id; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_kinds
    ADD CONSTRAINT ux_t_kinds_meta_id UNIQUE (meta_id);


--
-- Name: t_sub_kinds ux_t_sub_kinds_per_kind; Type: CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_sub_kinds
    ADD CONSTRAINT ux_t_sub_kinds_per_kind UNIQUE (sub_kind_code, kind_meta_id);


--
-- Name: ix_blobs_len; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_blobs_len ON public.t_blobs USING btree (blob_bytes_len);


--
-- Name: ix_blobs_sha; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_blobs_sha ON public.t_blobs USING btree (blob_sha256);


--
-- Name: ix_chat_groups_parent; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_groups_parent ON public.t_chat_groups USING btree (parent_meta);


--
-- Name: ix_chat_groups_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_chat_groups_user ON public.t_chat_groups USING btree (user_id);


--
-- Name: ix_msg_metadata_gin; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_msg_metadata_gin ON public.t_chat_messages USING gin (metadata);


--
-- Name: ix_msg_session; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_msg_session ON public.t_chat_messages USING btree (session_meta);


--
-- Name: ix_sessions_group; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sessions_group ON public.t_chat_sessions USING btree (group_meta);


--
-- Name: ix_sessions_title_trgm; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sessions_title_trgm ON public.t_chat_sessions USING gin (title public.gin_trgm_ops);


--
-- Name: ix_sessions_user; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_sessions_user ON public.t_chat_sessions USING btree (user_id);


--
-- Name: ix_t_kinds_kind_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_t_kinds_kind_code ON public.t_kinds USING btree (kind_code);


--
-- Name: ix_t_kinds_kind_name; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_t_kinds_kind_name ON public.t_kinds USING btree (kind_name);


--
-- Name: ix_t_sub_kinds_kind_meta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_t_sub_kinds_kind_meta_id ON public.t_sub_kinds USING btree (kind_meta_id);


--
-- Name: ix_t_sub_kinds_kind_sub; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_t_sub_kinds_kind_sub ON public.t_sub_kinds USING btree (kind_meta_id, sub_kind_code);


--
-- Name: ix_t_sub_kinds_sub_kind_code; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_t_sub_kinds_sub_kind_code ON public.t_sub_kinds USING btree (sub_kind_code);


--
-- Name: ix_tb_record_meta_created; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_tb_record_meta_created ON public.tb_record_meta USING btree (created);


--
-- Name: ix_tb_record_meta_is_del_false; Type: INDEX; Schema: public; Owner: -
--

CREATE INDEX ix_tb_record_meta_is_del_false ON public.tb_record_meta USING btree (is_del) WHERE (is_del = false);


--
-- Name: ux_msg_session_seq; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_msg_session_seq ON public.t_chat_messages USING btree (session_meta, seq);


--
-- Name: ux_t_pcaches_prompt_hash; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_t_pcaches_prompt_hash ON public.t_pcaches USING btree (pcache_prompt_hash);


--
-- Name: ux_t_sub_kinds_meta_id; Type: INDEX; Schema: public; Owner: -
--

CREATE UNIQUE INDEX ux_t_sub_kinds_meta_id ON public.t_sub_kinds USING btree (meta_id);


--
-- Name: t_blobs trg_t_blobs_mark_updated; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_t_blobs_mark_updated BEFORE UPDATE ON public.t_blobs FOR EACH ROW EXECUTE FUNCTION public.tg_mark_updated_call_update_record();


--
-- Name: t_blobs trg_t_blobs_soft_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_t_blobs_soft_delete BEFORE DELETE ON public.t_blobs FOR EACH ROW EXECUTE FUNCTION public.tg_soft_delete_call_delete_record();


--
-- Name: v_chat_groups trg_v_chat_groups_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_chat_groups_delete INSTEAD OF DELETE ON public.v_chat_groups FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_groups_delete();


--
-- Name: v_chat_groups trg_v_chat_groups_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_chat_groups_upsert INSTEAD OF INSERT OR UPDATE ON public.v_chat_groups FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_groups_upsert();


--
-- Name: v_chat_messages trg_v_chat_messages_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_chat_messages_delete INSTEAD OF DELETE ON public.v_chat_messages FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_messages_delete();


--
-- Name: v_chat_messages trg_v_chat_messages_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_chat_messages_upsert INSTEAD OF INSERT OR UPDATE ON public.v_chat_messages FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_messages_upsert();


--
-- Name: v_chat_sessions trg_v_chat_sessions_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_chat_sessions_delete INSTEAD OF DELETE ON public.v_chat_sessions FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_sessions_delete();


--
-- Name: v_chat_sessions trg_v_chat_sessions_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_chat_sessions_upsert INSTEAD OF INSERT OR UPDATE ON public.v_chat_sessions FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_sessions_upsert();


--
-- Name: v_kinds trg_v_kinds_del; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_kinds_del INSTEAD OF DELETE ON public.v_kinds FOR EACH ROW EXECUTE FUNCTION public.v_kinds_delete();


--
-- Name: v_kinds trg_v_kinds_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_kinds_upsert INSTEAD OF INSERT OR UPDATE ON public.v_kinds FOR EACH ROW EXECUTE FUNCTION public.v_kinds_upsert();


--
-- Name: v_record_meta trg_v_record_meta_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_record_meta_delete INSTEAD OF DELETE ON public.v_record_meta FOR EACH ROW EXECUTE FUNCTION public.v_record_meta_delete();


--
-- Name: v_record_meta trg_v_record_meta_insert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_record_meta_insert INSTEAD OF INSERT ON public.v_record_meta FOR EACH ROW EXECUTE FUNCTION public.v_record_meta_insert();


--
-- Name: v_record_meta trg_v_record_meta_update; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_record_meta_update INSTEAD OF UPDATE ON public.v_record_meta FOR EACH ROW EXECUTE FUNCTION public.v_record_meta_update();


--
-- Name: v_sub_kinds trg_v_sub_kinds_del; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_sub_kinds_del INSTEAD OF DELETE ON public.v_sub_kinds FOR EACH ROW EXECUTE FUNCTION public.v_sub_kinds_delete();


--
-- Name: v_sub_kinds trg_v_sub_kinds_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_sub_kinds_upsert INSTEAD OF INSERT OR UPDATE ON public.v_sub_kinds FOR EACH ROW EXECUTE FUNCTION public.v_sub_kinds_upsert();


--
-- Name: v_user_docs trg_v_user_docs_delete; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_user_docs_delete INSTEAD OF DELETE ON public.v_user_docs FOR EACH ROW EXECUTE FUNCTION public.tg_v_user_docs_delete();


--
-- Name: v_user_docs trg_v_user_docs_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER trg_v_user_docs_upsert INSTEAD OF INSERT OR UPDATE ON public.v_user_docs FOR EACH ROW EXECUTE FUNCTION public.tg_v_user_docs_upsert();


--
-- Name: v_pcaches v_pcaches_del; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER v_pcaches_del INSTEAD OF DELETE ON public.v_pcaches FOR EACH ROW EXECUTE FUNCTION public.trg_v__pcaches_del();


--
-- Name: v_pcaches v_pcaches_upsert; Type: TRIGGER; Schema: public; Owner: -
--

CREATE TRIGGER v_pcaches_upsert INSTEAD OF INSERT OR UPDATE ON public.v_pcaches FOR EACH ROW EXECUTE FUNCTION public.v__pcaches_upsert();


--
-- Name: t_chat_messages fk_msg_blob; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_chat_messages
    ADD CONSTRAINT fk_msg_blob FOREIGN KEY (blob_meta_id) REFERENCES public.t_blobs(meta_id) ON DELETE SET NULL;


--
-- Name: t_message_attachments fk_msgatt_message; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_message_attachments
    ADD CONSTRAINT fk_msgatt_message FOREIGN KEY (message_meta) REFERENCES public.t_chat_messages(meta_id);


--
-- Name: t_chat_messages fk_t_chat_messages_meta_record; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_chat_messages
    ADD CONSTRAINT fk_t_chat_messages_meta_record FOREIGN KEY (meta_id) REFERENCES public.tb_record_meta(id);


--
-- Name: t_sub_kinds fk_t_sub_kinds_kind_meta_id; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_sub_kinds
    ADD CONSTRAINT fk_t_sub_kinds_kind_meta_id FOREIGN KEY (kind_meta_id) REFERENCES public.t_kinds(meta_id) ON UPDATE CASCADE ON DELETE RESTRICT;


--
-- Name: t_user_docs t_user_docs_blob_meta_id_fkey; Type: FK CONSTRAINT; Schema: public; Owner: -
--

ALTER TABLE ONLY public.t_user_docs
    ADD CONSTRAINT t_user_docs_blob_meta_id_fkey FOREIGN KEY (blob_meta_id) REFERENCES public.t_blobs(meta_id);


--
-- PostgreSQL database dump complete
--

\unrestrict dkxDuUe4QacpqjYu0gmbVuwIOie9mh6rhKg5XUgdh2hKFh9HgIgc0v9ELsfZREf

