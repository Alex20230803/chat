# db/repositories/llms.py
from __future__ import annotations
from dataclasses import dataclass
from typing import Any, Dict, List, Optional
from .base import BaseRepo

@dataclass(frozen=True)
class LlmRecord:
    # подстрой под реальные колонки v_llms
    llm_key: str
    llm_key: str
    llm_model: str
    llm_interface: str

class LlmsRepo(BaseRepo):
    def list(self, *, llm_name: Optional[str] = None, limit: Optional[int] = 1) -> List[Dict[str, Any]]:
        sql = "SELECT * FROM dict.llms()"
        params: Dict[str, Any] = {}
        if llm_name:
            sql = "SELECT * FROM dict.llms(:llm_name)"
            params["llm_name"] = llm_name
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        return [dict(r) for r in self._select(sql, params)]

    def get_by_name(self, llm_name: str) -> Dict[str, Any]:
        rows = self._select(
            "SELECT * FROM dict.llms(:m)",
            {"m": llm_name},
        )
        if not rows:
            raise KeyError(f'model "{llm_name}" не найдена')
        return dict(rows[0])
