from __future__ import annotations

import asyncio
import json
import logging
import os
from pathlib import Path

import anyio
import asyncpg

from .migrations import apply_migrations
from .database import database_url
from .services.vision import assess_image

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("rcmca.vision_worker")


async def _requeue_stale(pool) -> None:
    async with pool.acquire() as connection:
        count = await connection.execute(
            """
            UPDATE vision_assessments
            SET status = 'pending', updated_at = NOW()
            WHERE status = 'processing'
              AND image_data IS NOT NULL
              AND updated_at < NOW() - INTERVAL '10 minutes'
            """
        )
    if count != "UPDATE 0":
        logger.warning("Requeued stale vision jobs count=%s", count)


async def _claim_one(pool):
    async with pool.acquire() as connection:
        async with connection.transaction():
            row = await connection.fetchrow(
                """
                SELECT id, issue_id, image_data
                FROM vision_assessments
                WHERE status = 'pending' AND image_data IS NOT NULL
                ORDER BY created_at
                FOR UPDATE SKIP LOCKED
                LIMIT 1
                """
            )
            if row is None:
                return None
            await connection.execute(
                """
                UPDATE vision_assessments
                SET status = 'processing', updated_at = NOW()
                WHERE id = $1
                """,
                row["id"],
            )
            return dict(row)


async def _complete(pool, job: dict, result: dict) -> None:
    assessment_data = json.dumps({
        "detections": result["detections"],
        "image_width": result["image_width"],
        "image_height": result["image_height"],
        "severity_method": result["severity_method"],
    })
    async with pool.acquire() as connection:
        async with connection.transaction():
            await connection.execute(
                """
                UPDATE vision_assessments
                SET status = 'complete', model_name = $2,
                    severity_estimate = $3, detections = $4::jsonb,
                    image_data = NULL, error = NULL, updated_at = NOW()
                WHERE id = $1
                """,
                job["id"],
                result["model"],
                result["severity_estimate"],
                assessment_data,
            )
            if result["severity_estimate"] is not None:
                await connection.execute(
                    "UPDATE road_issues SET severity = GREATEST(severity, $2) WHERE id = $1",
                    job["issue_id"],
                    result["severity_estimate"],
                )


async def _fail(pool, job: dict, exc: Exception) -> None:
    async with pool.acquire() as connection:
        await connection.execute(
            """
            UPDATE vision_assessments
            SET status = 'failed', image_data = NULL,
                error = $2, updated_at = NOW()
            WHERE id = $1
            """,
            job["id"],
            str(exc)[:500],
        )


async def run_forever() -> None:
    pool = await asyncpg.create_pool(database_url(), min_size=1, max_size=4)
    migration_dir = Path(__file__).resolve().parents[2] / "db" / "migrations"
    await apply_migrations(pool, migration_dir)
    poll_interval = float(os.getenv("VISION_WORKER_POLL_SECONDS", "0.5"))
    stale_interval = float(os.getenv("VISION_WORKER_RECLAIM_SECONDS", "60"))
    last_reclaim = 0.0
    logger.info("Vision inference worker started poll_seconds=%s", poll_interval)
    try:
        while True:
            now = asyncio.get_running_loop().time()
            if now - last_reclaim >= stale_interval:
                await _requeue_stale(pool)
                last_reclaim = now
            job = await _claim_one(pool)
            if job is None:
                await asyncio.sleep(poll_interval)
                continue
            try:
                result = await anyio.to_thread.run_sync(assess_image, job["image_data"])
                await _complete(pool, job, result)
                logger.info(
                    "Vision assessment complete id=%s detections=%d severity=%s",
                    job["id"], len(result["detections"]), result["severity_estimate"],
                )
            except Exception as exc:
                await _fail(pool, job, exc)
                logger.exception("Vision assessment failed id=%s", job["id"])
    finally:
        await pool.close()


if __name__ == "__main__":
    asyncio.run(run_forever())
