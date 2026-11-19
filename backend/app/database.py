from __future__ import annotations

import json
import os
from urllib.parse import quote_plus


def database_url() -> str:
    direct_url = os.getenv("DATABASE_URL", "").strip()
    if direct_url:
        return direct_url
    secret_arn = os.getenv("DATABASE_SECRET_ARN", "").strip()
    if not secret_arn:
        return "postgresql://postgres:postgres_dev_only@localhost:5432/road_intelligence"

    import boto3

    secret = boto3.client("secretsmanager", region_name=os.getenv("AWS_REGION", "ap-south-1")).get_secret_value(
        SecretId=secret_arn
    )
    credentials = json.loads(secret["SecretString"])
    username = quote_plus(credentials["username"])
    password = quote_plus(credentials["password"])
    database = os.getenv("DATABASE_NAME", "road_intelligence")
    return (
        f"postgresql://{username}:{password}@{credentials['host']}:{credentials['port']}"
        f"/{database}?sslmode=require"
    )
