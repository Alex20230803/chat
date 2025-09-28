# db/repositories/agent_sub_kinds.py
from __future__ import annotations
from dataclasses import dataclass, asdict
from typing import Any, Dict, List, Literal, Optional, Sequence, Union
from .base import BaseRepo
import inspect
import ast

InOut = Literal["input", "output", "global"]
ReturnMode = Literal["objects", "json"]


@dataclass
class AgentSubKind:
    """
    Модель строки из get_agent_sub_kinds(:agent_name).

    Примерные поля (по дампу CSV):
      - sub_kind_code, sub_kind_name, sub_kind_type, sub_kind_default_value
      - in_out, meta_id, val, result
    """
    sub_kind_code: str
    sub_kind_name: Optional[str] = None
    sub_kind_type: Optional[str] = None
    sub_kind_default_value: Optional[Any] = None
    in_out: Optional[InOut] = None
    meta_id: Optional[str] = None  # UUID в текстовом представлении
    val: Optional[Any] = None
    result: Optional[Any] = None

    @staticmethod
    def from_row(row: Dict[str, Any]) -> "AgentSubKind":
        # Аккуратно вытаскиваем значения, учитывая возможные NULL/NaN
        def norm(x: Any) -> Any:
            # Приводим NaN из pandas/psycopg к None, если такое вдруг просочится
            try:
                import math
                if isinstance(x, float) and math.isnan(x):
                    return None
            except Exception:
                pass
            # Простейшая нормализация булевых, если приходят строками "True"/"False"
            if isinstance(x, str) and x in ("True", "False"):
                return x == "True"
            return x

        return AgentSubKind(
            sub_kind_code=row.get("sub_kind_code"),
            sub_kind_name=norm(row.get("sub_kind_name")),
            sub_kind_type=norm(row.get("sub_kind_type")),
            sub_kind_default_value=norm(row.get("sub_kind_default_value")),
            in_out=norm(row.get("in_out")),
            meta_id=norm(row.get("meta_id")),
            val=norm(row.get("val")),
            result=norm(row.get("result")),
        )

    def to_dict(self) -> Dict[str, Any]:
        return asdict(self)


class AgentSubKindsRepo(BaseRepo):
    """
    Репозиторий выборки сабкиндов агента через функцию get_agent_sub_kinds(:agent_name).

    Основные методы:
      - fetch_objects(agent_name, ...) -> List[AgentSubKind]
      - fetch_json(agent_name, ...)    -> List[dict]
      - fetch(..., return_as=...)      -> объединённый интерфейс

    Фильтры (опционально):
      - in_out: 'input' | 'output'
      - sub_kind_code_like: поиск по sub_kind_code (ILIKE '%...%')
    """

    __ALLOWED_IN_OUT: set[str] = {"input", "output", "global"}

    def _build_sql(
        self,
        *,
        with_where_in_out: bool,
        with_where_code_like: bool,
        case_insensitive: bool,
    ) -> str:
        base = "SELECT * FROM get_agent_sub_kinds(:agent_name)"
        wheres: List[str] = []

        if with_where_in_out:
            wheres.append("in_out = :in_out")

        if with_where_code_like:
            op = "ILIKE" if case_insensitive else "LIKE"
            wheres.append(f"sub_kind_code {op} :code_like")

        if wheres:
            base += " WHERE " + " AND ".join(wheres)

        base += " ORDER BY in_out NULLS LAST, sub_kind_code"
        return base

    def fetch(
        self,
        agent_name: str,
        *,
        in_out: Optional[InOut] = None,
        sub_kind_code_like: Optional[str] = None,
        case_insensitive: bool = True,
        limit: Optional[int] = None,
        offset: int = 0,
        return_as: ReturnMode = "objects",
    ) -> Union[List[AgentSubKind], List[Dict[str, Any]]]:
        """
        Универсальный метод. Управляйте форматом через return_as='objects' | 'json'.
        """
        params: Dict[str, Any] = {"agent_name": agent_name}
        with_where_in_out = False
        with_where_code_like = False

        if in_out is not None:
            if in_out not in self.__ALLOWED_IN_OUT:
                raise ValueError(f"Invalid in_out: {in_out!r}. Допустимо: {self.__ALLOWED_IN_OUT}")
            params["in_out"] = in_out
            with_where_in_out = True

        if sub_kind_code_like:
            params["code_like"] = f"%{sub_kind_code_like}%"
            with_where_code_like = True

        sql = self._build_sql(
            with_where_in_out=with_where_in_out,
            with_where_code_like=with_where_code_like,
            case_insensitive=case_insensitive,
        )

        if limit is not None:
            sql += " LIMIT :lim"
            params["lim"] = int(limit)
        if offset:
            sql += " OFFSET :off"
            params["off"] = int(offset)

        rows = self._select(sql, params)

        if return_as == "objects":
            return [AgentSubKind.from_row(r) for r in rows]
        elif return_as == "json":
            # Преобразуем к сериализуемым dict'ам
            return [AgentSubKind.from_row(r).to_dict() for r in rows]
        else:
            raise ValueError(f"Unsupported return_as={return_as!r}")

    # Удобные шорткаты

    def fetch_objects(
        self,
        agent_name: str,
        *,
        in_out: Optional[InOut] = None,
        sub_kind_code_like: Optional[str] = None,
        case_insensitive: bool = True,
        limit: Optional[int] = None,
        offset: int = 0,
    ) -> List[AgentSubKind]:
        return self.fetch(
            agent_name,
            in_out=in_out,
            sub_kind_code_like=sub_kind_code_like,
            case_insensitive=case_insensitive,
            limit=limit,
            offset=offset,
            return_as="objects",
        )  # type: ignore[return-value]

    def fetch_json(
        self,
        agent_name: str,
        *,
        in_out: Optional[InOut] = None,
        sub_kind_code_like: Optional[str] = None,
        case_insensitive: bool = True,
        limit: Optional[int] = None,
        offset: int = 0,
    ) -> List[Dict[str, Any]]:
        return self.fetch(
            agent_name,
            in_out=in_out,
            sub_kind_code_like=sub_kind_code_like,
            case_insensitive=case_insensitive,
            limit=limit,
            offset=offset,
            return_as="json",
        )  # type: ignore[return-value]


    def get_by_code_obj(
            self,
            agent_name: str,
            sub_kind_code: str,
            in_out: str,
            obj_type: str
        ):

        res = self.get_one_by_code(agent_name, sub_kind_code, in_out=in_out, return_as="json")['result']

        if obj_type == 'dict':
            res = ast.literal_eval(res)

        return res

    def get_out_to_in(
            self,
            from_agent_name: str,
            to_agent_name: str,
            sub_kind_code: str,
            value_from_dict: str = None
        ):

        res = self.get_one_by_code(from_agent_name, sub_kind_code, in_out="output", return_as="json")['result']

        # обрабатываем пока только один тип - dict
        if value_from_dict is not None:
            res_type = self.get_one_by_code(from_agent_name, sub_kind_code, in_out="output", return_as="json")['sub_kind_type']

            if res_type == 'dict':
                res = ast.literal_eval(res)["modules"][value_from_dict]

        meta_id = self.get_one_by_code(to_agent_name, sub_kind_code, in_out="input", return_as="json")['meta_id']
        self.create_user_doc(meta_id, res)

        return res

    def get_one_by_code(
        self,
        agent_name: str,
        sub_kind_code: str,
        *,
        in_out: Optional[InOut] = None,
        return_as: ReturnMode = "objects",
    ) -> Union[AgentSubKind, Dict[str, Any], None]:
        """
        Возвращает одну запись по точному коду сабкинда (или None).
        """
        params: Dict[str, Any] = {"agent_name": agent_name, "code": sub_kind_code}
        sql = "SELECT * FROM get_agent_sub_kinds(:agent_name) WHERE sub_kind_code = :code"
        if in_out is not None:
            if in_out not in self.__ALLOWED_IN_OUT:
                raise ValueError(f"Invalid in_out: {in_out!r}. Допустимо: {self.__ALLOWED_IN_OUT}")
            sql += " AND in_out = :in_out"
            params["in_out"] = in_out
        sql += " ORDER BY in_out NULLS LAST, sub_kind_code LIMIT 1"

        rows = self._select(sql, params)
        if not rows:
            return None
        obj = AgentSubKind.from_row(rows[0])
        return obj if return_as == "objects" else obj.to_dict()

# добавить внутрь class AgentSubKindsRepo(BaseRepo):

    def create_user_doc(
        self,
        user_title: str,
        user_content: str,
        *,
        user_user: str | None = None,          # автор/владелец (если у вас есть такое поле)
        doc_kind_code: str | None = None,      # тип документа (если используется)
        doc_ext: str | None = None,            # 'txt', 'md', ...
        in_out: InOut | None = None,           # 'input' | 'output' (если уместно)
        sub_kind_code: str | None = None,      # связка с сабкиндом
        tags: list[str] | None = None,         # массив тегов, если поле есть (jsonb/text[])
        meta_parent_id: str | None = None,     # если есть иерархия
        extra: dict | None = None,             # дополнительные произвольные поля -> столбцы
    ) -> dict:
        """
        Создаёт запись в v_user_docs. Обязательные: user_title, user_content.
        Остальные параметры добавляются в INSERT только если заданы.

        Возвращает словарь с полями из RETURNING (meta_id, user_doc_id и пр., если есть).
        """
        user_title = str(user_title)

        cols = ["user_title", "user_content"]
        vals = [":user_title", ":user_content"]
        params: dict[str, object] = {
            "user_title": user_title,
            "user_content": user_content,
        }

        def add(name: str, value: object | None):
            if value is None:
                return
            cols.append(name)
            vals.append(f":{name}")
            params[name] = value

        add("user_user", user_user)
        add("doc_kind_code", doc_kind_code)
        add("doc_ext", doc_ext)
        add("in_out", in_out)
        add("sub_kind_code", sub_kind_code)
        add("meta_parent_id", meta_parent_id)

        # массив/JSON поля — передаём как есть
        if tags is not None:
            add("tags", tags)
        if extra:
            for k, v in extra.items():
                add(k, v)

        sql = (
            f"select  * FROM upsert_user_doc({', '.join(vals)})"
            # подберите список под вашу view/триггер: meta_id, user_doc_id, created и т.п.
        )

        # Используем _select для получения RETURNING
        rows = self._execute(sql, params)
        return rows
