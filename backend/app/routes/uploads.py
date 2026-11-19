from __future__ import annotations

import os
from pathlib import Path
from uuid import uuid4

from fastapi import APIRouter, File, HTTPException, Request, UploadFile
from pydantic import BaseModel, Field
from starlette.concurrency import run_in_threadpool

router = APIRouter(prefix="/api/v1/uploads", tags=["uploads"])
_CONTENT_TYPES = {"image/jpeg": "jpg", "image/png": "png", "image/webp": "webp"}

# Local (non-S3) demo storage. main.py serves this directory at /uploads.
UPLOAD_DIR = Path(
    os.getenv("UPLOAD_DIR") or Path(__file__).resolve().parents[3] / "uploads"
)
MAX_LOCAL_FILES = 4
MAX_LOCAL_BYTES = 8 * 1024 * 1024


def _looks_like(extension: str, head: bytes) -> bool:
    if extension == "jpg":
        return head.startswith(b"\xff\xd8\xff")
    if extension == "png":
        return head.startswith(b"\x89PNG\r\n\x1a\n")
    return head[:4] == b"RIFF" and head[8:12] == b"WEBP"


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


@router.post("/local")
async def upload_local(request: Request, files: list[UploadFile] = File(...)):
    """Store up to 4 demo photos on local disk so uploads work without S3."""
    if not files:
        raise HTTPException(status_code=422, detail="Attach at least one image")
    if len(files) > MAX_LOCAL_FILES:
        raise HTTPException(
            status_code=413, detail=f"Upload at most {MAX_LOCAL_FILES} images at a time"
        )

    # Validate everything before writing anything, so a bad file leaves no orphans.
    staged: list[tuple[str, bytes]] = []
    for upload in files:
        extension = _CONTENT_TYPES.get((upload.content_type or "").lower())
        if extension is None:
            raise HTTPException(status_code=415, detail="Upload JPEG, PNG, or WebP images")
        data = await upload.read(MAX_LOCAL_BYTES + 1)
        if len(data) > MAX_LOCAL_BYTES:
            raise HTTPException(
                status_code=413, detail=f"Each image must be under {MAX_LOCAL_BYTES // (1024 * 1024)} MB"
            )
        if not _looks_like(extension, data[:12]):
            raise HTTPException(status_code=415, detail="File content does not match its image type")
        staged.append((f"{uuid4().hex}.{extension}", data))

    def write_all() -> None:
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        for name, data in staged:
            (UPLOAD_DIR / name).write_bytes(data)

    await run_in_threadpool(write_all)

    base = os.getenv("PUBLIC_BASE_URL", "").strip().rstrip("/") or str(request.base_url).rstrip("/")
    urls = [f"{base}/uploads/{name}" for name, _ in staged]
    return {"image_urls": urls, "count": len(urls)}
