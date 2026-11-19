from __future__ import annotations

import asyncio
import json
import os
import time
import urllib.request
from io import BytesIO
from pathlib import Path
from uuid import UUID, uuid4

import asyncpg
from PIL import Image, ImageDraw


def _request(url: str, data: bytes | None = None, headers: dict | None = None):
    request = urllib.request.Request(url, data=data, headers=headers or {})
    with urllib.request.urlopen(request, timeout=30) as response:
        return response.status, response.read()


async def main():
    model_path = os.getenv("VISION_MODEL_PATH", "/models/road_damage.onnx")
    if not os.path.isfile(model_path):
        raise SystemExit(f"Vision model not found: {model_path}")

    base = os.getenv("RCMCA_INTERNAL_API_URL", "http://127.0.0.1:8000")
    issue_id = None
    try:
        report = json.dumps({
            "category": "pothole",
            "description": "Temporary vision integration smoke report.",
            "latitude": 17.32021,
            "longitude": 78.67021,
            "severity": 1,
        }).encode()
        status, body = _request(
            f"{base}/api/v1/issues/report", report,
            {"Content-Type": "application/json"},
        )
        assert status == 201, status
        issue_id = json.loads(body)["issue"]["id"]

        sample_path = os.getenv("VISION_SMOKE_IMAGE", "").strip()
        if sample_path:
            image_bytes = Path(sample_path).read_bytes()
            file_name = Path(sample_path).name
            content_type = "image/jpeg" if Path(sample_path).suffix.casefold() in {".jpg", ".jpeg"} else "image/png"
        else:
            image = Image.new("RGB", (640, 640), (90, 90, 90))
            drawing = ImageDraw.Draw(image)
            drawing.rectangle((0, 330, 640, 640), fill=(65, 65, 65))
            drawing.ellipse((220, 380, 420, 520), fill=(15, 15, 15))
            encoded = BytesIO()
            image.save(encoded, format="PNG")
            image_bytes = encoded.getvalue()
            file_name = "synthetic-road.png"
            content_type = "image/png"

        boundary = f"----rcmca-{uuid4().hex}"
        multipart = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="image"; filename="{file_name}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode() + image_bytes + f"\r\n--{boundary}--\r\n".encode()
        status, body = _request(
            f"{base}/api/v1/issues/{issue_id}/vision", multipart,
            {"Content-Type": f"multipart/form-data; boundary={boundary}"},
        )
        assert status == 202, status
        assessment_id = json.loads(body)["assessment_id"]

        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            status, body = _request(
                f"{base}/api/v1/issues/{issue_id}/vision/{assessment_id}"
            )
            result = json.loads(body)
            if result["status"] in {"complete", "failed"}:
                break
            time.sleep(0.5)
        assert result["status"] == "complete", result
        assert result["model_name"] == os.path.basename(model_path), result
        payload = result["detections"]
        if isinstance(payload, str):
            payload = json.loads(payload)
        assert payload["image_width"] == 640 and payload["image_height"] == 640
        print(json.dumps({
            "status": result["status"],
            "model": result["model_name"],
            "detections": len(payload["detections"]),
            "severity_estimate": result["severity_estimate"],
        }))
    finally:
        if issue_id:
            connection = await asyncpg.connect(os.environ["DATABASE_URL"])
            try:
                await connection.execute("DELETE FROM road_issues WHERE id = $1", UUID(issue_id))
            finally:
                await connection.close()


if __name__ == "__main__":
    asyncio.run(main())
