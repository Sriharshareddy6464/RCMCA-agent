from __future__ import annotations

import httpx
from fastapi import APIRouter, HTTPException, Request

from ..db import find_route_hazards
from ..schemas import RouteHazard, RoutePlanRequest, RoutePlanResponse

router = APIRouter(prefix="/api/v1/routes", tags=["routes"])


@router.post("/plan", response_model=RoutePlanResponse)
async def plan_route(payload: RoutePlanRequest, request: Request):
    origin = payload.origin
    destination = payload.destination
    coordinates = (
        f"{origin.longitude:.7f},{origin.latitude:.7f};"
        f"{destination.longitude:.7f},{destination.latitude:.7f}"
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

    scored: list[tuple[dict, list[dict], bool]] = []
    try:
        for candidate in candidates:
            hazards = await find_route_hazards(
                request.app.state.db, candidate["geometry"]
            )
            has_severe = any(hazard["severity"] >= 4 for hazard in hazards)
            scored.append((candidate, hazards, has_severe))
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Hazard database is unavailable") from exc

    safe_routes = [item for item in scored if not item[2]]
    if safe_routes:
        chosen, hazards, _ = min(safe_routes, key=lambda item: item[0]["duration"])
        avoided_severe = any(item[2] for item in scored)
    else:
        # No clear OSRM alternative: return the least costly hazardous option with warnings.
        chosen, hazards, _ = min(
            scored,
            key=lambda item: item[0]["duration"] + 300 * sum(
                hazard["severity"] >= 4 for hazard in item[1]
            ),
        )
        avoided_severe = False

    return RoutePlanResponse(
        geometry=chosen["geometry"],
        distance_m=chosen["distance"],
        duration_s=chosen["duration"],
        avoided_severe_hazards=avoided_severe,
        alternatives_considered=len(candidates),
        hazards=[RouteHazard(**hazard) for hazard in hazards],
    )
