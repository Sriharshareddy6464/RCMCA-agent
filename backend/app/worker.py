from __future__ import annotations

import asyncio
import csv
import io
import logging
import os
from pathlib import Path
from typing import Any

import asyncpg
import httpx
from pydantic import BaseModel, Field, ValidationError, model_validator

from .migrations import apply_migrations
from .schemas import HazardCategory
from .services.geocoding import geocode_locality
from .database import database_url

logging.basicConfig(level=os.getenv("LOG_LEVEL", "INFO"))
logger = logging.getLogger("rcmca.municipal_sync")

_RESOLVED_STATES = {"resolved", "closed", "completed", "fixed", "disposed"}


class MunicipalIssue(BaseModel):
    ticket_id: str = Field(min_length=1, max_length=100)
    category: HazardCategory
    severity: int = Field(default=3, ge=1, le=5)
    description: str = Field(min_length=8, max_length=2000)
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)
    locality: str | None = Field(default=None, min_length=2, max_length=200)
    status: str = "open"

    @model_validator(mode="after")
    def require_location(self):
        coordinates = self.latitude is not None and self.longitude is not None
        if (self.latitude is None) != (self.longitude is None):
            raise ValueError("latitude and longitude must appear together")
        if not coordinates and not self.locality:
            raise ValueError("provide coordinates or a locality to geocode")
        return self


def _records(response: httpx.Response) -> list[dict[str, Any]]:
    content_type = response.headers.get("content-type", "").lower()
    if "html" in content_type:
        raise ValueError("feed returned an HTML portal page; configure a public export endpoint")
    if "json" in content_type:
        payload = response.json()
        if isinstance(payload, dict):
            payload = payload.get("records", [])
        if not isinstance(payload, list):
            raise ValueError("JSON export must contain a list or a 'records' list")
        return payload

    reader = csv.DictReader(io.StringIO(response.text))
    if not reader.fieldnames:
        raise ValueError("CSV export is missing a header row")
    return list(reader)


async def _upsert(pool, geocoder: httpx.AsyncClient,
                  source: str, raw: dict[str, Any]) -> bool:
    normalized = dict(raw)
    category = str(normalized.get("category", "")).strip().casefold().replace(" ", "_")
    normalized["category"] = {
        "damaged_road": "damaged_surface",
        "surface_damage": "damaged_surface",
        "open_drain": "open_manhole",
        "manhole": "open_manhole",
        "divider_damage": "broken_divider",
    }.get(category, category)
    if normalized.get("severity") in (None, ""):
        normalized["severity"] = 3
    for coordinate in ("latitude", "longitude"):
        if normalized.get(coordinate) == "":
            normalized[coordinate] = None
    if not normalized.get("status"):
        normalized["status"] = "open"
    try:
        issue = MunicipalIssue.model_validate(normalized)
    except ValidationError:
        logger.warning("Skipping one invalid record from source=%s", source)
        return False

    latitude, longitude = issue.latitude, issue.longitude
    if latitude is None:
        location = await geocode_locality(pool, geocoder, issue.locality or "")
        if location is None:
            logger.info("Skipping an unlocated record from source=%s", source)
            return False
        latitude, longitude = location["latitude"], location["longitude"]

    source_status = issue.status.strip().casefold()
    status = "resolved" if source_status in _RESOLVED_STATES else (
        "verified_ghmc" if source == "ghmc_portal" else "community_pending"
    )
    confidence = 2.5 if source == "ghmc_portal" else 1.0
    query = """
        INSERT INTO road_issues (
            category, severity, confidence_score, description, location,
            source, external_ticket_id, status
        ) VALUES (
            $1::hazard_category, $2, $3, $4,
            ST_SetSRID(ST_MakePoint($5, $6), 4326), $7, $8, $9::hazard_status
        )
        ON CONFLICT (source, external_ticket_id)
            WHERE external_ticket_id IS NOT NULL
        DO UPDATE SET
            category = EXCLUDED.category,
            severity = EXCLUDED.severity,
            confidence_score = GREATEST(road_issues.confidence_score, EXCLUDED.confidence_score),
            description = EXCLUDED.description,
            location = EXCLUDED.location,
            status = EXCLUDED.status
        RETURNING id
    """
    async with pool.acquire() as connection:
        await connection.execute(
            query,
            issue.category,
            issue.severity,
            confidence,
            issue.description,
            longitude,
            latitude,
            source,
            issue.ticket_id,
            status,
        )
    return True


async def sync_source(pool, client: httpx.AsyncClient, geocoder: httpx.AsyncClient,
                      source: str, feed_url: str) -> None:
    response = await client.get(feed_url)
    response.raise_for_status()
    records = _records(response)
    stored = 0
    for record in records:
        if await _upsert(pool, geocoder, source, record):
            stored += 1
    logger.info("Source sync complete source=%s fetched=%d stored=%d", source, len(records), stored)


async def run_forever() -> None:
    pool = await asyncpg.create_pool(database_url(), min_size=1, max_size=3)
    migration_dir = Path(__file__).resolve().parents[2] / "db" / "migrations"
    await apply_migrations(pool, migration_dir)
    timeout = httpx.Timeout(30.0)
    async with (
        httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client,
        httpx.AsyncClient(
            base_url=os.getenv("GEOCODER_BASE_URL", "https://nominatim.openstreetmap.org"),
            headers={"User-Agent": os.getenv("GEOCODER_USER_AGENT", "RCMCA-road-condition-monitor/0.2")},
            timeout=timeout,
        ) as geocoder,
    ):
        sources = {
            "ghmc_portal": os.getenv("GHMC_FEED_URL"),
            "prajavani": os.getenv("PRAJAVANI_FEED_URL"),
        }
        interval = int(os.getenv("MUNICIPAL_SYNC_INTERVAL_SECONDS", "1800"))
        logger.info("Municipal sync worker started interval_seconds=%d", interval)
        try:
            while True:
                for source, feed_url in sources.items():
                    if not feed_url:
                        continue
                    try:
                        await sync_source(pool, client, geocoder, source, feed_url)
                    except (httpx.HTTPError, ValueError) as exc:
                        logger.error("Source sync failed source=%s error=%s", source, type(exc).__name__)
                    except Exception as exc:
                        logger.error("Source sync failed source=%s error=%s", source, type(exc).__name__)
                await asyncio.sleep(interval)
        finally:
            await pool.close()


if __name__ == "__main__":
    asyncio.run(run_forever())
