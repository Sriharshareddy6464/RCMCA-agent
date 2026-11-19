from __future__ import annotations

import os
from contextlib import asynccontextmanager
from pathlib import Path

import asyncpg
import httpx
from fastapi import FastAPI, HTTPException
from redis.asyncio import Redis

from rcmc_graph import IssueFacts, rcmc_app
from .migrations import apply_migrations
from .database import database_url
from .routes.issues import router as issues_router
from .routes.routing import router as routing_router
from .routes.vision import router as vision_router
from .routes.uploads import router as uploads_router
from .schemas import IssueAssessmentRequest


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.db = await asyncpg.create_pool(
        database_url(),
        min_size=1,
        max_size=int(os.getenv("DB_POOL_SIZE", "10")),
    )
    migration_dir = Path(__file__).resolve().parents[2] / "db" / "migrations"
    await apply_migrations(app.state.db, migration_dir)
    app.state.redis = Redis.from_url(
        os.getenv("REDIS_URL", "redis://localhost:6379/0"),
        decode_responses=True,
    )
    app.state.osrm = httpx.AsyncClient(
        base_url=os.getenv("OSRM_URL", "http://localhost:5000"),
        timeout=httpx.Timeout(20.0),
    )
    try:
        yield
    finally:
        await app.state.osrm.aclose()
        await app.state.redis.aclose()
        await app.state.db.close()


app = FastAPI(
    title="RCMCA Road Condition API",
    description="Report, verify, and route around road hazards in Hyderabad.",
    version="0.2.0",
    lifespan=lifespan,
)
app.include_router(issues_router)
app.include_router(routing_router)
app.include_router(vision_router)
app.include_router(uploads_router)


@app.get("/health")
async def health():
    try:
        async with app.state.db.acquire() as connection:
            await connection.fetchval("SELECT 1")
        await app.state.redis.ping()
    except Exception as exc:
        raise HTTPException(status_code=503, detail="A required service is unavailable") from exc
    return {"status": "ok"}


@app.post("/api/v1/issues/assess")
def assess_issue(request: IssueAssessmentRequest):
    try:
        result = rcmc_app.invoke(request.model_dump())
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail="Issue assessment is unavailable. Check the configured chat model.",
        ) from exc
    return {
        "issue": IssueFacts.model_validate(result["facts"]),
        "priority_score": result["priority_score"],
        "dispatch_tier": result["dispatch_tier"],
        "action_required": result["action_required"],
        "complaint_subject": result["complaint_subject"],
        "complaint_draft": result["complaint_draft"],
    }
