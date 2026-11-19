# Technical Review: Road Condition Monitoring, Intelligence & Navigation System (RCMCA)

**Target Scope:** Greater Hyderabad Municipal Corporation (GHMC), Telangana, India  
**Workspace:** [03_langgraph_mcp](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp)  
**Architecture:** Microservices with Spatial PostGIS, OSRM Routing Engine, Computer Vision (YOLOv8 ONNX), LangGraph SLM Triage, Flutter Client, and AWS Cloud (ECS Fargate/Terraform).

---

## 1. System Architecture & Components

```
                   +-------------------------------------------------+
                   |           Flutter Client (MapLibre GL)          |
                   |   - Hardware GPS Lock & 1-Tap Camera Reporting   |
                   |   - 50m Geofence Re-Inspection Modal            |
                   +------------------------+------------------------+
                                            |
                                            | HTTPS (REST / S3 Pre-sign)
                                            v
                   +-------------------------------------------------+
                   |          FastAPI Gateway (Python 3.11)          |
                   |   - Advisory Lock Spatial Deduplication (25m)   |
                   |   - Corridor Route Hazard Analysis (40m)        |
                   |   - Asyncpg connection pooling & migrations     |
                   +--------+------------------+------------------+--+
                            |                  |                  |
           +----------------+                  |                  +----------------+
           v                                   v                                   v
+----------------------+             +--------------------+              +-------------------+
| PostgreSQL 16/PostGIS|             |  Redis 7 (Alpine)  |              | OSRM (v5.27.1 MLD)|
| - GiST Spatial Index |             |  - Pub/Sub channel |              | - Hyderabad Graph |
| - Row locks / Queues |             |    ("road_issues") |              | - Car.lua Profile |
+----------------------+             +--------------------+              +-------------------+
           ^                                                                       ^
           |                                                                       |
+----------+------------+                    +--------------------+                |
| Background Workers    |                    | Inference Engines  |                |
| - vision-worker       |------------------->| - ONNX Runtime     |                |
|   (SKIP LOCKED queue) |                    |   (YOLOv8 Pothole) |                |
| - municipal-sync      |                    | - LangGraph SLM    |----------------+
|   (Nominatim 4 req/m) |                    |   (Qwen2.5/Bedrock)|
+-----------------------+                    +--------------------+
```

| Component | Technology | File Reference | Primary Function |
| :--- | :--- | :--- | :--- |
| **API Backend** | FastAPI, Uvicorn, asyncpg | [backend/app/main.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/main.py) | Central REST interface, DB pooling, lifespan management |
| **Spatial Database** | PostgreSQL 16 + PostGIS 3.4 | [db/init/001_schema.sql](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/db/init/001_schema.sql) | WGS 84 spatial queries, deduplication, votes, evidence |
| **Routing Engine** | OSRM v5.27.1 (MLD) | [backend/app/routes/routing.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/routes/routing.py) | Hyderabad driving graph, alternative route generation |
| **SLM Triage** | LangGraph, Qwen2.5-3B / Bedrock | [rcmc_graph.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/rcmc_graph.py) | Text normalization, severity extraction, complaint drafting |
| **Computer Vision** | ONNX Runtime, YOLOv8s | [backend/app/services/vision.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/services/vision.py) | Pothole detection, IoU/NMS, box area-ratio severity |
| **Vision Worker** | Python Async Background Worker | [backend/app/vision_worker.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/vision_worker.py) | PostgreSQL `SKIP LOCKED` task queue, auto-requeue stale jobs |
| **Civic Sync Worker**| Python Httpx Scraper | [backend/app/worker.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/worker.py) | 30-min polling of municipal feeds, Nominatim geocoding |
| **Mobile Client** | Flutter 3.50+ / Dart | [mobile/lib/main.dart](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/mobile/lib/main.dart) | MapLibre rendering, live location, GPS shutter capture, S3 upload |
| **Infrastructure** | Terraform / AWS ECS Fargate | [infra/aws/main.tf](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/infra/aws/main.tf) | Multi-AZ RDS, ElastiCache Redis, ALB, S3 + CloudFront OAC |

---

## 2. All Mathematical & Algorithmic Formulas

### 2.1. LangGraph Priority Score & Dispatch Tier
Implemented in [rcmc_graph.py#L94-L115](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/rcmc_graph.py#L94-L115):
$$\text{Score}_{\text{base}} = \text{severity} \times 15, \quad \text{severity} \in [1, 5]$$
$$\text{Score} = \text{Score}_{\text{base}} + \Delta_{\text{cat}} + \Delta_{\text{site}}$$
Where:
- $\Delta_{\text{cat}} = +10$ if $\text{category} \in \{\text{open\_manhole}, \text{waterlogging}, \text{broken\_divider}\}$, else $0$
- $\Delta_{\text{site}} = +20$ if $\text{near\_sensitive\_site} = \text{True}$, else $0$
- Clamped score: $\text{Priority Score} = \min(\text{Score}, 100)$

**Dispatch Classification:**
- $\text{Priority Score} \ge 75 \implies \text{Tier: } \mathbf{HIGH}$ ("Immediate crew inspection")
- $45 \le \text{Priority Score} < 75 \implies \text{Tier: } \mathbf{MEDIUM}$ ("Schedule maintenance inspection")
- $\text{Priority Score} < 45 \implies \text{Tier: } \mathbf{LOW}$ ("Monitor and include in routine inspection")

---

### 2.2. Commuter Confidence & Vote Decay Formula
Implemented in [backend/app/routes/issues.py#L190-L219](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/routes/issues.py#L190-L219):
$$C = C_{\text{base}} + \sum_{i=1}^{N} \Delta_{\text{vote}, i}$$
Where:
- $C_{\text{base}} = 2.5$ if $\text{source} = \text{"ghmc\_portal"}$; $C_{\text{base}} = 1.0$ if $\text{source} = \text{"user\_report"}$
- Vote updates: $\Delta_{\text{vote}} = +0.5$ for $\text{CONFIRM}$; $\Delta_{\text{vote}} = -0.75$ for $\text{RESOLVED}$
- Individual user deduplication: `ON CONFLICT (issue_id, user_id) DO UPDATE` ensures 1 active vote per user.

**Lifecycle Transitions:**
- If $C \le 0.0 \implies \text{status} = \mathbf{resolved}$ (archived from routing graph)
- Else if $\text{source} = \text{"ghmc\_portal"} \implies \text{status} = \mathbf{verified\_ghmc}$
- Else if $C > 1.0 \implies \text{status} = \mathbf{active\_hazard}$
- Else $\implies \text{status unchanged}$ (`community_pending`)

---

### 2.3. Dynamic Route Hazard Cost & Corridor Evaluation
Implemented in [backend/app/db.py#L17-L36](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/db.py#L17-L36) and [backend/app/routes/routing.py#L40-L63](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/routes/routing.py#L40-L63):

1. **Corridor Hazard Query:**
   $$\text{ST\_DWithin}(\text{location}::\text{geography}, \text{route\_path}::\text{geography}, 40\text{ meters}) \quad \text{WHERE } \text{status} \ne \text{'resolved'}$$
2. **Route Selection Logic:**
   - Filter candidate routes where $\forall h \in \text{hazards}, \text{severity}_h < 4$. If safe routes exist, pick:
     $$\text{Chosen Route} = \arg\min_{r \in \text{SafeRoutes}} (\text{duration}(r))$$
   - If **all** OSRM alternative routes intersect severe hazards ($\text{severity} \ge 4$), penalize each severe hazard by 300 seconds (5 minutes):
     $$\text{Cost}(r) = \text{duration}(r) + 300 \times \sum_{h \in \text{hazards}(r)} \mathbb{I}(\text{severity}_h \ge 4)$$
     $$\text{Chosen Route} = \arg\min_{r \in \text{Candidates}} (\text{Cost}(r))$$
3. **Specification Route Risk Penalty (Reference from ADD ON):**
   $$\text{Route Penalty} = \sum \left( \text{Severity Scale [1-5]} \times \text{Freshness Factor} \right)$$

---

### 2.4. Computer Vision Geometry & Severity Estimation
Implemented in [backend/app/services/vision.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/services/vision.py):

1. **Letterbox Transformation:**
   $$s = \min\left(\frac{\text{side}}{W}, \frac{\text{side}}{H}\right), \quad \text{pad}_x = \left\lfloor \frac{\text{side} - \text{round}(W \cdot s)}{2} \right\rfloor, \quad \text{pad}_y = \left\lfloor \frac{\text{side} - \text{round}(H \cdot s)}{2} \right\rfloor$$
   Canvas filled with RGB `(114, 114, 114)`; pixel normalization: $X = \frac{I}{255.0} \in [0.0, 1.0]$.
2. **Coordinate Un-letterboxing:**
   $$x = \max\left(0.0, \min\left(W, \frac{x_{\text{box}} - \text{pad}_x}{s}\right)\right), \quad y = \max\left(0.0, \min\left(H, \frac{y_{\text{box}} - \text{pad}_y}{s}\right)\right)$$
3. **Intersection over Union (IoU):**
   $$\text{IoU}(A, B) = \frac{\max(0, \min(A_{x2}, B_{x2}) - \max(A_{x1}, B_{x1})) \times \max(0, \min(A_{y2}, B_{y2}) - \max(A_{y1}, B_{y1}))}{\max\left(\text{Area}(A) + \text{Area}(B) - \text{Area}(A \cap B), 10^{-8}\right)}$$
4. **Largest Detection Area Ratio Severity Heuristic:**
   Thresholds: $T = [0.01, 0.03, 0.08, 0.20]$ (`VISION_SEVERITY_AREA_THRESHOLDS`).
   $$\text{Ratio}_{\max} = \max_{b \in \text{detections}} \left( \frac{(x_2 - x_1) \times (y_2 - y_1)}{W \times H} \right)$$
   $$\text{Severity} = 1 + \sum_{t \in T} \mathbb{I}(\text{Ratio}_{\max} \ge t) \in [1, 5]$$
   - $\text{Ratio}_{\max} < 0.01 \implies 1$
   - $0.01 \le \text{Ratio}_{\max} < 0.03 \implies 2$
   - $0.03 \le \text{Ratio}_{\max} < 0.08 \implies 3$
   - $0.08 \le \text{Ratio}_{\max} < 0.20 \implies 4$
   - $\text{Ratio}_{\max} \ge 0.20 \implies 5$
5. **Monotonic Severity Update:**
   $$\text{severity}_{\text{issue}} \leftarrow \max(\text{severity}_{\text{current}}, \text{severity}_{\text{estimate}})$$

---

### 2.5. Spatial Deduplication Radius
Implemented in [backend/app/routes/issues.py#L61-L82](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/routes/issues.py#L61-L82):
$$\text{ST\_DWithin}\left(\text{location}::\text{geography}, \text{ST\_SetSRID}(\text{ST\_MakePoint}(\text{lon}, \text{lat}), 4326)::\text{geography}, 25\text{ meters}\right)$$
- If duplicate exists within 25 meters under same `hazard_category`:
  $$\text{report\_count} \leftarrow \text{report\_count} + 1, \quad \text{severity} \leftarrow \max(\text{severity}_{\text{existing}}, \text{severity}_{\text{new}})$$
  $$\text{evidence\_image\_url} \leftarrow \text{COALESCE}(\text{evidence\_image\_url}_{\text{existing}}, \text{evidence\_image\_url}_{\text{new}})$$

---

### 2.6. Geocoding Rate Limiter & Boundary Constraints
Implemented in [backend/app/services/geocoding.py](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/services/geocoding.py):
- Minimum interval: $\Delta t \ge 15.1\text{ s}$ ($\le 4\text{ requests per minute}$ single-threaded lock).
- Nominatim Query: `q = "{normalized_locality}, Hyderabad, Telangana, India"`, `format = "jsonv2"`, `limit = 1`.
- OSRM Hyderabad Geographic Extract Bounding Box: `[min_lon=78.15, min_lat=17.15, max_lon=78.72, max_lat=17.62]` (clipped via `osmium extract -b`).

---

## 3. Complete API & Service Endpoints

### 3.1. Public Application Endpoints (FastAPI)
All routes prefixed with `/api/v1` except health:

| HTTP Verb | Path | Request Schema / Params | Response Schema / Status | Description |
| :--- | :--- | :--- | :--- | :--- |
| `GET` | `/health` | None | `{"status": "ok"}` (200 / 503) | Readiness check for PostgreSQL connection pool and Redis ping. |
| `POST` | `/api/v1/issues/assess` | [IssueAssessmentRequest](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L128-L140) (`description`, `latitude`, `longitude`, `near_sensitive_site`, `language`) | `{"issue": IssueFacts, "priority_score": int, "dispatch_tier": str, "action_required": str, "complaint_subject": str, "complaint_draft": str}` | LangGraph execution: extracts facts, calculates priority, drafts complaint in `en`, `te`, or `hi`. |
| `GET` | `/api/v1/issues` | Query: `south`, `west`, `north`, `east` (float), `limit` (int, default 500, max 1000) | `list[IssueResponse]` (200) | Bounding box search (`ST_MakeEnvelope`) for active hazards (`status <> 'resolved'`). |
| `POST` | `/api/v1/issues/report` | [IssueReportRequest](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L19-L29) (`category`, `description`, `lat`, `lon`, `severity`, metadata) | [IssueReportResponse](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L60-L64) (201) | Submits hazard; merges into duplicate within 25m or creates row; saves evidence record. |
| `GET` | `/api/v1/issues/{issue_id}` | Path: `issue_id` (UUID) | [IssueResponse](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L42-L58) (200 / 404) | Full issue details including full gallery of historical evidence attachments. |
| `POST` | `/api/v1/issues/verify` | [VerifyIssueByIdRequest](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L87-L89) (`issue_id`, `user_id`, `vote_type`) | [VerifyIssueResponse](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L91-L96) (200 / 404) | Casts verification vote (`CONFIRM` or `RESOLVED`) and recalculates confidence score. |
| `POST` | `/api/v1/issues/{issue_id}/verify`| Path: `issue_id`, Body: [VerifyIssueRequest](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L82-L85) | [VerifyIssueResponse](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L91-L96) (200 / 404) | REST-compliant alias for issue verification. |
| `POST` | `/api/v1/issues/{issue_id}/vision` | Path: `issue_id`, Form: `image` (MultipartFile $\le 10\text{ MB}$) | [VisionAssessmentResponse](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L142-L146) (202 / 413 / 415 / 503)| Enqueues image into `vision_assessments` table (`status='pending'`) for asynchronous inference. |
| `GET` | `/api/v1/issues/{issue_id}/vision/{assessment_id}` | Path: `issue_id`, `assessment_id` (UUID) | JSON (`status`, `model_name`, `severity_estimate`, `detections`, `error`) | Polls status of queued vision inference task. |
| `POST` | `/api/v1/routes/plan` | [RoutePlanRequest](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L103-L106) (`origin`, `destination`) | [RoutePlanResponse](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/schemas.py#L120-L126) (200 / 422 / 503)| Queries OSRM for up to 3 routes, intersects 40m corridor hazards, selects safest/least costly. |
| `POST` | `/api/v1/uploads/presign` | [PresignRequest](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/routes/uploads.py#L14-L17) (`content_type`, `file_name`) | `{"upload_url", "method": "PUT", "headers", "object_key", "evidence_image_url", "expires_in_seconds": 300}` | Generates 5-minute AWS S3 pre-signed PUT URL with CloudFront distribution link. |

### 3.2. Internal, Dependent & Upstream Endpoints
- **OSRM Engine:** `GET {OSRM_URL}/route/v1/driving/{lon1},{lat1};{lon2},{lat2}?alternatives=3&steps=false&geometries=geojson&overview=full`
- **Nominatim Geocoder:** `GET {GEOCODER_BASE_URL}/search?q={query}, Hyderabad, Telangana, India&format=jsonv2&limit=1`
- **Municipal Feeds:** `GET {GHMC_FEED_URL}`, `GET {PRAJAVANI_FEED_URL}` (Supports CSV header rows or JSON arrays / `records` lists)
- **Local vLLM / OpenAI Chat Endpoint:** `POST {LLM_BASE_URL}/chat/completions`
- **Redis Pub/Sub:** Channel `road_issues` (events: `issue_reported`, `issue_verified`)
- **Direct S3 Upload Target:** `PUT https://{bucket}.s3.{region}.amazonaws.com/evidence/{uuid}.{ext}`
- **Evidence CDN Origin:** `GET https://{cloudfront_domain}/evidence/{uuid}.{ext}`
- **External Model Source:** `https://huggingface.co/peterhdd/pothole-detection-yolov8/resolve/main/best.onnx?download=true`
- **External OSM Source:** `https://download.geofabrik.de/asia/india/southern-zone-latest.osm.pbf`

---

## 4. Technical Terms, Enums & Database Definitions

### 4.1. Enums and Literals
- **`hazard_category`**: `'pothole'`, `'waterlogging'`, `'damaged_surface'`, `'open_manhole'`, `'broken_divider'`, `'other'`
- **`hazard_status`**: 
  - `'community_pending'`: Submitted by citizen, pending validation ($C \le 1.0$)
  - `'verified_ghmc'`: Sourced from official municipal grievance portal ($C = 2.5$)
  - `'active_hazard'`: Verified by community upvotes ($C > 1.0$)
  - `'resolved'`: Closed by negative commuter votes ($C \le 0.0$) or official ticket resolution
- **`verification_vote_type`**: `'CONFIRM'` ($+0.5$), `'RESOLVED'` ($-0.75$)
- **`dispatch_tier`**: `'HIGH'`, `'MEDIUM'`, `'LOW'`
- **`vision_status`**: `'pending'`, `'processing'`, `'complete'`, `'failed'`
- **Supported Languages**: `'en'` (English), `'te'` (Telugu), `'hi'` (Hindi)

### 4.2. Concurrency Locks & Database Patterns
- **Advisory Transaction Locks:**
  - `pg_advisory_xact_lock(731904221)`: Serializes concurrent citizen hazard reporting in [backend/app/routes/issues.py#L60](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/routes/issues.py#L60) to eliminate race conditions on 25m duplicate checks.
  - `pg_advisory_xact_lock(731904222)`: Serializes schema migration runs in [backend/app/migrations.py#L12](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/migrations.py#L12).
- **Pessimistic Row Locks:** `SELECT ... FOR UPDATE` on issue voting and deduplication.
- **Worker Queue Concurrency:** `SELECT ... FOR UPDATE SKIP LOCKED LIMIT 1` in [backend/app/vision_worker.py#L44](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/vision_worker.py#L44) enables horizontal worker scaling without dual-processing.
- **Spatial Indexes:**
  - `idx_road_issues_location` USING `GIST(location)`
  - `idx_road_issues_category_status` ON `road_issues(category, status)`
  - `idx_road_issues_external_ticket` UNIQUE ON `(source, external_ticket_id)` WHERE `external_ticket_id IS NOT NULL`

---

## 5. Configuration, Environment Variables & Secrets

### 5.1. Master Variable Reference

| Variable | Default Value | Production AWS Source | Purpose & Classification |
| :--- | :--- | :--- | :--- |
| `POSTGRES_USER` | `postgres` | RDS Master Secret | Database administrator user |
| `POSTGRES_PASSWORD` | `postgres_dev_only` | RDS Master Secret | **Hardcoded Dev Secret** (local only) |
| `POSTGRES_DB` / `DATABASE_NAME`| `road_intelligence` | Terraform variable | Database name |
| `DATABASE_URL` | `postgresql://postgres:postgres_dev_only@postgis:5432/road_intelligence` | Composed dynamically | Direct database connection URI |
| `DATABASE_SECRET_ARN` | `""` | `aws_db_instance.main.master_user_secret[0].secret_arn` | AWS Secrets Manager ARN storing RDS credentials |
| `REDIS_URL` | `redis://localhost:6379/0` (dev) / `redis://redis:6379/0` (docker) | `rediss://{endpoint}:6379/0?ssl_cert_reqs=required` | Cache & Pub/Sub broker connection string |
| `OSRM_URL` | `http://localhost:5000` (dev) / `http://osrm:5000` (docker) | `http://osrm.rcmca.internal:5000` | OSRM routing daemon endpoint |
| `LLM_PROVIDER` | `openai_compatible` | `bedrock` | SLM backend selection (`openai_compatible` / `bedrock`) |
| `LLM_BASE_URL` | `http://host.docker.internal:11434/v1` | N/A (Bedrock Converse SDK used) | Base URL for Ollama / vLLM API |
| `LLM_API_KEY` | `ollama-local` | IAM Role Auth | OpenAI-compatible bearer authorization key |
| `LLM_MODEL` / `bedrock_model_id`| `qwen2.5:3b` | `qwen.qwen3-32b-v1:0` | Target inference model ID |
| `VLLM_MODEL` | `Qwen/Qwen2.5-3B-Instruct-AWQ` | N/A | Quantized GPU checkpoint for local vLLM |
| `VLLM_GPU_MEMORY_UTILIZATION`| `0.82` | N/A | VRAM allocation cap for AWQ-Marlin on RTX 3050 |
| `VISION_MODEL_PATH` | `/models/road_damage.onnx` | `/tmp/road_damage.onnx` (synced from S3) | Local path to ONNX model weights |
| `VISION_CLASS_NAMES` | `["pothole"]` | `["pothole"]` | Array of labels matching model output classes |
| `VISION_CONFIDENCE_THRESHOLD`| `0.35` | `0.35` | Minimum detection confidence score |
| `VISION_NMS_THRESHOLD` | `0.45` | `0.45` | Non-Maximum Suppression IoU threshold |
| `VISION_SEVERITY_AREA_THRESHOLDS`| `0.01,0.03,0.08,0.2` | `0.01,0.03,0.08,0.2` | Bounding-box area ratio boundaries for severity 1–5 |
| `VISION_WORKER_POLL_SECONDS` | `0.5` | `0.5` | Queue polling cycle interval |
| `VISION_WORKER_RECLAIM_SECONDS`| `60` | `60` | Stale job evaluation cycle (requeues jobs > 10m old) |
| `S3_BUCKET` | `""` | `aws_s3_bucket.evidence.bucket` | Private AWS S3 bucket for evidence images & models |
| `S3_PUBLIC_BASE_URL` | `""` | `https://{cloudfront_distribution.evidence.domain_name}` | CloudFront HTTPS CDN base domain |
| `GHMC_FEED_URL` | `""` | Parameterized in tfvars | Endpoint for authorized GHMC ticket feed |
| `PRAJAVANI_FEED_URL` | `""` | Parameterized in tfvars | Endpoint for authorized Prajavani feed |
| `GEOCODER_BASE_URL` | `https://nominatim.openstreetmap.org` | Same | Upstream geocoding provider |
| `GEOCODER_USER_AGENT` | `RCMCA-road-condition-monitor/0.2` | `RCMCA-road-condition-monitor/1.0` | HTTP User-Agent identifying client to OSM |
| `MUNICIPAL_SYNC_INTERVAL_SECONDS`| `1800` (30 minutes) | `1800` | Recurrent background scraping interval |
| `RCMCA_API_BASE_URL` | `http://10.0.2.2:8001` (mobile) | `https://{alb.dns_name}` | Mobile client compile-time environment definition |

---

## 6. Critical Security, Architectural & Licensing Findings

1. **Hardcoded Credentials & Dev Secrets:**
   - The password `postgres_dev_only` is hardcoded across [.env.example](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/.env.example#L2), [docker-compose.yml](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/docker-compose.yml#L6), [backend/app/database.py#L14](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/database.py#L14), and test scripts. In production, [backend/app/database.py#L18](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/backend/app/database.py#L18) correctly switches to AWS Secrets Manager (`DATABASE_SECRET_ARN`), but any environment without AWS credentials falls back to the hardcoded default.
2. **Missing API Authentication & Authorization:**
   - The FastAPI application implements **no authentication, API tokens, or OAuth2**. Any client with network access can post reports, inject coordinates, or alter voting confidence scores.
   - In AWS Terraform, [infra/aws/main.tf#L435-L445](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/infra/aws/main.tf#L435-L445) mitigates this via strict preconditions: ALB ingress CIDR cannot be open (`0.0.0.0/0` is blocked by Terraform validation) and requires explicit IP whitelisting (`allowed_ingress_cidrs`).
3. **Sybil Vulnerability on Re-Inspection Voting:**
   - The verification endpoint relies on a client-supplied `user_id` stored in client-side SharedPreferences ([mobile/lib/main.dart#L99](file:///c:/Users/Sriharsha/inquilab/agentic_workflows/rcmc_agent/03_langgraph_mcp/mobile/lib/main.dart#L99)). An attacker can script multiple random UUIDs to arbitrarily lower confidence scores below $0.0$, maliciously triggering `status = 'resolved'` to remove hazards.
4. **Model Licensing Ambiguity:**
   - Starter model weights `models/road_damage.onnx` (SHA-256: `91DD7DE7A110C61314EA19A958FCC85C7B3461CC6D60D87FEFC08B41AC6E32C5`) have a license conflict: the HuggingFace model card states Apache-2.0, whereas the embedded ONNX metadata contains `license: AGPL-3.0 License`. The file is correctly excluded from Git and Docker contexts.
5. **Bedrock Model Divergence:**
   - Local inference utilizes 4-bit `Qwen2.5-3B-Instruct-AWQ` on vLLM. AWS deployment configures `qwen.qwen3-32b-v1:0` via Amazon Bedrock Converse API due to the absence of Qwen2.5-3B on Bedrock, which alters inference cost, latency, and token consumption profile.
6. **Unauthenticated Public Endpoints & Denial-of-Service Risk:**
   - `POST /api/v1/issues/{issue_id}/vision` accepts direct multipart uploads up to 10 MB in memory into the database `BYTEA` column before worker processing. While bytes are set to `NULL` upon job completion, high-volume uploads could exhaust PostgreSQL disk storage.