from __future__ import annotations

import os
from uuid import uuid4

from fastapi import APIRouter, HTTPException
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

router = APIRouter(prefix="/api/v1/uploads", tags=["uploads"])
_CONTENT_TYPES = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}


class PresignRequest(BaseModel):
    content_type: str
    file_name: str = Field(min_length=1, max_length=180)


@router.post("/presign")
async def presign_upload(payload: PresignRequest):
    """Issue a short-lived direct-to-S3 PUT URL; bucket stays private."""
    extension = _CONTENT_TYPES.get(payload.content_type.lower())
    bucket = os.getenv("S3_BUCKET", "").strip()
    region = os.getenv("AWS_REGION", "ap-south-1").strip()
    cdn_base = os.getenv("S3_PUBLIC_BASE_URL", "").strip().rstrip("/")
    if extension is None:
        raise HTTPException(status_code=415, detail="Upload a JPEG, PNG, or WebP image")
    if not bucket or not cdn_base:
        raise HTTPException(status_code=503, detail="S3 upload storage is not configured")

    key = f"evidence/{uuid4()}.{extension}"

    def create_url():
        import boto3

        client = boto3.client("s3", region_name=region)
        return client.generate_presigned_url(
            "put_object",
            Params={"Bucket": bucket, "Key": key, "ContentType": payload.content_type.lower()},
            ExpiresIn=300,
            HttpMethod="PUT",
        )

    try:
        upload_url = await run_in_threadpool(create_url)
    except Exception as exc:
        raise HTTPException(status_code=503, detail="Could not create an S3 upload URL") from exc
    return {
        "upload_url": upload_url,
        "method": "PUT",
        "headers": {"Content-Type": payload.content_type.lower()},
        "object_key": key,
        "evidence_image_url": f"{cdn_base}/{key}",
        "expires_in_seconds": 300,
    }
