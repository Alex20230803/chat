-- audit_v_chat.sql
-- Проверка всех VIEW public.v_chat_* на соответствие шаблону:
--   INSERT/UPDATE через INSTEAD OF-триггер с:
--     v_meta_id := COALESCE(NEW.meta_id, public.create_record());
--     UPDATE-ветка: PERFORM public.update_record(OLD.meta_id);
--     DELETE-ветка: PERFORM public.delete_record(OLD.meta_id);
--   Для v_chat_messages: запрет упоминаний NEW.content_inline/NEW.blob_meta_id,
--     вставка в t_chat_messages и расчёт seq через COALESCE(MAX(seq),0)+1.

WITH views AS (
  SELECT c.oid::regclass AS view_regclass,
         n.nspname       AS schema,
         c.relname       AS view_name
  FROM pg_class c
  JOIN pg_namespace n ON n.oid = c.relnamespace
  WHERE c.relkind = 'v'
    AND n.nspname = 'public'
    AND c.relname LIKE 'v_%'
    AND c.relname not LIKE 'v_record_meta'
    AND c.relname not LIKE 'v_agents'
    AND c.relname not LIKE 'v_users'
),
trg AS (
  SELECT t.tgname,
         t.tgfoid::regproc AS func_regproc,
         t.tgrelid::regclass AS on_view,
         t.tgenabled,
         -- события
         (t.tgtype & 4) <> 0 AS is_insert,
         (t.tgtype & 8) <> 0 AS is_delete,
         (t.tgtype & 16)<> 0 AS is_update
  FROM pg_trigger t
  WHERE NOT t.tgisinternal
),
fn AS (
  SELECT p.oid,
         p.oid::regprocedure AS regproc,
         pg_get_functiondef(p.oid) AS def
  FROM pg_proc p
),
v_trg AS (
  SELECT v.view_regclass,
         v.view_name,
         array_agg(DISTINCT trg.func_regproc) FILTER (WHERE trg.is_insert OR trg.is_update) AS upsert_funcs,
         array_agg(DISTINCT trg.func_regproc) FILTER (WHERE trg.is_delete) AS delete_funcs
  FROM views v
  LEFT JOIN trg ON trg.on_view = v.view_regclass
  GROUP BY v.view_regclass, v.view_name
),
checks AS (
  SELECT
    v.view_name,
    COALESCE(upsert_funcs, ARRAY[]::regprocedure[])  AS upsert_funcs,
    COALESCE(delete_funcs, ARRAY[]::regprocedure[])  AS delete_funcs
  FROM v_trg v
),
fn_checks AS (
  -- Разворачиваем функции и считаем сигнатуры соответствия по тексту
  SELECT
    c.view_name,
    f.regproc,
    f.def,
    -- Базовые правила
    (f.def ILIKE '%COALESCE(NEW.meta_id, public.create_record())%') AS has_create_record_on_insert,
    (f.def ILIKE '%PERFORM public.update_record(OLD.meta_id)%')     AS has_update_record_on_update,
    (f.def ILIKE '%PERFORM public.delete_record(OLD.meta_id)%')     AS has_delete_record_on_delete,
    -- Для messages: запрещённые NEW.*
    (f.def ILIKE '%NEW.content_inline%')                            AS has_bad_new_content_inline,
    (f.def ILIKE '%NEW.blob_meta_id%')                              AS has_bad_new_blob_meta_id,
    -- Для messages: обязательные конструкции
    (f.def ILIKE '%INSERT INTO public.t_chat_messages%')            AS inserts_into_t_chat_messages,
    (f.def ILIKE '%COALESCE(MAX(seq),0)+1%')                        AS has_seq_calc
  FROM checks c
  LEFT JOIN LATERAL unnest(c.upsert_funcs || c.delete_funcs) uf(regproc) ON TRUE
  LEFT JOIN fn f ON f.regproc = uf.regproc
),
rollup AS (
  SELECT
    c.view_name,
    -- наличие нужных триггеров
    (array_length(c.upsert_funcs,1) >= 1)                 AS has_upsert_trigger,
    (array_length(c.delete_funcs,1) >= 1)                 AS has_delete_trigger,

    -- сводка по функциям (если несколько — достаточно, чтобы В КАКОЙ-ТО одной функции условие выполнилось)
    bool_or(fc.has_create_record_on_insert)               AS ok_create_record_on_insert,
    bool_or(fc.has_update_record_on_update)               AS ok_update_record_on_update,
    bool_or(fc.has_delete_record_on_delete)               AS ok_delete_record_on_delete,

    -- спец-проверки для messages
    bool_or(fc.has_bad_new_content_inline)                AS bad_new_content_inline_any,
    bool_or(fc.has_bad_new_blob_meta_id)                  AS bad_new_blob_meta_id_any,
    bool_or(fc.inserts_into_t_chat_messages)              AS ok_inserts_into_t_chat_messages,
    bool_or(fc.has_seq_calc)                              AS ok_has_seq_calc,

    -- перечни функций (для отчётности)
    array_agg(DISTINCT fc.regproc) FILTER (WHERE fc.regproc IS NOT NULL) AS all_funcs
  FROM checks c
  LEFT JOIN fn_checks fc ON fc.view_name = c.view_name
  GROUP BY c.view_name, c.upsert_funcs, c.delete_funcs
)
SELECT
  view_name,
  CASE WHEN has_upsert_trigger THEN 'OK' ELSE 'NO' END            AS trg_upsert,
  CASE WHEN has_delete_trigger THEN 'OK' ELSE 'NO' END            AS trg_delete,
  CASE WHEN ok_create_record_on_insert THEN 'OK' ELSE 'NO' END    AS ins_create_record,
  CASE WHEN ok_update_record_on_update THEN 'OK' ELSE 'NO' END    AS upd_update_record,
  CASE WHEN ok_delete_record_on_delete THEN 'OK' ELSE 'NO' END    AS del_delete_record,
  -- Только для v_chat_messages дополнительно контролим:
  CASE WHEN view_name = 'v_chat_messages' AND bad_new_content_inline_any THEN 'BAD' ELSE 'OK' END AS ban_new_content_inline,
  CASE WHEN view_name = 'v_chat_messages' AND bad_new_blob_meta_id_any  THEN 'BAD' ELSE 'OK' END AS ban_new_blob_meta_id,
  CASE WHEN view_name = 'v_chat_messages' AND ok_inserts_into_t_chat_messages THEN 'OK' ELSE CASE WHEN view_name='v_chat_messages' THEN 'NO' ELSE '-' END END AS ins_t_chat_messages,
  CASE WHEN view_name = 'v_chat_messages' AND ok_has_seq_calc THEN 'OK' ELSE CASE WHEN view_name='v_chat_messages' THEN 'NO' ELSE '-' END END AS seq_calc,
  all_funcs
FROM rollup
ORDER BY view_name;
