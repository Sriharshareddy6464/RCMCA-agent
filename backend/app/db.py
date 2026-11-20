from __future__ import annotations

from typing import Any

ISSUE_FIELDS = """
id, category::text AS category, severity, confidence_score, report_count,
description, evidence_image_url, ST_Y(location::geometry) AS latitude,
ST_X(location::geometry) AS longitude, source, source_url, external_ticket_id,
status::text AS status, created_at, updated_at
"""


def issue_dict(record: Any) -> dict[str, Any]:
    return dict(record)


async def find_route_hazards(pool, route_geojson: dict[str, Any]) -> list[dict[str, Any]]:
    import json

    query = """
        WITH route AS (
            SELECT ST_SetSRID(ST_GeomFromGeoJSON($1), 4326)::geography AS path
        )
        SELECT i.id, i.category::text AS category, i.severity,
               i.status::text AS status, i.description,
               ST_Distance(i.location::geography, route.path) AS distance_from_route_m,
               ST_Y(i.location::geometry) AS latitude,
               ST_X(i.location::geometry) AS longitude
        FROM road_issues AS i CROSS JOIN route
        WHERE i.status <> 'resolved'
          AND ST_DWithin(i.location::geography, route.path, 40)
        ORDER BY i.severity DESC, distance_from_route_m ASC
    """
    async with pool.acquire() as connection:
        records = await connection.fetch(query, json.dumps(route_geojson))
    return [dict(record) for record in records]
