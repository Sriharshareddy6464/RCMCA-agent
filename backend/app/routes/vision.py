from __future__ import annotations

import os
import json
from uuid import UUID

from fastapi import APIRouter, File, HTTPException, Request, UploadFile

router = APIRouter(prefix="/api/v1/issues", tags=["vision"])
_MAX_IMAGE_BYTES = 10 * 1024 * 1024


@router.post("/{issue_id}/vision", status_code=202)
async def assess_issue_image(
    issue_id: UUID,
    request: Request,
    image: UploadFile = File(...),
):
    model_path = os.getenv("VISION_MODEL_PATH", "").strip()
    if not model_path or not os.path.isfile(model_path):
        raise HTTPException(status_code=503, detail="Vision model is not configured")
    if image.content_type not in {"image/jpeg", "image/png", "image/webp"}:
        raise HTTPException(status_code=415, detail="Upload a JPEG, PNG, or WebP image")
    content = await image.read(_MAX_IMAGE_BYTES + 1)
    await image.close()
    if not content or len(content) > _MAX_IMAGE_BYTES:
        raise HTTPException(status_code=413, detail="Image must be between 1 byte and 10 MB")

    async with request.app.state.db.acquire() as connection:
        issue_exists = await connection.fetchval(
            "SELECT EXISTS(SELECT 1 FROM road_issues WHERE id = $1)", issue_id
        )
        if not issue_exists:
            raise HTTPException(status_code=404, detail="Road issue not found")
        assessment_id = await connection.fetchval(
            """
            INSERT INTO vision_assessments (issue_id, status, image_data)
            VALUES ($1, 'pending', $2) RETURNING id
            """,
            issue_id,
            content,
        )

    return {
        "assessment_id": assessment_id,
        "issue_id": issue_id,
        "status": "pending",
        "message": "Image assessment queued for the vision worker; poll the status endpoint.",
    }


@router.get("/{issue_id}/vision/{assessment_id}")
async def get_vision_assessment(issue_id: UUID, assessment_id: UUID, request: Request):
    async with request.app.state.db.acquire() as connection:
        row = await connection.fetchrow(
            """
            SELECT id, issue_id, status, model_name, severity_estimate,
                   detections, error, created_at, updated_at
            FROM vision_assessments WHERE id = $1 AND issue_id = $2
            """,
            assessment_id,
            issue_id,
        )
    if row is None:
        raise HTTPException(status_code=404, detail="Vision assessment not found")
    result = dict(row)
    if result["detections"] is not None and isinstance(result["detections"], str):
        result["detections"] = json.loads(result["detections"])
    return result
