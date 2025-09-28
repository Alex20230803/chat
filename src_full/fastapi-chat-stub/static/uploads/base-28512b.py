# db/repositories/base.py
from __future__ import annotations
from typing import Any, Dict, List
from sqlalchemy import text
from sqlalchemy.engine import Engine, RowMapping

class BaseRepo:
    def __init__(self, engine: Engine):
        self.engine = engine

    def _select(self, sql: str, params: Dict[str, Any]) -> List[RowMapping]:
        with self.engine.connect() as conn:
            return conn.execute(text(sql), params).mappings().all()

    def _execute(self, sql: str, params: dict | None = None):

        # ВАЖНО: begin() => commit при выходе, даже если внутри SELECT-функция делает DML
        with self.engine.begin() as conn:
            res = conn.execute(text(sql), params or {})
            # поддержим и функции/RETURNING, где есть результат
            try:
                return res.rowcount
            except Exception:
                return None
