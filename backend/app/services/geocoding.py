from __future__ import annotations

import asyncio
import time
import unicodedata
import httpx

_request_lock = asyncio.Lock()
_last_request_at = 0.0
_minimum_interval_seconds = 15.1  # 4 requests/minute for recurring worker use.


def _query_key(locality: str) -> str:
    normalized = " ".join(unicodedata.normalize("NFKC", locality).casefold().split())
    return normalized


async def geocode_locality(pool, client: httpx.AsyncClient, locality: str) -> dict | None:
    """Resolve a locality with cached, single-threaded Nominatim requests."""
    global _last_request_at

    query = " ".join(locality.split())
    key = _query_key(query)
    if not key:
        return None

    async with pool.acquire() as connection:
        cached = await connection.fetchrow(
            """
            SELECT latitude, longitude, display_name
            FROM geocode_cache WHERE query_key = $1
            """,
            key,
        )
    if cached:
        return dict(cached)

    async with _request_lock:
        # Check again after acquiring the lock in case another request filled the cache.
        async with pool.acquire() as connection:
            cached = await connection.fetchrow(
                """
                SELECT latitude, longitude, display_name
                FROM geocode_cache WHERE query_key = $1
                """,
                key,
            )
        if cached:
            return dict(cached)

        wait_seconds = _minimum_interval_seconds - (time.monotonic() - _last_request_at)
        if wait_seconds > 0:
            await asyncio.sleep(wait_seconds)

        response = await client.get(
            "/search",
            params={"q": f"{query}, Hyderabad, Telangana, India", "format": "jsonv2", "limit": 1},
        )
        _last_request_at = time.monotonic()
        response.raise_for_status()
        results = response.json()
        if not results:
            return None
        result = results[0]
        geocoded = {
            "latitude": float(result["lat"]),
            "longitude": float(result["lon"]),
            "display_name": result.get("display_name", query),
        }
        async with pool.acquire() as connection:
            await connection.execute(
                """
                INSERT INTO geocode_cache (query_key, query_text, latitude, longitude, display_name)
                VALUES ($1, $2, $3, $4, $5)
                ON CONFLICT (query_key) DO NOTHING
                """,
                key,
                query,
                geocoded["latitude"],
                geocoded["longitude"],
                geocoded["display_name"],
            )
        return geocoded
