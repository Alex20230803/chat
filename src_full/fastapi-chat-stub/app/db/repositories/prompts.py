# db/repositories/prompts.py
from __future__ import annotations
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
from .base import BaseRepo

@dataclass(frozen=True)
class PromptRecord:
    user_user: str
    prompt_key_key: str
    user_id: int
    prompt_metadata: Dict[str, Any]
    prompt_body: str
    prompt_key_id: int
    prompt_id: int

class PromptsRepo(BaseRepo):
    def get_by_key(
        self, key: str, *, user_user: Optional[str] = None, limit: Optional[int] = None
    ) -> List[PromptRecord]:
        sql = """
            SELECT *
            FROM public.v_prompts
            WHERE prompt_key = :key
        """
        params: Dict[str, Any] = {"key": key}
        sql += " ORDER BY prompt_id DESC"
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)

        rows = self._select(sql, params)
        return [PromptRecord(**dict(r)) for r in rows]

    def get_latest(self, key: str, *, user_user: Optional[str] = None) -> PromptRecord:
        recs = self.get_by_key(key, user_user=user_user, limit=1)
        if not recs:
            who = f' и user="{user_user}"' if user_user else ""
            raise KeyError(f'нет записей для key="{key}"{who}')
        return recs[0]

    def get_body(self, key: str, *, user_user: Optional[str] = None) -> str:
        return self.get_latest(key, user_user=user_user).prompt_body

    def get_metadata(self, key: str, *, user_user: Optional[str] = None) -> Dict[str, Any]:
        return self.get_latest(key, user_user=user_user).prompt_metadata
