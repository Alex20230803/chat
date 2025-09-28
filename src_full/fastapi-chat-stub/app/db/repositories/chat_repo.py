from __future__ import annotations
from typing import Any, Dict, List, Literal, Optional, Tuple, TypedDict

from .base import BaseRepo

Role = Literal["system", "user", "assistant", "tool"]
ContentFormat = Literal["text", "markdown", "json", "html"]

class GroupRow(TypedDict, total=False):
    meta_id: str
    parent_meta: Optional[str]
    group_name: str

class SessionRow(TypedDict, total=False):
    meta_id: str
    group_meta: Optional[str]
    title: str
    last_message_at: Optional[str]
    total_tokens: int
    created: Optional[str]
    updated: Optional[str]

class MessageRow(TypedDict, total=False):
    meta_id: str
    session_meta: str
    role: Role
    content: str
    content_format: ContentFormat
    seq: int
    token_count: Optional[int]
    metadata: Dict[str, Any]


class ChatRepo(BaseRepo):
    # -------- Groups --------
    def create_group(self, group_name: str, parent_meta: Optional[str] = None) -> str:
        sql = """
        INSERT INTO public.v_chat_groups (group_name, parent_meta)
        VALUES (:group_name, :parent_meta)
        RETURNING meta_id;
        """
        rows = self._select(sql, {"group_name": group_name, "parent_meta": parent_meta})
        return rows[0]["meta_id"]

    def list_groups(self) -> List[GroupRow]:
        sql = """
        SELECT g.meta_id, g.parent_meta, g.group_name
        FROM public.v_chat_groups g
        ORDER BY g.group_name ASC, g.meta_id;
        """
        rows = self._select(sql, {})
        return [dict(r) for r in rows]  # type: ignore[return-value]

    def update_group(self, meta_id: str, *, group_name: Optional[str] = None, parent_meta: Optional[str] = None) -> int:
        sets: List[str] = []
        params: Dict[str, Any] = {"meta_id": meta_id}
        if group_name is not None:
            sets.append("group_name = :group_name"); params["group_name"] = group_name
        if parent_meta is not None:
            sets.append("parent_meta = :parent_meta"); params["parent_meta"] = parent_meta
        if not sets:
            return 0
        sql = f"UPDATE public.v_chat_groups SET {', '.join(sets)} WHERE meta_id = :meta_id;"
        return self._execute(sql, params) or 0

    def delete_group(self, meta_id: str) -> int:
        return self._execute("DELETE FROM public.v_chat_groups WHERE meta_id = :meta_id;", {"meta_id": meta_id}) or 0

    # -------- Sessions --------
    def create_session(self, title: str = "Новый чат", group_meta: Optional[str] = None) -> str:
        sql = """
        INSERT INTO public.v_chat_sessions (title, group_meta)
        VALUES (:title, :group_meta)
        RETURNING meta_id;
        """
        rows = self._select(sql, {"title": title, "group_meta": group_meta})
        return rows[0]["meta_id"]

    def list_sessions(self, *, limit: int = 50, offset: int = 0) -> List[SessionRow]:
        sql = """
        SELECT s.meta_id, s.group_meta, s.title, s.last_message_at, s.total_tokens,
         m.created, m.updated
     FROM public.v_chat_sessions s
     LEFT JOIN public.v_record_meta m ON m.id = s.meta_id
        ORDER BY m.updated DESC
        LIMIT :limit OFFSET :offset;
        """
        rows = self._select(sql, {"limit": limit, "offset": offset})
        return [dict(r) for r in rows]  # type: ignore[return-value]

    def update_session(self, meta_id: str, *, title: Optional[str] = None, group_meta: Optional[str] = None) -> int:
        sets: List[str] = []
        params: Dict[str, Any] = {"meta_id": meta_id}
        if title is not None:
            sets.append("title = :title"); params["title"] = title
        if group_meta is not None:
            sets.append("group_meta = :group_meta"); params["group_meta"] = group_meta
        if not sets:
            return 0
        sql = f"UPDATE public.v_chat_sessions SET {', '.join(sets)} WHERE meta_id = :meta_id;"
        return self._execute(sql, params) or 0

    def delete_session(self, meta_id: str) -> int:
        return self._execute("DELETE FROM public.v_chat_sessions WHERE meta_id = :meta_id;", {"meta_id": meta_id}) or 0

    # -------- Messages --------
    def add_message(
        self,
        session_meta: str,
        role: Role,
        content: str,
        *,
        content_format: ContentFormat = "text",
        token_count: Optional[int] = None,
        metadata: Optional[Dict[str, Any]] = None,
    ) -> Tuple[str, int]:
        sql = """
        INSERT INTO public.v_chat_messages
            (session_meta, role, content_format, content, token_count, metadata)
        VALUES (:session_meta, :role, :content_format, :content, :token_count, COALESCE(:metadata, '{}'::jsonb))
        RETURNING meta_id, seq;
        """
        rows = self._select(sql, {
            "session_meta": session_meta,
            "role": role,
            "content_format": content_format,
            "content": content,
            "token_count": token_count,
            "metadata": metadata,
        })
        row = rows[0]
        return row["meta_id"], row["seq"]

    def list_messages(
        self,
        session_meta: str,
        *,
        after_seq: Optional[int] = None,
        limit: int = 200,
        ascending: bool = True,
    ) -> List[MessageRow]:
        order = "ASC" if ascending else "DESC"
        sql = f"""
        SELECT meta_id, session_meta, role, content, content_format, seq, token_count, metadata
        FROM public.v_chat_messages
        WHERE session_meta = :session_meta
          AND (:after_seq IS NULL OR seq > :after_seq)
        ORDER BY seq {order}
        LIMIT :limit;
        """
        rows = self._select(sql, {"session_meta": session_meta, "after_seq": after_seq, "limit": limit})
        return [dict(r) for r in rows]  # type: ignore[return-value]

    def delete_message(self, message_meta: str) -> int:
        return self._execute("DELETE FROM public.v_chat_messages WHERE meta_id = :message_meta;", {"message_meta": message_meta}) or 0

    def get_context_by_budget(self, session_meta: str, *, max_chars: int = 12000) -> List[MessageRow]:
        sql = """
        WITH msgs AS (
          SELECT meta_id, role, content, COALESCE(token_count, GREATEST(length(content), 1)) AS unit, seq
          FROM public.v_chat_messages
          WHERE session_meta = :session_meta
          ORDER BY seq DESC
          LIMIT 1000
        ),
        acc AS (
          SELECT *, SUM(unit) OVER (ORDER BY seq DESC) AS cum
          FROM msgs
        )
        SELECT meta_id, :session_meta AS session_meta, role, content, 'text'::text AS content_format, seq, NULL::int AS token_count, '{}'::jsonb AS metadata
        FROM acc
        WHERE cum <= :max_chars
        ORDER BY seq ASC;
        """
        rows = self._select(sql, {"session_meta": session_meta, "max_chars": max_chars})
        return [dict(r) for r in rows]  # type: ignore[return-value]

    # --- blobs & attachments -------------------------------------------------
    def upsert_blob(self, *, content: bytes, sha256: str, size_bytes: int) -> str:
        """Insert blob if not exists and return blob meta id."""
        row = self._select(
            "SELECT meta_id FROM public.t_blobs WHERE blob_sha256=:sha AND blob_bytes_len=:len LIMIT 1",
            {"sha": sha256, "len": size_bytes},
        )
        if row:
            return row[0]["meta_id"]
        # create a new record meta id
        blob_meta = self._select("INSERT INTO public.tb_record_meta DEFAULT VALUES RETURNING id;", {})[0]["id"]
        self._execute(
            "INSERT INTO public.t_blobs(meta_id, blob_sha256, blob_bytes_len, blob_content) "
            "VALUES (:meta, :sha, :len, :content)",
            {"meta": blob_meta, "sha": sha256, "len": size_bytes, "content": content},
        )
        return blob_meta

    def attach_blob_to_message(self, *, message_meta: str, filename: str, mime_type: str, size_bytes: int, blob_meta_id: str) -> str:
        """Attach an existing blob (by meta id) to a message and return attachment meta id."""
        row = self._select(
            "INSERT INTO public.v_message_attachments (message_meta, filename, mime_type, size_bytes, blob_meta_id) "
            "VALUES (:msg, :name, :mime, :size, :blob) RETURNING meta_id;",
            {"msg": message_meta, "name": filename, "mime": mime_type, "size": size_bytes, "blob": blob_meta_id},
        )
        return row[0]["meta_id"]

    def list_attachments(self, *, message_meta: str) -> List[dict]:
        rows = self._select(
            "SELECT meta_id, filename, mime_type, size_bytes, blob_meta_id, blob_sha256 "
            "FROM public.v_message_attachments WHERE message_meta=:msg ORDER BY meta_id",
            {"msg": message_meta},
        )
        return [dict(r) for r in rows]

    def delete_attachment(self, *, attachment_meta: str) -> int:
        return self._execute("DELETE FROM public.v_message_attachments WHERE meta_id=:mid", {"mid": attachment_meta}) or 0
