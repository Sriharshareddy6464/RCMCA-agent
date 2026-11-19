# RCMCA

Road Condition Monitoring, Intelligence & Navigation for Hyderabad. The product goal is to collect road hazard reports, assess and deduplicate them, connect them to civic repair workflows, and help commuters avoid active hazards.

The product architecture is in [context.md](context.md). This repository is being built in phases. Phase 1 is the local core: FastAPI, PostGIS, Redis, and OSRM. LangGraph handles free-text report normalization; location, deduplication, verification, and route selection are deterministic application and database operations.

## Phase 1 features

- `POST /api/v1/issues/report`: stores a report, or merges it with the nearest active report of the same category within 25 meters.
- `GET /api/v1/issues/{issue_id}`: returns a stored issue.
- `GET /api/v1/issues?south=...&west=...&north=...&east=...`: returns active hazards bounded to a map viewport (maximum 1,000 rows).
- `GET /api/v1/issues/{issue_id}` and the report response include the issue's evidence gallery, with capture location, GPS accuracy, heading, and capture time for each image.
- `POST /api/v1/issues/verify` (or `POST /api/v1/issues/{issue_id}/verify`): records one current vote per user and recalculates confidence. A repeated vote by the same user updates their vote.
- `POST /api/v1/routes/plan`: requests OSRM route alternatives, finds active hazards within 40 meters of each route, and selects a route without severity 4-5 hazards when one is available. If none is available, it returns the lowest-penalty route with hazards in the response.
- `POST /api/v1/issues/assess`: uses LangGraph and an OpenAI-compatible chat model (Qwen2.5 3B via Ollama by default) to normalize a free-text report and draft a complaint in English, Telugu, or Hindi. It does not submit that complaint.
- `POST /api/v1/issues/{issue_id}/vision`: stores JPEG/PNG/WebP evidence as a durable assessment job and returns an assessment ID. The separate `vision-worker` claims jobs with PostgreSQL row locks, runs configurable ONNX detection, and persists results. Poll `GET /api/v1/issues/{issue_id}/vision/{assessment_id}` for status. Image bytes are cleared when processing finishes; stale jobs can be reclaimed after a worker restart. A detection can raise (never lower) the issue's severity.
- `GET /health`: checks PostGIS and Redis readiness.
- `POST /api/v1/uploads/presign`: creates a five-minute S3 PUT URL when a private bucket and CloudFront URL are configured.
- `municipal-sync` worker: polls an explicitly configured public CSV or JSON export every 30 minutes. It is idle when no source URL is configured.

The vote weights follow the architecture note: GHMC-sourced reports start at 2.5 confidence, other reports at 1.0, confirmation adds 0.5, and a resolved vote subtracts 0.75. Confidence at or below zero resolves an issue.

## Phase 3 mobile client

The Flutter app and Android/iOS platform projects are in [mobile/](mobile/). It includes a MapLibre Hyderabad hazard map, viewport refresh, route planning, in-app capture, signed S3 upload, vision queue submission, and 50 m verification prompts while navigation is active. `flutter analyze`, the Android debug APK build, and release AAB build (including Flutter's symbol check) pass. A workspace-local Android Command-line Tools package provides `apkanalyzer`; its SHA-256 was verified against Google's published checksum. A connected-phone launch could not be completed because the phone is currently absent from ADB. The release artifact uses a debug signing key and placeholder API URL. Live S3/CloudFront configuration, production signing, device validation, and address search remain outstanding. See [mobile/README.md](mobile/README.md).

## Phase 4 AWS foundation

Terraform resources and deployment notes are in [infra/aws/README.md](infra/aws/README.md). A read-only no-refresh plan proposes 48 additions and no updates or destroys; no resources have been created. An issued ACM certificate/domain and built immutable images are still missing, and task deployment is guarded on those inputs and explicit restricted ingress CIDRs. Provisioning RDS, Redis, ECS, ALB, S3, and CloudFront incurs charges and needs account owner review. The AWS model adapter uses managed Bedrock Qwen3 32B; that differs from the local Qwen2.5-3B-AWQ model.

The 100 rows inserted for a fresh local database are synthetic demo records around Banjara Hills, Hitec City, and Begumpet. They are not historical GHMC records. Road-network data is from [Geofabrik's Southern Zone extract](https://download.geofabrik.de/asia/india.html), derived from OpenStreetMap and available under the ODbL.

## Phase 2 integration setup

The municipal worker accepts only an authorized export endpoint configured through `GHMC_FEED_URL` or `PRAJAVANI_FEED_URL`. The response must be a public CSV or JSON export using `ticket_id`, `category`, `description`, and either `latitude` plus `longitude` or `locality`; `severity` and `status` are optional. The worker does not log in, submit complaints, or scrape the interactive citizen/OTP pages. GHMC's official status flow asks for a grievance ID and mobile/OTP, so a bulk sync needs an official export/API before its URL can be configured.

Locality-only records use the configurable Nominatim service and are cached in PostGIS. The worker sends a product-identifying User-Agent and throttles uncached lookups to at most four per minute in one worker process. This follows the [Nominatim usage policy](https://operations.osmfoundation.org/policies/nominatim/); production-scale recurring geocoding should use a self-hosted instance or a provider that supports the workload. Display OpenStreetMap attribution in any user-facing map or geocoding result.

For vision assessments, the local starter ONNX artifact can be downloaded and checksum-verified with `\.\scripts\download_vision_model.ps1`. It comes from [peterhdd/pothole-detection-yolov8](https://huggingface.co/peterhdd/pothole-detection-yolov8), detects potholes only, and has not been validated on Hyderabad roads. Its ONNX metadata lists AGPL-3.0 while the model card declares Apache-2.0; the local weight is excluded from Git and Docker build context pending license clarification. Set `VISION_CLASS_NAMES=["pothole"]` for this model; change the value to match any replacement model's exact class order. `VISION_SEVERITY_AREA_THRESHOLDS` configures four ascending box-area ratios used for the 1–5 severity estimate. This is an interim image-area heuristic; calibrate it against labeled Hyderabad road images before using the score for operational dispatch.

To run Qwen2.5 3B through vLLM instead of Ollama, set `LLM_BASE_URL=http://vllm:8000/v1` and `LLM_MODEL=Qwen/Qwen2.5-3B-Instruct-AWQ` in `.env`, then start the `inference` profile:

```powershell
docker compose --profile inference up --build
```

The profile uses the [official vLLM OpenAI-compatible container](https://docs.vllm.ai/en/stable/deployment/docker/) and the [Qwen2.5 3B AWQ model](https://huggingface.co/Qwen/Qwen2.5-3B-Instruct-AWQ), with model weights cached in a named Docker volume. It requires Docker NVIDIA GPU support. [vLLM requires Linux](https://docs.vllm.ai/en/stable/getting_started/installation/gpu/); Windows hosts should use Docker Desktop with WSL2 GPU integration. The quantized model is a local development configuration and can use most of a 6 GB GPU, so avoid starting another GPU workload concurrently.

## Local setup

Requirements: Docker Desktop with Compose, Python 3.11 for the data download helper, and an OpenAI-compatible chat endpoint if using `/issues/assess`.

1. Copy `.env.example` to `.env` and adjust local settings as needed. The default Postgres password is for local development only.
2. Download the Southern Zone OSM PBF extract (about 533 MB at the time this setup was written):

   ```powershell
   python scripts/download_osm.py
   ```

3. Clip it to the Hyderabad area and build the OSRM MLD graph. This takes additional disk space and can take several minutes:

   ```powershell
   .\scripts\prepare_osrm_data.ps1
   ```

4. Start the local services:

   ```powershell
   docker compose up --build
   ```

5. Open `http://localhost:8001/docs` for the API page. The API listens on host port 8001 by default; the PostGIS, Redis, and OSRM host ports default to 5433, 6380, and 5001.

Run the Phase 1 API smoke checks against the local stack with `.\scripts\verify_phase1.ps1`. LangGraph, municipal feed parser, and vision upload/background-result checks run inside the API image with `docker compose exec api python -m scripts.verify_graph`, `docker compose exec api python -m scripts.verify_worker`, and `docker compose exec api python -m scripts.verify_vision`.

PostGIS runs `db/init/*.sql` only when it initializes an empty data volume. To reinitialize after changing its initial schema or seed data, `docker compose down -v` removes both local PostGIS and Redis data; then start the stack again.

## Example requests

Report a road issue:

```json
{
  "category": "pothole",
  "description": "A deep pothole is forcing bikes into traffic.",
  "latitude": 17.4362,
  "longitude": 78.4483,
  "severity": 4
}
```

Plan a route:

```json
{
  "origin": {"latitude": 17.437, "longitude": 78.448},
  "destination": {"latitude": 17.443, "longitude": 78.376}
}
```

Verify an issue (`POST /api/v1/issues/verify`):

```json
{
  "issue_id": "d4e4eec5-d617-4e63-9823-a70d68b45957",
  "user_id": "6e6b4e3b-5a0e-45d3-b5ea-82e625e87f57",
  "vote_type": "CONFIRM"
}
```

## Known Phase 1 boundaries

- The local OSRM graph uses driving routes and OSM coverage; it does not yet implement hazard-specific edge weights or polygon exclusions. The service compares OSRM alternatives and reports hazards along the selected route.
- Redis publishes issue updates on the `road_issues` channel, but there is not yet a WebSocket endpoint.
- Local development can omit S3; direct mobile photo reporting needs AWS bucket, CloudFront, and task credentials configured.
- The API has no authentication yet. Do not expose it to the public internet.
- The API has no account authentication yet; mobile verification uses a persistent anonymous device ID.
- The mobile app uses public demo map tiles and coordinates for destination input; production tiles and address search remain follow-up work.
- AWS deployment is Terraform-prepared but not provisioned. See [infra/aws/README.md](infra/aws/README.md).
