from __future__ import annotations

import json
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from redis.exceptions import RedisError

from ..db import ISSUE_FIELDS, issue_dict
from ..migrations import ensure_hyd_demo_issues
from ..schemas import (
    IssueReportRequest,
    IssueReportResponse,
    IssueResponse,
    IssueViewportRequest,
    VerifyIssueByIdRequest,
    VerifyIssueRequest,
    VerifyIssueResponse,
)
from ..scrape_hyd_civic import scrape_feeds

router = APIRouter(prefix="/api/v1/issues", tags=["issues"])

ISSUE_FIELDS_X = (
    ISSUE_FIELDS.rstrip()
    + ", corporation, zone, ward_no, ward_name, authority_designation,"
    " authority_email, status_color, impact_mcq, image_urls"
)
MAX_IMAGES_PER_ISSUE = 12
_WARD_COLUMNS = (
    "ward_no, corporation, zone, ward_name, authority_designation, authority_email"
)


def _issue_out(row) -> dict:
    issue = issue_dict(row)
    urls = issue.get("image_urls")
    if isinstance(urls, str):  # jsonb arrives as text unless a codec is registered
        urls = json.loads(urls)
    issue["image_urls"] = urls or []
    return issue


async def _ward_for_point(connection, longitude: float, latitude: float):
    """Ward containing the point; falls back to the nearest ward outside all polygons."""
    point = "ST_SetSRID(ST_MakePoint($1, $2), 4326)"
    ward = await connection.fetchrow(
        f"SELECT {_WARD_COLUMNS} FROM hyd_wards WHERE ST_Contains(geom, {point}) "
        "ORDER BY ST_Area(geom) ASC LIMIT 1",
        longitude, latitude,
    )
    if ward is None:
        ward = await connection.fetchrow(
            f"SELECT {_WARD_COLUMNS} FROM hyd_wards ORDER BY geom <-> {point} LIMIT 1",
            longitude, latitude,
        )
    return ward


@router.get("", response_model=list[IssueResponse])
async def list_issues(request: Request, south: float, west: float, north: float, east: float, limit: int = 500):
    """Return active hazards in a map viewport, capped to keep mobile responses bounded."""
    bounds = IssueViewportRequest(south=south, west=west, north=north, east=east, limit=limit)
    async with request.app.state.db.acquire() as connection:
        records = await connection.fetch(
            f"""
            SELECT {ISSUE_FIELDS_X} FROM road_issues
            WHERE status <> 'resolved'
              AND location && ST_MakeEnvelope($1, $2, $3, $4, 4326)
            ORDER BY severity DESC, updated_at DESC
            LIMIT $5
            """,
            bounds.west, bounds.south, bounds.east, bounds.north, bounds.limit,
        )
    return [_issue_out(row) for row in records]


@router.post("/refresh")
async def refresh_issues(request: Request):
    """Refresh public civic news and ensure the Hyderabad demo issue set exists."""
    pool = request.app.state.db
    # Seed first so a public feed outage never prevents the map from having a
    # complete local issue set. This is idempotent and also runs at startup.
    async with pool.acquire() as connection:
        await ensure_hyd_demo_issues(connection)

    imported = await scrape_feeds(pool)
    async with pool.acquire() as connection:
        total_issues = await connection.fetchval("SELECT COUNT(*) FROM road_issues")
    return {"imported": imported, "total_issues": int(total_issues or 0)}


async def _evidence_for_issue(connection, issue_id: UUID) -> list[dict]:
    rows = await connection.fetch(
        """
        SELECT id, image_url, ST_Y(location::geometry) AS latitude,
               ST_X(location::geometry) AS longitude, accuracy_m,
               heading_degrees, captured_at, created_at
        FROM issue_evidence WHERE issue_id = $1 ORDER BY created_at ASC
        """,
        issue_id,
    )
    return [dict(row) for row in rows]


@router.post("/report", response_model=IssueReportResponse, status_code=201)
async def report_issue(payload: IssueReportRequest, request: Request):
    pool = request.app.state.db
    new_urls = list(dict.fromkeys(
        u for u in [payload.evidence_image_url, *payload.image_urls] if u
    ))
    async with pool.acquire() as connection:
        async with connection.transaction():
            # Serialize initial reports so nearby concurrent requests cannot both insert.
            await connection.execute("SELECT pg_advisory_xact_lock(731904221)")
            duplicate = await connection.fetchrow(
                f"""
                SELECT {ISSUE_FIELDS_X},
                       ST_Distance(location::geography,
                           ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography)
                           AS distance_m
                FROM road_issues
                WHERE category = $1::hazard_category
                  AND status <> 'resolved'
                  AND ST_DWithin(
                      location::geography,
                      ST_SetSRID(ST_MakePoint($2, $3), 4326)::geography,
                      25
                  )
                ORDER BY distance_m ASC
                LIMIT 1
                FOR UPDATE
                """,
                payload.category,
                payload.longitude,
                payload.latitude,
            )

            if duplicate:
                existing = _issue_out(duplicate)["image_urls"]
                merged = list(dict.fromkeys([*existing, *new_urls]))[:MAX_IMAGES_PER_ISSUE]
                row = await connection.fetchrow(
                    f"""
                    UPDATE road_issues
                    SET report_count = report_count + 1,
                        severity = GREATEST(severity, $2),
                        evidence_image_url = COALESCE(evidence_image_url, $3),
                        impact_mcq = COALESCE($4, impact_mcq),
                        image_urls = $5::jsonb
                    WHERE id = $1
                    RETURNING {ISSUE_FIELDS_X}
                    """,
                    duplicate["id"],
                    payload.severity,
                    new_urls[0] if new_urls else None,
                    payload.impact_mcq,
                    json.dumps(merged),
                )
                deduplicated = True
            else:
                ward = await _ward_for_point(
                    connection, payload.longitude, payload.latitude
                )
                ward_values = (
                    tuple(
                        ward[key] for key in (
                            "corporation", "zone", "ward_no", "ward_name",
                            "authority_designation", "authority_email",
                        )
                    )
                    if ward else (None,) * 6
                )
                row = await connection.fetchrow(
                    f"""
                    INSERT INTO road_issues (
                        category, severity, description, evidence_image_url,
                        location, source, status, impact_mcq, image_urls,
                        corporation, zone, ward_no, ward_name,
                        authority_designation, authority_email
                    ) VALUES (
                        $1::hazard_category, $2, $3, $4,
                        ST_SetSRID(ST_MakePoint($5, $6), 4326),
                        'user_report', 'community_pending', $7, $8::jsonb,
                        $9, $10, $11, $12, $13, $14
                    )
                    RETURNING {ISSUE_FIELDS_X}
                    """,
                    payload.category,
                    payload.severity,
                    payload.description,
                    new_urls[0] if new_urls else None,
                    payload.longitude,
                    payload.latitude,
                    payload.impact_mcq,
                    json.dumps(new_urls),
                    *ward_values,
                )
                deduplicated = False

            for url in new_urls:
                await connection.execute(
                    """
                    INSERT INTO issue_evidence (
                        issue_id, image_url, location, accuracy_m,
                        heading_degrees, captured_at
                    ) VALUES (
                        $1, $2, ST_SetSRID(ST_MakePoint($3, $4), 4326),
                        $5, $6, COALESCE($7, NOW())
                    )
                    """,
                    row["id"], url,
                    payload.longitude, payload.latitude,
                    payload.capture_accuracy_m, payload.capture_heading_degrees,
                    payload.captured_at,
                )
            evidence = await _evidence_for_issue(connection, row["id"])

    event = {"event": "issue_reported", "issue_id": str(row["id"])}
    try:
        await request.app.state.redis.publish("road_issues", json.dumps(event))
    except RedisError:
        # Redis is a live-update optimization; the database write is authoritative.
        pass

    issue = _issue_out(row)
    issue["evidence"] = evidence
    return IssueReportResponse(issue=issue, deduplicated=deduplicated)


@router.get("/{issue_id}", response_model=IssueResponse)
async def get_issue(issue_id: UUID, request: Request):
    async with request.app.state.db.acquire() as connection:
        row = await connection.fetchrow(
            f"SELECT {ISSUE_FIELDS_X} FROM road_issues WHERE id = $1", issue_id
        )
        evidence = await _evidence_for_issue(connection, issue_id) if row else []
    if row is None:
        raise HTTPException(status_code=404, detail="Road issue not found")
    issue = _issue_out(row)
    issue["evidence"] = evidence
    return issue


async def _record_vote(issue_id: UUID, payload: VerifyIssueRequest, request: Request):
    async with request.app.state.db.acquire() as connection:
        async with connection.transaction():
            issue = await connection.fetchrow(
                """
                SELECT id, source, status::text AS status
                FROM road_issues WHERE id = $1 FOR UPDATE
                """,
                issue_id,
            )
            if issue is None:
                raise HTTPException(status_code=404, detail="Road issue not found")

            await connection.execute(
                """
                INSERT INTO verification_votes (
                    issue_id, user_id, vote_type, still_present,
                    condition_score, impact_mcq
                ) VALUES ($1, $2, $3::verification_vote_type, $4, $5, $6)
                ON CONFLICT (issue_id, user_id)
                DO UPDATE SET vote_type = EXCLUDED.vote_type,
                              still_present = EXCLUDED.still_present,
                              condition_score = EXCLUDED.condition_score,
                              impact_mcq = EXCLUDED.impact_mcq,
                              created_at = NOW()
                """,
                issue_id,
                payload.user_id,
                payload.vote_type,
                payload.still_present,
                payload.condition_score,
                payload.impact_mcq,
            )

            base_confidence = 2.5 if issue["source"] == "ghmc_portal" else 1.0
            vote_delta = await connection.fetchval(
                """
                SELECT COALESCE(SUM(
                    CASE vote_type
                        WHEN 'CONFIRM' THEN 0.5
                        WHEN 'RESOLVED' THEN -0.75
                    END
                ), 0)::double precision
                FROM verification_votes WHERE issue_id = $1
                """,
                issue_id,
            )
            confidence = base_confidence + vote_delta
            # Severity follows the crowd: mean condition score of surveyors who
            # still see the hazard (unchanged until someone supplies a score).
            avg_score = await connection.fetchval(
                """
                SELECT AVG(condition_score)::double precision FROM verification_votes
                WHERE issue_id = $1 AND still_present IS TRUE
                  AND condition_score IS NOT NULL
                """,
                issue_id,
            )
            crowd_severity = (
                max(1, min(5, int(avg_score + 0.5))) if avg_score is not None else None
            )
            updated = await connection.fetchrow(
                """
                UPDATE road_issues
                SET confidence_score = $2,
                    severity = COALESCE($3::smallint, severity),
                    impact_mcq = COALESCE($4::text, impact_mcq),
                    status = CASE
                        WHEN $2::double precision <= 0.0 THEN 'resolved'::hazard_status
                        WHEN source = 'ghmc_portal' THEN 'verified_ghmc'::hazard_status
                        WHEN $2::double precision > 1.0 THEN 'active_hazard'::hazard_status
                        ELSE status
                    END
                WHERE id = $1
                RETURNING confidence_score, severity, status_color,
                          status::text AS status
                """,
                issue_id,
                confidence,
                crowd_severity,
                payload.impact_mcq if payload.still_present else None,
            )

    try:
        await request.app.state.redis.publish(
            "road_issues",
            json.dumps(
                {"event": "issue_verified", "issue_id": str(issue_id), "status": updated["status"]}
            ),
        )
    except RedisError:
        pass

    return VerifyIssueResponse(
        issue_id=issue_id,
        confidence_score=updated["confidence_score"],
        status=updated["status"],
        still_present=payload.still_present,
        condition_score=payload.condition_score,
        impact_mcq=payload.impact_mcq,
        severity=updated["severity"],
        status_color=updated["status_color"],
    )


@router.post("/verify", response_model=VerifyIssueResponse)
async def verify_issue_by_id(payload: VerifyIssueByIdRequest, request: Request):
    return await _record_vote(payload.issue_id, payload, request)


@router.post("/{issue_id}/verify", response_model=VerifyIssueResponse)
async def verify_issue(issue_id: UUID, payload: VerifyIssueRequest, request: Request):
    return await _record_vote(issue_id, payload, request)
