# db/config.py
from __future__ import annotations
from dataclasses import dataclass
from functools import lru_cache
from pathlib import Path
import yaml

CONFIG_PATH = Path(__file__).with_name("config.yaml")

@dataclass(frozen=True)
class DatabaseConfig:
    host: str | None = None
    port: int | None = None
    name: str | None = None
    user: str | None = None
    password: str | None = None
    service: str | None = None
    sslmode: str | None = None
    options: str | None = None

@dataclass(frozen=True)
class PoolConfig:
    pool_size: int = 5
    max_overflow: int = 10
    pool_pre_ping: bool = True

@dataclass(frozen=True)
class Settings:
    database: DatabaseConfig
    pool: PoolConfig

def _validate(d: dict) -> Settings:
    db = d.get("database") or {}
    pool = d.get("pool") or {}

    # либо service, либо набор полей host/port/name/user/password
    if not db.get("service"):
        required = ["host", "port", "name", "user", "password"]
        missing = [k for k in required if db.get(k) in (None, "")]
        if missing:
            raise ValueError(f"db/config.yaml: отсутствуют поля {missing} в .database (если нет service)")

    return Settings(
        database=DatabaseConfig(
            host=db.get("host"),
            port=int(db["port"]) if db.get("port") is not None else None,
            name=db.get("name"),
            user=db.get("user"),
            password=db.get("password"),
            service=db.get("service"),
            sslmode=db.get("sslmode"),
            options=db.get("options"),
        ),
        pool=PoolConfig(
            pool_size=int(pool.get("pool_size", 5)),
            max_overflow=int(pool.get("max_overflow", 10)),
            pool_pre_ping=bool(pool.get("pool_pre_ping", True)),
        ),
    )

@lru_cache(maxsize=1)
def get_settings(config_path: Path | None = None) -> Settings:
    path = config_path or CONFIG_PATH
    if not path.exists():
        raise FileNotFoundError(f"Не найден конфиг: {path}")
    with open(path, "r", encoding="utf-8") as f:
        data = yaml.safe_load(f) or {}
    return _validate(data)
