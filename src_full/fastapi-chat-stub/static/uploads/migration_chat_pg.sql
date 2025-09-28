
-- =====================================================================
-- Chat schema migration (compatible with existing t_/v_/meta conventions)
-- Requires: tb_record_meta, v_record_meta, t_blobs, v_users, delete_record(),
--           doc_format_t enum, extensions pgcrypto (digest) and pg_trgm.
-- Apply on the SAME database. Safe to run multiple times (guards included).
-- =====================================================================

BEGIN;

-- ---------- Extensions (safe) ----------
CREATE EXTENSION IF NOT EXISTS "pgcrypto";
CREATE EXTENSION IF NOT EXISTS "pg_trgm";

-- ---------- Types ----------
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_type WHERE typname = 'msg_role_t') THEN
    CREATE TYPE public.msg_role_t AS ENUM ('system','user','assistant','tool');
  END IF;
END $$;

-- =====================================================================
-- 1) Chat Groups: t_chat_groups / v_chat_groups + triggers
-- =====================================================================

-- Base table (if not exists)
DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='t_chat_groups') THEN
    CREATE TABLE public.t_chat_groups (
      meta_id      uuid    NOT NULL,              -- -> tb_record_meta.id
      user_id      integer NOT NULL,              -- owner (from v_users via current_user)
      parent_meta  uuid    NULL,                  -- nesting (optional): -> t_chat_groups.meta_id
      group_name   text    NOT NULL
    );
    CREATE INDEX IF NOT EXISTS ix_chat_groups_user   ON public.t_chat_groups(user_id);
    CREATE INDEX IF NOT EXISTS ix_chat_groups_parent ON public.t_chat_groups(parent_meta);
  END IF;
END $$;

-- View (replace to pick up definition changes)
CREATE OR REPLACE VIEW public.v_chat_groups AS
SELECT g.meta_id,
       g.user_id,
       g.parent_meta,
       g.group_name
FROM public.t_chat_groups g
JOIN public.v_record_meta m ON m.id = g.meta_id;

-- Upsert trigger function
CREATE OR REPLACE FUNCTION public.tg_v_chat_groups_upsert()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_uid integer;
BEGIN
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unknown current_user %', current_user;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.meta_id IS NULL THEN
      INSERT INTO public.tb_record_meta DEFAULT VALUES RETURNING id INTO NEW.meta_id;
    ELSE
      -- ensure meta exists
      PERFORM 1 FROM public.tb_record_meta WHERE id = NEW.meta_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'meta_id % not found in tb_record_meta', NEW.meta_id;
      END IF;
    END IF;

    INSERT INTO public.t_chat_groups (meta_id, user_id, parent_meta, group_name)
    VALUES (NEW.meta_id, v_uid, NEW.parent_meta, NEW.group_name);

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.t_chat_groups
       SET parent_meta = NEW.parent_meta,
           group_name  = NEW.group_name
     WHERE meta_id = NEW.meta_id;

    UPDATE public.tb_record_meta SET updated = now() WHERE id = NEW.meta_id;
    RETURN NEW;
  END IF;

  RETURN NULL;
END $$;

-- Delete trigger function
CREATE OR REPLACE FUNCTION public.tg_v_chat_groups_delete()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END $$;

-- Triggers
DROP TRIGGER IF EXISTS trg_v_chat_groups_upsert ON public.v_chat_groups;
CREATE TRIGGER trg_v_chat_groups_upsert
INSTEAD OF INSERT OR UPDATE ON public.v_chat_groups
FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_groups_upsert();

DROP TRIGGER IF EXISTS trg_v_chat_groups_delete ON public.v_chat_groups;
CREATE TRIGGER trg_v_chat_groups_delete
INSTEAD OF DELETE ON public.v_chat_groups
FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_groups_delete();

-- =====================================================================
-- 2) Chat Sessions: t_chat_sessions / v_chat_sessions + triggers
-- =====================================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='t_chat_sessions') THEN
    CREATE TABLE public.t_chat_sessions (
      meta_id         uuid      NOT NULL,     -- -> tb_record_meta.id
      user_id         integer   NOT NULL,     -- owner
      group_meta      uuid      NULL,         -- -> t_chat_groups.meta_id
      title           text      NOT NULL DEFAULT 'Новый чат',
      last_message_at timestamptz,
      total_tokens    integer   NOT NULL DEFAULT 0
    );
    CREATE INDEX IF NOT EXISTS ix_sessions_user   ON public.t_chat_sessions(user_id);
    CREATE INDEX IF NOT EXISTS ix_sessions_group  ON public.t_chat_sessions(group_meta);
  END IF;
END $$;

CREATE OR REPLACE VIEW public.v_chat_sessions AS
SELECT s.meta_id,
       s.user_id,
       s.group_meta,
       s.title,
       s.last_message_at,
       s.total_tokens
FROM public.t_chat_sessions s
JOIN public.v_record_meta m ON m.id = s.meta_id;

-- Upsert
CREATE OR REPLACE FUNCTION public.tg_v_chat_sessions_upsert()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE v_uid integer;
BEGIN
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unknown current_user %', current_user;
  END IF;

  IF TG_OP = 'INSERT' THEN
    IF NEW.meta_id IS NULL THEN
      INSERT INTO public.tb_record_meta DEFAULT VALUES RETURNING id INTO NEW.meta_id;
    ELSE
      PERFORM 1 FROM public.tb_record_meta WHERE id = NEW.meta_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'meta_id % not found in tb_record_meta', NEW.meta_id;
      END IF;
    END IF;

    INSERT INTO public.t_chat_sessions (meta_id, user_id, group_meta, title, last_message_at, total_tokens)
    VALUES (NEW.meta_id, v_uid, NEW.group_meta, COALESCE(NEW.title, 'Новый чат'), NEW.last_message_at, COALESCE(NEW.total_tokens,0));

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.t_chat_sessions
       SET group_meta      = NEW.group_meta,
           title           = NEW.title,
           last_message_at = NEW.last_message_at,
           total_tokens    = COALESCE(NEW.total_tokens, 0)
     WHERE meta_id = NEW.meta_id;

    UPDATE public.tb_record_meta SET updated = now() WHERE id = NEW.meta_id;
    RETURN NEW;
  END IF;

  RETURN NULL;
END $$;

-- Delete
CREATE OR REPLACE FUNCTION public.tg_v_chat_sessions_delete()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_v_chat_sessions_upsert ON public.v_chat_sessions;
CREATE TRIGGER trg_v_chat_sessions_upsert
INSTEAD OF INSERT OR UPDATE ON public.v_chat_sessions
FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_sessions_upsert();

DROP TRIGGER IF EXISTS trg_v_chat_sessions_delete ON public.v_chat_sessions;
CREATE TRIGGER trg_v_chat_sessions_delete
INSTEAD OF DELETE ON public.v_chat_sessions
FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_sessions_delete();

-- Helpful indexes on meta (updated) and title trigram
CREATE INDEX IF NOT EXISTS ix_sessions_title_trgm ON public.t_chat_sessions USING GIN (title gin_trgm_ops);

-- =====================================================================
-- 3) Chat Messages: t_chat_messages / v_chat_messages + triggers
-- =====================================================================

DO $$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM information_schema.tables WHERE table_schema='public' AND table_name='t_chat_messages') THEN
    CREATE TABLE public.t_chat_messages (
      meta_id           uuid                NOT NULL,  -- -> tb_record_meta.id
      session_meta      uuid                NOT NULL,  -- -> t_chat_sessions.meta_id
      user_id           integer             NOT NULL,  -- owner (creator)
      role              public.msg_role_t   NOT NULL,
      content_format    public.doc_format_t NOT NULL DEFAULT 'text',
      content_inline    text,
      blob_meta_id      uuid,
      content_len       bigint              NOT NULL DEFAULT 0,
      content_sha256    text                NOT NULL,
      seq               bigint              NOT NULL,  -- order within session
      token_count       integer,
      metadata          jsonb               NOT NULL DEFAULT '{}'::jsonb
    );
    ALTER TABLE public.t_chat_messages
      ADD CONSTRAINT fk_msg_blob FOREIGN KEY (blob_meta_id) REFERENCES public.t_blobs(meta_id) ON DELETE SET NULL;
    CREATE UNIQUE INDEX IF NOT EXISTS ux_msg_session_seq ON public.t_chat_messages(session_meta, seq);
    CREATE INDEX IF NOT EXISTS ix_msg_session       ON public.t_chat_messages(session_meta);
    CREATE INDEX IF NOT EXISTS ix_msg_metadata_gin  ON public.t_chat_messages USING GIN (metadata);
  END IF;
END $$;

-- View: resolves content from inline/blob and filters via v_record_meta
CREATE OR REPLACE VIEW public.v_chat_messages AS
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
         WHEN m.content_inline IS NOT NULL THEN m.content_inline
         WHEN m.blob_meta_id IS NOT NULL THEN convert_from(b.blob_content, 'UTF8')
         ELSE NULL
       END AS content
FROM public.t_chat_messages m
JOIN public.v_record_meta rm ON rm.id = m.meta_id
LEFT JOIN public.t_blobs b   ON b.meta_id = m.blob_meta_id;

-- Upsert (handles inline/blob, seq, aggregates)
CREATE OR REPLACE FUNCTION public.tg_v_chat_messages_upsert()
RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_uid       integer;
  v_bytes     bytea;
  v_len       bigint;
  v_sha256    text;
  v_threshold integer := 4096; -- bytes; store inline below this, else blob
  v_blob_meta uuid;
  v_seq       bigint;
BEGIN
  SELECT u.user_id INTO v_uid
  FROM public.v_users u
  WHERE u.user_user = current_user
  LIMIT 1;
  IF v_uid IS NULL THEN
    RAISE EXCEPTION 'unknown current_user %', current_user;
  END IF;

  -- prepare content
  v_bytes := convert_to(COALESCE(NEW.content, ''), 'UTF8');
  v_len   := octet_length(v_bytes);
  v_sha256:= encode(digest(v_bytes, 'sha256'), 'hex');

  IF v_len <= v_threshold THEN
    NEW.content_inline := NEW.content;
    NEW.blob_meta_id   := NULL;
  ELSE
    INSERT INTO public.tb_record_meta DEFAULT VALUES RETURNING id INTO v_blob_meta;
    INSERT INTO public.t_blobs(meta_id, blob_sha256, blob_bytes_len, blob_content)
    VALUES (v_blob_meta, v_sha256, v_len, v_bytes);
    NEW.content_inline := NULL;
    NEW.blob_meta_id   := v_blob_meta;
  END IF;

  NEW.content_len    := v_len;
  NEW.content_sha256 := v_sha256;
  NEW.user_id        := v_uid;

  IF TG_OP = 'INSERT' THEN
    IF NEW.meta_id IS NULL THEN
      INSERT INTO public.tb_record_meta DEFAULT VALUES RETURNING id INTO NEW.meta_id;
    ELSE
      PERFORM 1 FROM public.tb_record_meta WHERE id = NEW.meta_id;
      IF NOT FOUND THEN
        RAISE EXCEPTION 'meta_id % not found in tb_record_meta', NEW.meta_id;
      END IF;
    END IF;

    -- atomic seq per session
    WITH next AS (
      SELECT COALESCE(MAX(seq),0)+1 AS seq
      FROM public.t_chat_messages
      WHERE session_meta = NEW.session_meta
      FOR UPDATE
    )
    SELECT seq INTO v_seq FROM next;
    NEW.seq := v_seq;

    INSERT INTO public.t_chat_messages(
      meta_id, session_meta, user_id, role, content_format,
      content_inline, blob_meta_id, content_len, content_sha256,
      seq, token_count, metadata
    ) VALUES (
      NEW.meta_id, NEW.session_meta, NEW.user_id, NEW.role, NEW.content_format,
      NEW.content_inline, NEW.blob_meta_id, NEW.content_len, NEW.content_sha256,
      NEW.seq, NEW.token_count, COALESCE(NEW.metadata,'{}'::jsonb)
    );

    -- session aggregates
    UPDATE public.tb_record_meta SET updated = now() WHERE id = NEW.meta_id;
    UPDATE public.t_chat_sessions
       SET last_message_at = now(),
           total_tokens    = COALESCE(total_tokens,0) + COALESCE(NEW.token_count,0)
     WHERE meta_id = NEW.session_meta;

    RETURN NEW;

  ELSIF TG_OP = 'UPDATE' THEN
    UPDATE public.t_chat_messages
       SET role            = NEW.role,
           content_format  = NEW.content_format,
           content_inline  = NEW.content_inline,
           blob_meta_id    = NEW.blob_meta_id,
           content_len     = NEW.content_len,
           content_sha256  = NEW.content_sha256,
           token_count     = NEW.token_count,
           metadata        = COALESCE(NEW.metadata,'{}'::jsonb)
     WHERE meta_id = NEW.meta_id;

    UPDATE public.tb_record_meta SET updated = now() WHERE id = NEW.meta_id;
    RETURN NEW;
  END IF;

  RETURN NULL;
END $$;

-- Delete
CREATE OR REPLACE FUNCTION public.tg_v_chat_messages_delete()
RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  PERFORM public.delete_record(OLD.meta_id);
  RETURN NULL;
END $$;

DROP TRIGGER IF EXISTS trg_v_chat_messages_upsert ON public.v_chat_messages;
CREATE TRIGGER trg_v_chat_messages_upsert
INSTEAD OF INSERT OR UPDATE ON public.v_chat_messages
FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_messages_upsert();

DROP TRIGGER IF EXISTS trg_v_chat_messages_delete ON public.v_chat_messages;
CREATE TRIGGER trg_v_chat_messages_delete
INSTEAD OF DELETE ON public.v_chat_messages
FOR EACH ROW EXECUTE FUNCTION public.tg_v_chat_messages_delete();

COMMIT;
