# db/engine.py
from sqlalchemy import create_engine
from sqlalchemy.engine import Engine
from typing import Mapping, Any
from .config import Settings, DatabaseConfig, PoolConfig

def _build_connect_args(db: DatabaseConfig) -> Mapping[str, Any]:
    args: dict[str, Any] = {}
    if db.service:
        args["service"] = db.service
    if db.options:
        args["options"] = db.options
    if db.sslmode:
        # для psycopg2 можно прокинуть через options или в строку, но оставим как есть
        args["sslmode"] = db.sslmode
    return args

def create_engine_from_settings(cfg: Settings) -> Engine:
    db, pool = cfg.database, cfg.pool

    if db.service:
        url = "postgresql+psycopg2://"
        return create_engine(
            url,
            connect_args=_build_connect_args(db),
            pool_pre_ping=pool.pool_pre_ping,
            pool_size=pool.pool_size,
            max_overflow=pool.max_overflow,
            future=True,
        )

    # явный DSN
    url = f"postgresql+psycopg2://{db.user}:{db.password}@{db.host}:{db.port}/{db.name}"
    return create_engine(
        url,
        connect_args=_build_connect_args(cfg.database),
        pool_pre_ping=pool.pool_pre_ping,
        pool_size=pool.pool_size,
        max_overflow=pool.max_overflow,
        future=True,
    )
