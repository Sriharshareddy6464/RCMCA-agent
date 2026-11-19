"""Download the pinned private model artifact from S3, then start the worker."""

from __future__ import annotations

import asyncio
import os
from pathlib import Path


def main() -> None:
    model_path = Path(os.getenv("VISION_MODEL_PATH", "/tmp/road_damage.onnx"))
    if not model_path.is_file():
        bucket = os.environ["VISION_MODEL_BUCKET"]
        key = os.environ["VISION_MODEL_KEY"]
        import boto3

        model_path.parent.mkdir(parents=True, exist_ok=True)
        boto3.client("s3", region_name=os.getenv("AWS_REGION", "ap-south-1")).download_file(
            bucket, key, str(model_path)
        )

    from backend.app.vision_worker import run_forever

    asyncio.run(run_forever())


if __name__ == "__main__":
    main()
