from __future__ import annotations

import json
from uuid import UUID

from fastapi import APIRouter, HTTPException, Request
from redis.exceptions import RedisError

from ..db import ISSUE_FIELDS, issue_dict
from ..schemas import (
    IssueReportRequest,
    IssueReportResponse,
    IssueResponse,
    IssueViewportRequest,
    VerifyIssueByIdRequest,
    VerifyIssueRequest,
    VerifyIssueResponse,
)

router = APIRouter(prefix="/api/v1/issues", tags=["issues"])


@router.get("", response_model=list[IssueResponse])
async def list_issues(request: Request, south: float, west: float, north: float, east: float, limit: int = 500):
    """Return active hazards in a map viewport, capped to keep mobile responses bounded."""
    bounds = IssueViewportRequest(south=south, west=west, north=north, east=east, limit=limit)
    async with request.app.state.db.acquire() as connection:
        records = await connection.fetch(
            f"""
            SELECT {ISSUE_FIELDS} FROM road_issues
            WHERE status <> 'resolved'
              AND location && ST_MakeEnvelope($1, $2, $3, $4, 4326)
            ORDER BY severity DESC, updated_at DESC
            LIMIT $5
            """,
            bounds.west, bounds.south, bounds.east, bounds.north, bounds.limit,
        )
    return [issue_dict(row) for row in records]


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
    async with pool.acquire() as connection:
        async with connection.transaction():
            # Serialize initial reports so nearby concurrent requests cannot both insert.
            await connection.execute("SELECT pg_advisory_xact_lock(731904221)")
            duplicate = await connection.fetchrow(
                f"""
                SELECT {ISSUE_FIELDS},
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
                row = await connection.fetchrow(
                    f"""
                    UPDATE road_issues
                    SET report_count = report_count + 1,
                        severity = GREATEST(severity, $2),
                        evidence_image_url = COALESCE(evidence_image_url, $3)
                    WHERE id = $1
                    RETURNING {ISSUE_FIELDS}
                    """,
                    duplicate["id"],
                    payload.severity,
                    payload.evidence_image_url,
                )
                deduplicated = True
            else:
                row = await connection.fetchrow(
                    f"""
                    INSERT INTO road_issues (
                        category, severity, description, evidence_image_url,
                        location, source, status
                    ) VALUES (
                        $1::hazard_category, $2, $3, $4,
                        ST_SetSRID(ST_MakePoint($5, $6), 4326),
                        'user_report', 'community_pending'
                    )
                    RETURNING {ISSUE_FIELDS}
                    """,
                    payload.category,
                    payload.severity,
                    payload.description,
                    payload.evidence_image_url,
                    payload.longitude,
                    payload.latitude,
                )
                deduplicated = False

            if payload.evidence_image_url:
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
                    row["id"], payload.evidence_image_url,
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

    issue = issue_dict(row)
    issue["evidence"] = evidence
    return IssueReportResponse(issue=issue, deduplicated=deduplicated)


@router.get("/{issue_id}", response_model=IssueResponse)
async def get_issue(issue_id: UUID, request: Request):
    async with request.app.state.db.acquire() as connection:
        row = await connection.fetchrow(
            f"SELECT {ISSUE_FIELDS} FROM road_issues WHERE id = $1", issue_id
        )
        evidence = await _evidence_for_issue(connection, issue_id) if row else []
    if row is None:
        raise HTTPException(status_code=404, detail="Road issue not found")
    issue = issue_dict(row)
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
                INSERT INTO verification_votes (issue_id, user_id, vote_type)
                VALUES ($1, $2, $3::verification_vote_type)
                ON CONFLICT (issue_id, user_id)
                DO UPDATE SET vote_type = EXCLUDED.vote_type, created_at = NOW()
                """,
                issue_id,
                payload.user_id,
                payload.vote_type,
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
            updated = await connection.fetchrow(
                """
                UPDATE road_issues
                SET confidence_score = $2,
                    status = CASE
                        WHEN $2::double precision <= 0.0 THEN 'resolved'::hazard_status
                        WHEN source = 'ghmc_portal' THEN 'verified_ghmc'::hazard_status
                        WHEN $2::double precision > 1.0 THEN 'active_hazard'::hazard_status
                        ELSE status
                    END
                WHERE id = $1
                RETURNING confidence_score, status::text AS status
                """,
                issue_id,
                confidence,
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
    )


@router.post("/verify", response_model=VerifyIssueResponse)
async def verify_issue_by_id(payload: VerifyIssueByIdRequest, request: Request):
    return await _record_vote(payload.issue_id, payload, request)


@router.post("/{issue_id}/verify", response_model=VerifyIssueResponse)
async def verify_issue(issue_id: UUID, payload: VerifyIssueRequest, request: Request):
    return await _record_vote(issue_id, payload, request)
