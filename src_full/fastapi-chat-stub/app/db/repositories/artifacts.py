# db/repositories/artifacts.py
from __future__ import annotations
from typing import Any, Dict, List, Literal, Optional
from .base import BaseRepo

ViewName = Literal["v_in", "v_out"]
SearchField = Literal["sub_kind_name", "sub_kind_value", "kind_name"]

class ArtifactsRepo(BaseRepo):
    """
    Репозиторий для чтения sub_kind_code из v_in / v_out.
    Динамически определяет:
      - имя столбца subkind: sub_kind_code
      - доступные поля для поиска (sub_kind_name / kind_name / sub_kind_value)
    """

    __ALLOWED_VIEWS: set[ViewName] = {"v_in", "v_out"}
    __POSSIBLE_SUBKIND_COLS = ("sub_kind_code",)
    __POSSIBLE_SEARCH_FIELDS: tuple[SearchField, ...] = (
        "sub_kind_name",
        "sub_kind_value",
        "kind_name",
    )

    __subkind_col_cache: Dict[str, str] = {}
    __search_fields_cache: Dict[str, set[str]] = {}

    def _resolve_subkind_col(self, view: str) -> str:
        if view in self.__subkind_col_cache:
            return self.__subkind_col_cache[view]

        sql = """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = :view
              AND column_name = ANY(:candidates)
        """
        rows = self._select(sql, {"view": view, "candidates": list(self.__POSSIBLE_SUBKIND_COLS)})
        if not rows:
            raise RuntimeError(f"Не удалось определить столбец sub_kind_code для представления {view}")
        col_name = rows[0]["column_name"]
        self.__subkind_col_cache[view] = col_name
        return col_name

    def _resolve_search_fields(self, view: str) -> set[str]:
        if view in self.__search_fields_cache:
            return self.__search_fields_cache[view]

        sql = """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = :view
              AND column_name = ANY(:candidates)
        """
        rows = self._select(sql, {"view": view, "candidates": list(self.__POSSIBLE_SEARCH_FIELDS)})
        available = {r["column_name"] for r in rows}
        self.__search_fields_cache[view] = available
        return available

    def list_subkinds(
        self,
        *,
        view: ViewName,
        like_value: str,
        search_in: SearchField = "sub_kind_name",
        limit: Optional[int] = None,
        offset: int = 0,
        case_insensitive: bool = True,
    ) -> List[str]:
        if view not in self.__ALLOWED_VIEWS:
            raise ValueError(f"Unsupported view: {view}")

        available_fields = self._resolve_search_fields(view)
        if search_in not in available_fields:
            raise ValueError(f"Поле поиска '{search_in}' недоступно в представлении '{view}'")

        subkind_col = self._resolve_subkind_col(view)

        where_sql = f"{search_in} ILIKE :pattern" if case_insensitive else f"{search_in} LIKE :pattern"

        sql = f"""
            SELECT DISTINCT {subkind_col} AS subkind
            FROM {view}
            WHERE ({where_sql})
            ORDER BY {subkind_col} NULLS LAST
        """
        params: Dict[str, Any] = {"pattern": f"%{like_value}%"}
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        if offset:
            sql += " OFFSET :off"
            params["off"] = int(offset)

        rows = self._select(sql, params)
        return [r["subkind"] for r in rows]

    def list_subkinds_any_field(
        self,
        *,
        view: ViewName,
        like_value: str,
        limit: Optional[int] = None,
        offset: int = 0,
        case_insensitive: bool = True,
    ) -> List[str]:
        if view not in self.__ALLOWED_VIEWS:
            raise ValueError(f"Unsupported view: {view}")

        available_fields = self._resolve_search_fields(view)
        if not available_fields:
            raise RuntimeError(
                f"В {view} нет ни одного из полей для поиска: {', '.join(self.__POSSIBLE_SEARCH_FIELDS)}"
            )

        subkind_col = self._resolve_subkind_col(view)
        like_op = "ILIKE" if case_insensitive else "LIKE"

        # динамически строим OR из доступных полей
        where_parts = [f"COALESCE({fld}, '') {like_op} :pattern" for fld in sorted(available_fields)]
        where_sql = " OR ".join(where_parts)

        sql = f"""
            SELECT DISTINCT {subkind_col} AS subkind
            FROM {view}
            WHERE ({where_sql})
            ORDER BY {subkind_col} NULLS LAST
        """
        params: Dict[str, Any] = {"pattern": f"%{like_value}%"}
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        if offset:
            sql += " OFFSET :off"
            params["off"] = int(offset)

        rows = self._select(sql, params)
        return [r["subkind"] for r in rows]

    # Шорткаты
    def list_subkinds_in(self, like_value: str, search_in: SearchField = "sub_kind_value", **kwargs) -> List[str]:
        return self.list_subkinds(view="v_in", like_value=like_value, search_in=search_in, **kwargs)

    def list_subkinds_out(self, like_value: str, search_in: SearchField = "sub_kind_value", **kwargs) -> List[str]:
        return self.list_subkinds(view="v_out", like_value=like_value, search_in=search_in, **kwargs)