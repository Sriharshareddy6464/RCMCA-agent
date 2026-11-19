from __future__ import annotations

import asyncio
import os
import re
import unicodedata
from typing import Any

import httpx
from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field, model_validator

from ..services.geocoding import geocode_locality

# These local ward centers/labels are the ward gazetteer already seeded by the
# application. Landmark aliases map to the closest available local center; any
# unmatched place name is resolved through the cached geocoding service.
_LOCAL_PLACES: dict[str, tuple[str, str, float, float]] = {
    "khairatabad": ("Khairatabad", "GHMC", 17.4120, 78.4600),
    "banjara hills": ("Banjara Hills", "GHMC", 17.4126, 78.4482),
    "sanathnagar": ("Sanathnagar", "GHMC", 17.4560, 78.4440),
    "tarnaka": ("Tarnaka", "GHMC", 17.4270, 78.5320),
    "pathergatti": ("Pathergatti", "GHMC", 17.3600, 78.4740),
    "kondapur": ("Kondapur", "CMC", 17.4690, 78.3640),
    "gachibowli": ("Gachibowli", "CMC", 17.4400, 78.3480),
    "madhapur": ("Madhapur", "CMC", 17.4480, 78.3910),
    "kphb colony": ("KPHB Colony", "CMC", 17.4930, 78.3990),
    "jeedimetla": ("Jeedimetla", "CMC", 17.5110, 78.4400),
    "malkajgiri": ("Malkajgiri", "MMC", 17.4560, 78.5270),
    "ramanthapur": ("Ramanthapur", "MMC", 17.3990, 78.5410),
    "vanasthalipuram": ("Vanasthalipuram", "MMC", 17.3300, 78.5720),
    "kapra": ("Kapra", "MMC", 17.4780, 78.5640),
}
_LOCAL_ALIASES = {
    "charminar": "pathergatti",
    "ghmc": "khairatabad",
    "ghmc headquarters": "khairatabad",
    "greater hyderabad municipal corporation": "khairatabad",
    "hitech city": "madhapur",
    "hi tech city": "madhapur",
    "hitec city": "madhapur",
    "cyber towers": "madhapur",
    "cyberabad": "gachibowli",
    "cyberabad cmc": "gachibowli",
    "cyberabad municipal corporation": "gachibowli",
    "financial district": "gachibowli",
    "gachibowli stadium": "gachibowli",
    "kukatpally": "kphb colony",
    "uppal": "ramanthapur",
    "lb nagar": "vanasthalipuram",
    "malkajgiri mmc": "malkajgiri",
    "malkajgiri municipal corporation": "malkajgiri",
    "malkajgiri railway station": "malkajgiri",
    "ecil": "kapra",
}


def _place_key(value: str) -> str:
    normalized = unicodedata.normalize("NFKD", value).casefold()
    normalized = "".join(c for c in normalized if not unicodedata.combining(c))
    normalized = re.sub(r"[^\w\s]", " ", normalized)
    words = [w for w in normalized.split() if w not in {"hyderabad", "telangana", "india"}]
    return " ".join(words)


class RouteRequest(BaseModel):
    """Route endpoints accept [longitude, latitude], place names, or legacy objects."""

    origin: str | list[float] | dict[str, float]
    destination: str | list[float] | dict[str, float]

    @model_validator(mode="after")
    def validate_endpoints(self):
        for name in ("origin", "destination"):
            value = getattr(self, name)
            if isinstance(value, str):
                if not value.strip() or len(value) > 200:
                    raise ValueError(f"{name} must be a non-empty Hyderabad place name")
            elif isinstance(value, list):
                if len(value) != 2:
                    raise ValueError(f"{name} coordinates must be [longitude, latitude]")
                longitude, latitude = value
                if not -180 <= longitude <= 180 or not -90 <= latitude <= 90:
                    raise ValueError(f"{name} coordinates are outside valid longitude/latitude ranges")
            else:
                # Preserve the previous {latitude, longitude} request shape.
                if set(value) != {"latitude", "longitude"}:
                    raise ValueError(f"{name} must contain latitude and longitude")
                if not -180 <= value["longitude"] <= 180 or not -90 <= value["latitude"] <= 90:
                    raise ValueError(f"{name} coordinates are outside valid longitude/latitude ranges")
        return self


def _coerce_coordinate(value: list[float] | dict[str, float]) -> dict[str, float]:
    if isinstance(value, list):
        longitude, latitude = value
        return {"latitude": latitude, "longitude": longitude}
    return {"latitude": value["latitude"], "longitude": value["longitude"]}


async def resolve_route_place(value: str | list[float] | dict[str, float], request: Request) -> dict[str, Any]:
    """Resolve coordinate endpoints directly and Hyderabad places locally first."""
    if not isinstance(value, str):
        return _coerce_coordinate(value)

    query = value.strip()
    key = _place_key(query)
    key = _LOCAL_ALIASES.get(key, key)
    if key in _LOCAL_PLACES:
        label, corporation, latitude, longitude = _LOCAL_PLACES[key]
        return {
            "latitude": latitude,
            "longitude": longitude,
            "display_name": label,
            "corporation": corporation,
            "resolution": "local_landmark",
        }

    # The ward table is a local fallback for seeded ward names and avoids a
    # network lookup when the exact locality is already known to the database.
    try:
        async with request.app.state.db.acquire() as connection:
            ward = await connection.fetchrow(
                """
                SELECT ward_name, corporation,
                       ST_Y(ST_PointOnSurface(geom)) AS latitude,
                       ST_X(ST_PointOnSurface(geom)) AS longitude
                FROM hyd_wards
                WHERE lower(ward_name) = lower($1)
                ORDER BY ward_no
                LIMIT 1
                """,
                query,
            )
        if ward:
            return {**dict(ward), "display_name": ward["ward_name"], "resolution": "local_ward"}
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Local place index is unavailable") from exc

    try:
        geocoder_base = os.getenv("GEOCODER_BASE_URL", "https://nominatim.openstreetmap.org")
        headers = {
            "User-Agent": os.getenv(
                "GEOCODER_USER_AGENT", "RCMCA-road-condition-monitor/0.3"
            )
        }
        async with httpx.AsyncClient(
            base_url=geocoder_base, headers=headers, timeout=httpx.Timeout(12.0)
        ) as geocoder:
            place = await geocode_locality(request.app.state.db, geocoder, query)
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(status_code=503, detail="Place geocoding is unavailable") from exc
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Place geocoding is unavailable") from exc
    if place is None:
        raise HTTPException(status_code=422, detail=f"Could not find a Hyderabad place named '{query}'")

    latitude = float(place["latitude"])
    longitude = float(place["longitude"])
    # Keep this Hyderabad-only API from silently routing to a distant Nominatim match.
    if not 16.7 <= latitude <= 18.1 or not 77.7 <= longitude <= 79.1:
        raise HTTPException(status_code=422, detail=f"'{query}' did not resolve inside the Hyderabad region")
    return {**place, "resolution": "geocoder"}


async def _route_hazards(pool, geometry: dict[str, Any]) -> list[dict[str, Any]]:
    """Return active issues within a 40 m PostGIS corridor around a GeoJSON line."""
    import json

    query = """
        WITH route AS (
            SELECT ST_SetSRID(ST_GeomFromGeoJSON($1), 4326)::geography AS path
        )
        SELECT i.id::text AS id,
               COALESCE(NULLIF(LEFT(BTRIM(i.description), 180), ''), i.category::text) AS title,
               COALESCE(i.status_color, 'GREEN') AS status_color,
               i.ward_name,
               i.corporation,
               i.category::text AS category,
               i.severity,
               i.status::text AS status,
               ST_Y(i.location::geometry) AS latitude,
               ST_X(i.location::geometry) AS longitude,
               ST_AsGeoJSON(i.location::geometry)::json AS geometry,
               ST_Distance(i.location::geography, route.path) AS distance_from_route_m
        FROM road_issues AS i CROSS JOIN route
        WHERE i.status <> 'resolved'
          AND ST_DWithin(i.location::geography, route.path, 40)
        ORDER BY distance_from_route_m ASC, i.severity DESC, i.id
    """
    async with pool.acquire() as connection:
        rows = await connection.fetch(query, json.dumps(geometry))
    return [dict(row) for row in rows]


def _recommendation_key(route: dict[str, Any]) -> tuple:
    issues = route["issues_on_route"]
    red = sum(issue["status_color"] == "RED" for issue in issues)
    orange = sum(issue["status_color"] == "ORANGE" for issue in issues)
    critical = red + orange
    return (
        critical > 0,
        red,
        orange,
        len(issues),
        route["duration_min"],
        route["distance_km"],
    )


async def audit_routes(
    origin: str | list[float] | dict[str, float],
    destination: str | list[float] | dict[str, float],
    request: Request,
) -> dict[str, Any]:
    resolved_origin, resolved_destination = await asyncio.gather(
        resolve_route_place(origin, request), resolve_route_place(destination, request)
    )
    coordinates = (
        f"{resolved_origin['longitude']:.7f},{resolved_origin['latitude']:.7f};"
        f"{resolved_destination['longitude']:.7f},{resolved_destination['latitude']:.7f}"
    )
    try:
        response = await request.app.state.osrm.get(
            f"/route/v1/driving/{coordinates}",
            params={
                "alternatives": 3,
                "steps": "false",
                "geometries": "geojson",
                "overview": "full",
            },
        )
        response.raise_for_status()
        route_payload = response.json()
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(status_code=503, detail="Routing engine is unavailable") from exc

    candidates = route_payload.get("routes") or []
    if not candidates:
        raise HTTPException(status_code=422, detail="OSRM could not find a route")

    try:
        routes = []
        for index, candidate in enumerate(candidates, start=1):
            issues = await _route_hazards(
                request.app.state.db, candidate["geometry"]
            )
            routes.append(
                {
                    "route_id": f"route_{index}",
                    "label": f"Alternative {index}",
                    "is_recommended": False,
                    "distance_km": candidate["distance"] / 1000.0,
                    "duration_min": candidate["duration"] / 60.0,
                    "issues_on_route": issues,
                    "geometry": candidate["geometry"],
                }
            )
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Hazard database is unavailable") from exc

    recommended = min(routes, key=_recommendation_key)
    recommended["is_recommended"] = True
    recommended["label"] = "Safest available route"
    recommended_critical = any(
        issue["status_color"] in {"ORANGE", "RED"}
        for issue in recommended["issues_on_route"]
    )
    alternatives_avoided_critical = any(
        issue["status_color"] in {"ORANGE", "RED"}
        for route in routes
        if route is not recommended
        for issue in route["issues_on_route"]
    )
    return {
        "origin": resolved_origin,
        "destination": resolved_destination,
        "alternatives_considered": len(routes),
        "recommended_route_id": recommended["route_id"],
        "routes": routes,
        # Preserve the original route response fields consumed by existing clients.
        "geometry": recommended["geometry"],
        "distance_m": recommended["distance_km"] * 1000.0,
        "duration_s": recommended["duration_min"] * 60.0,
        "avoided_severe_hazards": alternatives_avoided_critical and not recommended_critical,
        "hazards": [
            {
                "id": issue["id"],
                "category": issue["category"],
                "severity": issue["severity"],
                "status": issue["status"],
                "description": issue["title"],
                "distance_from_route_m": issue["distance_from_route_m"],
                "latitude": issue["latitude"],
                "longitude": issue["longitude"],
            }
            for issue in recommended["issues_on_route"]
        ],
    }


router = APIRouter(tags=["routes"])


@router.post("/api/v1/routes/plan")
async def plan_route(payload: RouteRequest, request: Request):
    return await audit_routes(payload.origin, payload.destination, request)


# main.py already includes the routing router. Attach the chat router here so
# the requested /api/v1/chat endpoint is registered without changing main.py.
from .chat import router as chat_router  # noqa: E402

router.include_router(chat_router)
