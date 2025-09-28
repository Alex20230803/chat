# db/core.py
from __future__ import annotations
from functools import lru_cache
from pathlib import Path
from typing import Any, Dict
import yaml
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine

def load_config(path: Path) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as f:
        return yaml.safe_load(f)

@lru_cache(maxsize=1)
def get_engine(config_path: Path) -> Engine:
    cfg = load_config(config_path)["database"]
    # psycopg2 driver, пул + pre_ping, statement_timeout
    engine = create_engine(
        f"postgresql+psycopg2://{cfg['user']}:{cfg['password']}@{cfg['host']}:{cfg['port']}/{cfg['name']}",
        pool_pre_ping=True,
        pool_size=5,
        max_overflow=10,
        future=True,
        connect_args={"options": "-c statement_timeout=30000 -c timezone=UTC"},
    )
    return engine

class Database:
    """Общий доступ к Engine + фабрика репозиториев."""
    def __init__(self, engine: Engine):
        self.engine = engine

    @classmethod
    def from_config(cls, config_path: Path) -> "Database":
        return cls(get_engine(config_path))
