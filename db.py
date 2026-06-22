import os
from sqlalchemy import create_engine, text


DATABASE_URL = os.getenv("DATABASE_URL")

if not DATABASE_URL:
    raise RuntimeError(
        "Falta configurar DATABASE_URL. "
        "Ejemplo: postgresql+psycopg2://usuario:password@localhost:5432/siarc"
    )

engine = create_engine(DATABASE_URL)


def fetch_one(query, params=None):
    with engine.connect() as conn:
        result = conn.execute(text(query), params or {})
        row = result.mappings().first()
        return dict(row) if row else None


def fetch_all(query, params=None):
    with engine.connect() as conn:
        result = conn.execute(text(query), params or {})
        return [dict(row) for row in result.mappings().all()]
