from __future__ import annotations

import re
from typing import Any
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from pydantic import BaseModel, Field, model_validator

from rcmc_graph import ChatIntent, build_chat_graph
from ..services.geocoding import find_hyderabad_locality

router = APIRouter(tags=["chat"])


class ChatRequest(BaseModel):
    message: str = Field(min_length=1, max_length=4000)
    user_lat: float | None = Field(default=None, ge=-90, le=90)
    user_lon: float | None = Field(default=None, ge=-180, le=180)

    @model_validator(mode="after")
    def location_is_complete(self):
        if (self.user_lat is None) != (self.user_lon is None):
            raise ValueError("user_lat and user_lon must be supplied together")
        return self


def _route_origin(intent: ChatIntent, state: dict[str, Any]):
    origin = intent.origin
    if origin is None or origin.casefold().strip() in {
        "current location", "my location", "here", "my current location", "me"
    }:
        if state.get("user_lat") is None or state.get("user_lon") is None:
            raise HTTPException(
                status_code=422,
                detail="Share your location or name a route origin.",
            )
        return [state["user_lon"], state["user_lat"]]
    return origin


async def _audit_from_chat(intent: ChatIntent, state: dict[str, Any], request: Request):
    # Imported lazily so the routing module can mount this router without a
    # circular module import during FastAPI application startup.
    from .routing import audit_routes

    if not intent.destination:
        raise HTTPException(status_code=422, detail="Name a destination for route planning.")
    return await audit_routes(_route_origin(intent, state), intent.destination, request)


def _issue_search_terms(value: str) -> str:
    stopwords = {
        "a", "an", "any", "are", "is", "road", "issue", "issues", "reported",
        "problem", "problems", "near", "at", "the", "on", "in", "my", "there",
        "please", "find", "show", "me", "about", "of", "for", "to", "by",
    }
    plurals = {
        "potholes": "pothole", "manholes": "manhole", "cracks": "crack",
        "issues": "issue", "problems": "problem", "drains": "drain",
    }
    words = re.findall(r"\w+", value.casefold())
    normalized = [plurals.get(word, word) for word in words]
    return " ".join(word for word in normalized if len(word) >= 3 and word not in stopwords)


async def _resolve_issue(intent: ChatIntent, state: dict[str, Any], request: Request):
    pool = request.app.state.db
    issue_id = intent.issue_id
    if issue_id is None:
        match = re.search(
            r"\b[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\b",
            state["message"],
        )
        issue_id = match.group(0) if match else None

    fields = """
        id::text AS id, category::text AS category, severity,
        description, status::text AS status, status_color, impact_mcq,
        corporation, zone, ward_no, ward_name,
        authority_designation, authority_email,
        ST_Y(location::geometry) AS latitude,
        ST_X(location::geometry) AS longitude,
        created_at, updated_at
    """
    async with pool.acquire() as connection:
        row = None
        if issue_id:
            try:
                row = await connection.fetchrow(
                    f"SELECT {fields} FROM road_issues WHERE id = $1", UUID(issue_id)
                )
            except ValueError as exc:
                raise HTTPException(status_code=422, detail="The issue ID is not a valid UUID") from exc
        else:
            full_query = " ".join(part for part in (intent.issue_query, state["message"]) if part)
            query_text = _issue_search_terms(full_query)
            locality = find_hyderabad_locality(full_query)
            category = next(
                (name for name in (
                    "pothole", "waterlogging", "damaged_surface", "open_manhole",
                    "broken_divider", "other",
                ) if name.replace("_", " ") in query_text),
                None,
            )
            if locality:
                row = await connection.fetchrow(
                    f"""
                    SELECT {fields},
                           ST_Distance(
                               location::geography,
                               ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
                           ) AS distance_m
                    FROM road_issues
                    WHERE status <> 'resolved'
                      AND ($3::text IS NULL OR category::text = $3)
                      AND ST_DWithin(
                          location::geography,
                          ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
                          3000
                      )
                    ORDER BY distance_m ASC, severity DESC, updated_at DESC
                    LIMIT 1
                    """,
                    locality["longitude"], locality["latitude"], category,
                )
            if query_text:
                ts_query = " | ".join(f"{word}:*" for word in query_text.split())
                row = row or await connection.fetchrow(
                    f"""
                    SELECT {fields},
                           ts_rank(
                               to_tsvector('simple', concat_ws(' ', category::text, description, ward_name, corporation)),
                               to_tsquery('simple', $1)
                           ) AS match_rank
                    FROM road_issues
                    WHERE to_tsvector(
                              'simple', concat_ws(' ', category::text, description, ward_name, corporation)
                          ) @@ to_tsquery('simple', $1)
                    ORDER BY match_rank DESC,
                             (status <> 'resolved') DESC,
                             updated_at DESC
                    LIMIT 1
                    """,
                    ts_query,
                )
            if row is None and state.get("user_lat") is not None:
                row = await connection.fetchrow(
                    f"""
                    SELECT {fields},
                           ST_Distance(
                               location::geography,
                               ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography
                           ) AS distance_m
                    FROM road_issues
                    WHERE status <> 'resolved'
                      AND ST_DWithin(
                          location::geography,
                          ST_SetSRID(ST_MakePoint($1, $2), 4326)::geography,
                          3000
                      )
                    ORDER BY distance_m ASC
                    LIMIT 1
                    """,
                    state["user_lon"], state["user_lat"],
                )

    if row is None:
        raise HTTPException(
            status_code=404,
            detail="No matching road issue was found. Include an issue UUID, category, or locality.",
        )
    issue = dict(row)
    issue.pop("match_rank", None)
    issue.pop("distance_m", None)
    return issue


def _route_auditor_for(request: Request):
    async def run(intent: ChatIntent, state: dict[str, Any]):
        return await _audit_from_chat(intent, state, request)

    return run


def _issue_resolver_for(request: Request):
    async def run(intent: ChatIntent, state: dict[str, Any]):
        return await _resolve_issue(intent, state, request)

    return run


def _route_explanation(audit: dict[str, Any]) -> str:
    origin = audit["origin"].get("display_name", "the requested origin")
    destination = audit["destination"].get("display_name", "the requested destination")
    routes = audit["routes"]
    using_fallback = audit.get("routing_source") == "fallback_geometry"
    lines = [
        f"1. Route endpoints: {origin} to {destination}.",
        (
            f"2. OSRM evaluated {len(routes)} driving plan(s)."
            if not using_fallback
            else f"2. The routing engine was unavailable; I generated {len(routes)} approximate corridor option(s)."
        ),
        "3. I checked each plan's 40 m corridor against active PostGIS road issues:",
    ]
    for route in routes:
        issues = route["issues_on_route"]
        if not issues:
            detail = "no active issues found"
        else:
            detail = "; ".join(
                f"{issue['title']} (issue {issue['id']}; {issue['status_color']}; "
                f"ward {issue['ward_name'] or 'unknown'}; "
                f"{issue['corporation'] or 'corporation unknown'})"
                for issue in issues
            )
        mark = "recommended" if route["is_recommended"] else "alternative"
        lines.append(f"   - {route['route_id']} ({mark}): {len(issues)} issue(s): {detail}.")
    recommended = next(route for route in routes if route["is_recommended"])
    dangerous = [
        issue
        for issue in recommended["issues_on_route"]
        if issue["status_color"] in {"ORANGE", "RED"}
    ]
    if dangerous:
        rationale = (
            f"it has the fewest ORANGE/RED issues ({len(dangerous)}) among the available plans"
        )
    else:
        rationale = "it avoids all ORANGE/RED issues and is the cleanest available plan"
    lines.append(
        f"4. Recommended {recommended['route_id']} ({recommended['distance_km']:.1f} km, "
        f"{recommended['duration_min']:.0f} min) because {rationale}."
    )
    return "\n".join(lines)


@router.post("/api/v1/chat")
async def chat(payload: ChatRequest, request: Request):
    state = payload.model_dump()
    try:
        graph = build_chat_graph(
            _route_auditor_for(request), _issue_resolver_for(request)
        )
        result = await graph.ainvoke(state)
    except HTTPException:
        raise
    except Exception as exc:
        raise HTTPException(
            status_code=503,
            detail="Chat processing is unavailable. Check the configured chat model.",
        ) from exc

    intent: ChatIntent = result["intent"]
    if intent.action == "route":
        audit = result["route_audit"]
        recommended = next(route for route in audit["routes"] if route["is_recommended"])
        return {
            "intent": "route",
            "message": _route_explanation(audit),
            "plans_evaluated": audit["alternatives_considered"],
            "routes": audit["routes"],
            "recommended_route_id": recommended["route_id"],
            "recommended_route_geojson": recommended["geometry"],
            "deep_link": f"rcmcs://navigate?route_id={recommended['route_id']}",
        }

    if intent.action == "issue":
        issue = result["issue"]
        draft = result["email_draft"]
        recipient = issue.get("authority_email") or ""
        return {
            "intent": "issue",
            "message": (
                f"Issue {issue['id']}: {issue['status_color']} {issue['category']} in "
                f"{issue.get('ward_name') or 'an unassigned ward'}, "
                f"{issue.get('corporation') or 'municipality unknown'}."
            ),
            "issue": issue,
            "draft_email": {
                "to": recipient,
                "subject": draft.subject,
                "body": draft.body,
            },
        }

    return {"intent": "other", "message": result["answer"]}
