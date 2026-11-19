from __future__ import annotations

from pathlib import Path


async def apply_migrations(pool, migration_dir: Path) -> None:
    if not migration_dir.exists():
        return
    base_schema = migration_dir.parent / "init" / "001_schema.sql"
    async with pool.acquire() as connection:
        async with connection.transaction():
            await connection.execute("SELECT pg_advisory_xact_lock(731904222)")
            if base_schema.exists():
                await connection.execute(base_schema.read_text(encoding="utf-8"))
            await connection.execute(
                """
                CREATE TABLE IF NOT EXISTS schema_migrations (
                    name TEXT PRIMARY KEY,
                    applied_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
                )
                """
            )
            applied = {
                row["name"]
                for row in await connection.fetch("SELECT name FROM schema_migrations")
            }
            for migration in sorted(migration_dir.glob("*.sql")):
                if migration.name in applied:
                    continue
                await connection.execute(migration.read_text(encoding="utf-8"))
                await connection.execute(
                    "INSERT INTO schema_migrations (name) VALUES ($1)", migration.name
                )
