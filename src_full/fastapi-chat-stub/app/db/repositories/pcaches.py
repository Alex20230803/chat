# db/repositories/pcaches.py
from __future__ import annotations
from dataclasses import dataclass
from typing import Any, Dict, List, Optional

from sqlalchemy import text as sql_text
from .base import BaseRepo


@dataclass(frozen=True)
class PcacheRecord:
    meta_id: int
    pcache_prompt: Optional[str]
    pcache_prompt_hash: str
    pcache_response: Optional[str]
    pcache_tokens_used: Optional[int]
    pcache_content: Optional[str]  # <-- новое поле из VIEW


def _row_to_record(row: Dict[str, Any]) -> PcacheRecord:
    d = dict(row)
    return PcacheRecord(
        meta_id=int(d["meta_id"]),
        pcache_prompt=d.get("pcache_prompt"),
        pcache_prompt_hash=str(d["pcache_prompt_hash"]),
        pcache_response=d.get("pcache_response"),
        pcache_tokens_used=d.get("pcache_tokens_used"),
        pcache_content=d.get("pcache_content"),
    )


class PcachesRepo(BaseRepo):
    """
    Работа строго с VIEW public.v_pcaches (см. SQL выше).
    Поле pcache_content вычисляется в БД и уже содержит «текст ответа».
    """

    # ---------- SELECT ----------

    def get_by_meta_id(self, meta_id: int) -> PcacheRecord:
        rows = self._select(
            """
            SELECT meta_id,
                   pcache_prompt,
                   pcache_prompt_hash,
                   pcache_response,
                   pcache_tokens_used,
                   pcache_content
            FROM public.v_pcaches
            WHERE meta_id = :id
            """,
            {"id": meta_id},
        )
        if not rows:
            raise KeyError(f"meta_id={meta_id} не найден в v_pcaches")
        return _row_to_record(dict(rows[0]))

    def list_recent(self, *, limit: int = 50) -> List[PcacheRecord]:
        rows = self._select(
            """
            SELECT meta_id,
                   pcache_prompt,
                   pcache_prompt_hash,
                   pcache_response,
                   pcache_tokens_used,
                   pcache_content
            FROM public.v_pcaches
            ORDER BY meta_id DESC
            LIMIT :lim
            """,
            {"lim": int(limit)},
        )
        return [_row_to_record(dict(r)) for r in rows]

    def find_by_hash(self, pcache_prompt_hash: str, *, limit: int = 1) -> List[PcacheRecord]:
        rows = self._select(
            """
            SELECT meta_id,
                   pcache_prompt,
                   pcache_prompt_hash,
                   pcache_response,
                   pcache_tokens_used,
                   pcache_content
            FROM public.v_pcaches
            WHERE pcache_prompt_hash = :h
            ORDER BY meta_id DESC
            LIMIT :lim
            """,
            {"h": pcache_prompt_hash, "lim": int(limit)},
        )
        return [_row_to_record(dict(r)) for r in rows]

    # ---------- INSERT ----------

    def create(
        self,
        pcache_prompt: Optional[str] = None,
        pcache_prompt_hash: Optional[str] = None,
        pcache_response: Optional[str] = None,
        pcache_tokens_used: Optional[int] = None,
    ) -> PcacheRecord:
        """
        Вставка через VIEW. Триггер/правило внутри VIEW может реализовывать идемпотентность.
        """
        sql = """
        INSERT INTO public.v_pcaches (
            pcache_prompt,
            pcache_prompt_hash,
            pcache_response,
            pcache_tokens_used
        ) VALUES (
            :prompt,
            :hash,
            :resp,
            :toks
        )
        RETURNING meta_id,
                  pcache_prompt,
                  pcache_prompt_hash,
                  pcache_response,
                  pcache_tokens_used,
                  pcache_content
        """
        params = {
            "prompt": pcache_prompt,
            "hash": pcache_prompt_hash,
            "resp": pcache_response,
            "toks": pcache_tokens_used,
        }
        with self.engine.begin() as conn:
            row = conn.execute(sql_text(sql), params).mappings().one()
        return _row_to_record(dict(row))

    def get_or_create(
        self,
        *,
        pcache_prompt: Optional[str] = None,
        pcache_prompt_hash: Optional[str] = None,
        pcache_response: Optional[str] = None,
        pcache_tokens_used: Optional[int] = None,
    ) -> PcacheRecord:
        if pcache_prompt_hash:
            found = self.find_by_hash(pcache_prompt_hash, limit=1)
            if found:
                return found[0]
        return self.create(
            pcache_prompt=pcache_prompt,
            pcache_prompt_hash=pcache_prompt_hash,
            pcache_response=pcache_response,
            pcache_tokens_used=pcache_tokens_used,
        )
