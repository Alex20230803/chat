# db/repositories/user_docs.py
from __future__ import annotations
from typing import Any, Dict, List, Literal, Optional, Sequence, Tuple, Union
from uuid import UUID
from .base import BaseRepo

SearchField = Literal["user_content", "user_title"]

class UserDocsRepo(BaseRepo):
    """
    Репозиторий для v_user_docs: поиск + INSERT/UPDATE/DELETE через триггеры вью.
    Поля вью: meta_id, user_id, user_title, user_lang_iso, user_content_format,
              user_content_len, user_sha256, user_content.
    """

    __VIEW = "v_user_docs"
    __POSSIBLE_SEARCH_FIELDS: Tuple[SearchField, ...] = ("user_content", "user_title")

    __search_fields_cache: Optional[set[str]] = None

    # ---------------- internals ----------------

    def _resolve_available_search_fields(self) -> set[str]:
        if self.__search_fields_cache is not None:
            return self.__search_fields_cache
        rows = self._select(
            """
            SELECT column_name
            FROM information_schema.columns
            WHERE table_schema = 'public'
              AND table_name = :view
              AND column_name = ANY(:candidates)
            """,
            {"view": self.__VIEW, "candidates": list(self.__POSSIBLE_SEARCH_FIELDS)},
        )
        self.__search_fields_cache = {r["column_name"] for r in rows}
        return self.__search_fields_cache

    @staticmethod
    def _like_op(case_insensitive: bool) -> str:
        return "ILIKE" if case_insensitive else "LIKE"

    # ---------------- reads ----------------

    def list_meta_ids(
        self,
        *,
        like_value: str,
        search_in: SearchField = "user_content",
        limit: Optional[int] = None,
        offset: int = 0,
        case_insensitive: bool = True,
        user_id: Optional[Union[str, UUID]] = None,
        lang_iso: Optional[str] = None,
    ) -> List[int]:
        available = self._resolve_available_search_fields()
        if search_in not in available:
            raise RuntimeError(
                f"В {self.__VIEW} нет колонки '{search_in}'. "
                f"Доступны: {', '.join(sorted(available)) or '—'}"
            )

        like_op = self._like_op(case_insensitive)
        where = [f"{search_in} {like_op} :pattern"]
        params: Dict[str, Any] = {"pattern": f"%{like_value}%"}
        if user_id is not None:
            where.append("user_id = :user_id")
            params["user_id"] = str(user_id)
        if lang_iso is not None:
            where.append("user_lang_iso = :lang_iso")
            params["lang_iso"] = lang_iso

        sql = f"""
            SELECT DISTINCT meta_id
            FROM {self.__VIEW}
            WHERE {' AND '.join(where)}
            ORDER BY meta_id
        """
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        if offset:
            sql += " OFFSET :off"
            params["off"] = int(offset)

        rows = self._select(sql, params)
        return [int(r["meta_id"]) for r in rows]

    def list_titles(
        self,
        *,
        like_value: str,
        search_in: SearchField = "user_content",
        limit: Optional[int] = None,
        offset: int = 0,
        case_insensitive: bool = True,
        user_id: Optional[Union[str, UUID]] = None,
        lang_iso: Optional[str] = None,
    ) -> List[str]:
        available = self._resolve_available_search_fields()
        if search_in not in available:
            raise RuntimeError(
                f"В {self.__VIEW} нет колонки '{search_in}'. "
                f"Доступны: {', '.join(sorted(available)) or '—'}"
            )

        like_op = self._like_op(case_insensitive)
        where = [f"{search_in} {like_op} :pattern"]
        params: Dict[str, Any] = {"pattern": f"%{like_value}%"}
        if user_id is not None:
            where.append("user_id = :user_id")
            params["user_id"] = str(user_id)
        if lang_iso is not None:
            where.append("user_lang_iso = :lang_iso")
            params["lang_iso"] = lang_iso

        sql = f"""
            SELECT DISTINCT user_title
            FROM {self.__VIEW}
            WHERE {' AND '.join(where)}
            ORDER BY user_title NULLS LAST
        """
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        if offset:
            sql += " OFFSET :off"
            params["off"] = int(offset)

        rows = self._select(sql, params)
        return [r["user_title"] for r in rows]

    def list_meta_ids_any_field(
        self,
        *,
        like_value: str,
        limit: Optional[int] = None,
        offset: int = 0,
        case_insensitive: bool = True,
        user_id: Optional[Union[str, UUID]] = None,
        lang_iso: Optional[str] = None,
    ) -> List[int]:
        available = self._resolve_available_search_fields()
        if not available:
            raise RuntimeError(
                f"В {self.__VIEW} нет ни одного из полей для поиска: "
                f"{', '.join(self.__POSSIBLE_SEARCH_FIELDS)}"
            )
        like_op = self._like_op(case_insensitive)
        text_ors = [f"COALESCE({fld}, '') {like_op} :pattern" for fld in sorted(available)]
        params: Dict[str, Any] = {"pattern": f"%{like_value}%"}
        where: List[str] = [f"({' OR '.join(text_ors)})"]
        if user_id is not None:
            where.append("user_id = :user_id")
            params["user_id"] = str(user_id)
        if lang_iso is not None:
            where.append("user_lang_iso = :lang_iso")
            params["lang_iso"] = lang_iso

        sql = f"""
            SELECT DISTINCT meta_id
            FROM {self.__VIEW}
            WHERE {' AND '.join(where)}
            ORDER BY meta_id
        """
        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        if offset:
            sql += " OFFSET :off"
            params["off"] = int(offset)

        rows = self._select(sql, params)
        return [int(r["meta_id"]) for r in rows]

    # ---------------- writes ----------------
    # ВАЖНО: вью поддерживает INSTEAD OF INSERT/UPDATE/DELETE (см. триггеры),
    # поэтому можно писать прямо в неё, а триггеры разложат в базовые таблицы.

    def insert_doc(
        self,
        *,
        user_id: Union[str, UUID],
        user_title: Optional[str],
        user_content: str,
        user_lang_iso: Optional[str] = None,
        user_content_format: Optional[str] = None,
    ) -> int:
        """
        Вставка документа через v_user_docs, возвращает meta_id.
        Минимально достаточно user_id + user_content; формат/язык/заголовок — опционально.
        Поля длины/sha256 не передаём — пусть считает триггер.
        """
        cols: List[str] = ["user_id", "user_content"]
        vals: List[str] = [":user_id", ":user_content"]
        params: Dict[str, Any] = {"user_id": str(user_id), "user_content": user_content}

        if user_title is not None:
            cols.append("user_title")
            vals.append(":user_title")
            params["user_title"] = user_title
        if user_lang_iso is not None:
            cols.append("user_lang_iso")
            vals.append(":user_lang_iso")
            params["user_lang_iso"] = user_lang_iso
        if user_content_format is not None:
            cols.append("user_content_format")
            vals.append(":user_content_format")
            params["user_content_format"] = user_content_format

        sql = f"""
            INSERT INTO {self.__VIEW} ({', '.join(cols)})
            VALUES ({', '.join(vals)})
            RETURNING meta_id
        """
        # используем транзакцию и читаем RETURNING
        from sqlalchemy import text
        with self.engine.begin() as conn:
            row = conn.execute(text(sql), params).mappings().first()
            if not row:
                raise RuntimeError("INSERT v_user_docs не вернул meta_id")
            return int(row["meta_id"])

    def update_doc(
        self,
        *,
        meta_id: int,
        user_title: Optional[Optional[str]] = None,        # None = не менять;  явный NULL => set NULL
        user_content: Optional[Optional[str]] = None,
        user_lang_iso: Optional[Optional[str]] = None,
        user_content_format: Optional[Optional[str]] = None,
    ) -> int:
        """
        Частичное обновление. Передавай только то, что нужно менять.
        Чтобы сбросить поле в NULL — передай аргумент явным None внутри Optional (как сейчас).
        Ничего не передавать = поле не трогаем (оставить None по умолчанию).
        Возвращает количество обновлённых строк (0 или 1).
        """
        sets: List[str] = []
        params: Dict[str, Any] = {"id": int(meta_id)}

        def add(col: str, val: Any, param: str):
            sets.append(f"{col} = {param}")
            params[param.lstrip(':')] = val

        if user_title is not None:
            add("user_title", user_title, ":user_title")
        if user_content is not None:
            add("user_content", user_content, ":user_content")
        if user_lang_iso is not None:
            add("user_lang_iso", user_lang_iso, ":user_lang_iso")
        if user_content_format is not None:
            add("user_content_format", user_content_format, ":user_content_format")

        if not sets:
            return 0  # нечего обновлять

        sql = f"""
            UPDATE {self.__VIEW}
            SET {', '.join(sets)}
            WHERE meta_id = :id
        """
        return self._execute(sql, params)

    def delete_doc(self, *, meta_id: int) -> int:
        """
        Удаление (мягкое — через триггер): вернёт 1, если удаление прошло.
        """
        sql = f"DELETE FROM {self.__VIEW} WHERE meta_id = :id"
        return self._execute(sql, {"id": int(meta_id)})
