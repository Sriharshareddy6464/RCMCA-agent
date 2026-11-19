# Road Condition Monitoring, Intelligence & Navigation System (RCMCA)
**Target Region:** Greater Hyderabad Municipal Corporation (GHMC), Telangana, India  
**System Architecture:** Mobile-First, Microservice Architecture with Embedded SLM & Spatial Routing Engine  
**Status:** Architecture Finalized (Docker Compose First -> AWS ECS Production)

---

## 1. Executive Summary & Objective

The Civic Road Condition Intelligence & Navigation System is a production-grade, mobile-first mobility platform. It solves urban transit delays and vehicle damage caused by undetected road defects (potholes, waterlogging, open manholes, damaged dividers) across Hyderabad.

Departing from generic conversational chatbots and visual orchestrators (Dify, n8n), this platform operates a dedicated, code-first architecture. It combines deterministic geospatial calculation (PostGIS + OSRM), real-time citizen-sensed data, automated GHMC grievance portal synchronization, vision-based distress severity scoring, and a Small Language Model (SLM) for civic report normalization and route advisories.

---

## 2. Definitive Technology Stack (Prescribed Best-in-Class)

Every layer has been chosen specifically for low latency, zero-hallucination geospatial routing, and cost efficiency.

| Layer | Selected Technology | Role & Justification |
| :--- | :--- | :--- |
| **Mobile Client** | **Flutter (Dart)** | Cross-platform single codebase, native camera and 60fps MapLibre GL rendering, hardware GPS access. |
| **Mapping & SDK** | **MapLibre Native / GL** | Open-source, zero per-seat licensing, supports custom vector tiles and polyline rendering. |
| **API Backend** | **FastAPI (Python 3.11)** | High-throughput async I/O (`asyncpg`), native Pydantic schema validation, rapid microservice modularity. |
| **Spatial Database** | **PostgreSQL 16 + PostGIS 3.4** | Industry-standard spatial engine; executes indexing (`GIST`) and corridor intersection queries (`ST_DWithin`). |
| **In-Memory Cache** | **Redis 7 (Alpine)** | Sub-millisecond geohash indexing (`GEOADD`/`GEOSEARCH`), WebSocket pub/sub live hazard sync, and sliding-window session storage. |
| **Routing Engine** | **OSRM (Open Source Routing Machine)** | Deterministic multi-modal routing engine running directly against Hyderabad OpenStreetMap (`.pbf`) data. |
| **SLM Inference** | **Qwen2.5-3B-Instruct** | Quantized 4-bit edge/server SLM for structured civic complaint drafting and conversational trip summaries. |
| **Vision Model** | **YOLOv8-Pothole (Fine-tuned ONNX)** | Real-time object detection classifying potholes, cracks, and waterlogging from camera uploads. |
| **Cloud Hosting** | **AWS ECS Fargate + RDS + ElastiCache** | Serverless container orchestration with auto-scaling; eliminates EC2 server maintenance. |
| **Storage & CDN** | **Amazon S3 + CloudFront** | Direct mobile pre-signed uploads for civic evidence images; public-read CDN distribution. |

---

## 3. Data Sources & Integration Pipelines

### 3.1. Official Municipal Feeds (GHMC & Prajavani)
* **Ingestion:** Asynchronous scraper worker (`httpx` + `Playwright`) executing every 30 minutes.
* **Scope:** Scrapes road repair tickets, waterlogging reports, and drainage complaints from the GHMC Citizen Portal and Prajavani.
* **Normalization:** Locality strings are geocoded into precise coordinates via OpenStreetMap Nominatim.
* **Lifecycle:** When a ticket status flips to `Resolved` on the portal, the database updates the hazard status to `resolved` and removes it from the routing penalty graph.

### 3.2. Citizen Crowdsourced Ingestion
* **Capture:** Citizens photograph hazards in the mobile app. The device extracts hardware GPS coordinates (`lat`, `lon`, `accuracy`, `heading`) at the millisecond of shutter release.
* **Vision Classification:** Uploaded photos trigger YOLOv8 inference to detect bounding boxes and assign a structural severity score (1 to 5).
* **Deduplication:** Spatial query runs within a 25-meter radius. If an issue already exists, the report counter and evidence gallery update without generating redundant map pins.

### 3.3. Commuter Re-Inspection ("Waze for Roads" Loop)
* **Geofenced Prompt:** When an active commuter enters a 50-meter radius of an unverified hazard, an unobtrusive banner appears: *"Pothole reported 40m ahead. Still damaged?"*
* **Dynamic Decay Algorithm:**
  * Base citizen submission: `confidence_score = 1.0`
  * GHMC ticket confirmed: `confidence_score = 2.5`
  * Commuter upvote ("Still there"): `+0.5`
  * Commuter downvote ("Road fixed"): `-0.75`
  * If `confidence_score <= 0`, status changes to `resolved` and the pin is archived.

---

## 4. End-to-End System Architecture

```
                                  +-------------------------------------+
                                  |     Flutter Mobile Application      |
                                  |   - MapLibre GL Realtime Map        |
                                  |   - 1-Tap Camera + EXIF GPS Lock    |
                                  |   - Passive Geofence Re-Inspection  |
                                  +------------------+------------------+
                                                     |
                                                     | HTTPS / WebSockets
                                                     v
                                  +-------------------------------------+
                                  |         FastAPI Gateway             |
                                  |   - Spatial Deduplication Filter    |
                                  |   - Dynamic Avoidance Coordinator   |
                                  +--------+-------------------+--------+
                                           |                   |
                     +---------------------+                   +---------------------+
                     |                                                               |
                     v                                                               v
      +-----------------------------+                                 +-----------------------------+
      |  PostgreSQL 16 + PostGIS    |                                 |       Redis 7 Cluster       |
      | - Spatial Index: GIST       |                                 | - Active 5km Viewport Geo   |
      | - 25m Deduplication Logic   |                                 | - Live Hazard Pub/Sub       |
      | - 40m Corridor Intersect    |                                 | - SLM Chat Context Window   |
      +--------------+--------------+                                 +-----------------------------+
                     |
                     +---------------------------------+
                     |                                 |
                     v                                 v
      +-----------------------------+   +-----------------------------+   +-----------------------------+
      |    OSRM Routing Engine      |   |   SLM Intent & Drafting     |   |    GHMC Scraper Service     |
      | - Hyderabad OSM Graph       |   | - Qwen2.5-3B-Instruct       |   | - Prajavani & GHMC Portal   |
      | - Dynamic Hazard Detours    |   | - Pydantic JSON Enforcement |   | - Auto-Status Reconciliation|
      +-----------------------------+   +-----------------------------+   +-----------------------------+
```

---

## 5. Core Geospatial Database Schema (`schema.sql`)

```sql
CREATE EXTENSION IF NOT EXISTS postgis;
CREATE EXTENSION IF NOT EXISTS "uuid-ossp";

CREATE TYPE hazard_category AS ENUM (
    'pothole',
    'waterlogging',
    'damaged_surface',
    'open_manhole',
    'broken_divider'
);

CREATE TYPE hazard_status AS ENUM (
    'community_pending',
    'verified_ghmc',
    'active_hazard',
    'resolved'
);

CREATE TABLE road_issues (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    category hazard_category NOT NULL,
    severity SMALLINT CHECK (severity BETWEEN 1 AND 5),
    confidence_score FLOAT DEFAULT 1.0,
    report_count INT DEFAULT 1,
    description TEXT,
    evidence_image_url TEXT,
    location GEOMETRY(Point, 4326) NOT NULL,
    source VARCHAR(50) NOT NULL, -- 'ghmc_portal', 'user_report', 'traffic_police'
    external_ticket_id VARCHAR(100), -- GHMC grievance reference ID
    status hazard_status DEFAULT 'community_pending',
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Essential Spatial & Performance Indexes
CREATE INDEX idx_road_issues_location ON road_issues USING GIST(location);
CREATE INDEX idx_road_issues_status ON road_issues(status);

CREATE TABLE verification_votes (
    id UUID PRIMARY KEY DEFAULT uuid_generate_v4(),
    issue_id UUID REFERENCES road_issues(id) ON DELETE CASCADE,
    user_id UUID NOT NULL,
    vote_type VARCHAR(10) CHECK (vote_type IN ('CONFIRM', 'RESOLVED')),
    created_at TIMESTAMPTZ DEFAULT NOW()
);
```

---

## 6. Real-Time Routing & Dynamic Detour Logic

```
[Start Navigation: Point A to Point B]
                   |
                   v
    Fetch Baseline Route Polyline (OSRM)
                   |
                   v
    Execute PostGIS Corridor Query:
    ST_DWithin(location::geography, Route_Polyline::geography, 40 meters)
                   |
        +----------+----------+
        |                     |
[No Severe Hazards]    [Severe Hazard Found (Severity >= 4)]
        |                     |
  Return Direct Path          v
                       Generate Avoidance Bounding Polygon
                              |
                       Re-query OSRM with Exclusion Zone
                              |
                       Trigger Alternate Bypass Route +
                       SLM Audio/Text Rationale
```

---

## 7. Phase-by-Phase Implementation Plan

### Phase 1: Local Docker Compose Core Development
* **Goal:** A fully functioning backend, routing, and spatial deduplication system running locally.
* **Checklist:**
  - [x] Write root `docker-compose.yml` orchestrating `postgis`, `redis`, `osrm`, and `fastapi`.
  - [x] Download Geofabrik Southern Zone OpenStreetMap data and add a helper to clip it to the Hyderabad bounding box.
  - [x] Run OSRM `extract`, `partition`, and `customize` to build the Hyderabad driving graph.
  - [x] Implement `POST /api/v1/issues/report` with 25-meter spatial deduplication query.
  - [x] Implement `POST /api/v1/routes/plan` with 40-meter corridor hazard intersection and OSRM alternatives.
  - [x] Implement `POST /api/v1/issues/verify` recalculating `confidence_score` upon user votes.
  - [x] Seed database with 100 synthetic local demo issues across Banjara Hills, Hitec City, and Begumpet. These rows are not historical GHMC records.

### Phase 2: AI Pipelines & GHMC Civic Sync Worker
* **Goal:** Automated municipal ticket scraping, vision scoring, and report structuring.
* **Checklist:**
  - [x] Build a 30-minute municipal sync worker for explicitly configured official CSV/JSON exports. The reviewed GHMC citizen/status pages do not expose a public bulk feed; portal scraping remains disabled until an authorized export/API is available.
  - [x] Add cached, rate-limited Nominatim geocoding for locality-only imported records.
  - [x] Integrate fine-tuned ONNX YOLOv8 model in the dedicated inference worker for road image distress scoring (1–5). The durable queue, persisted detections, and severity score passed on an external pothole validation image; the local starter detects potholes only, so broader-class coverage and Hyderabad-specific severity calibration remain model-improvement work.
  - [x] Deploy local **Qwen2.5-3B-Instruct** instance via vLLM. The optional GPU Compose profile runs Qwen2.5-3B-Instruct-AWQ with AWQ-Marlin on the local RTX 3050 (6 GB); the API's Pydantic-validated issue extraction and complaint drafting passed an end-to-end request.
  - [x] Build a structured, multilingual complaint draft generator; drafts require human review before filing.

### Phase 3: Flutter Mobile Client Development
* **Goal:** Complete mobile app with camera lock, interactive map, and passive verification.
* **Checklist:**
  - [x] Initialize Flutter app with Android/iOS platform projects, `maplibre_gl`, and `geolocator`.
  - [x] Build 1-Tap Camera reporting with the best available GPS fix, capture time, accuracy, and heading.
  - [x] Implement direct-to-S3 photo upload using signed URLs; live S3/CloudFront credentials are still required.
  - [x] Implement active-navigation location updates triggering a 50m geofence re-inspection modal: *"Still damaged?"*
  - [x] Build route navigation view with hazard pins and safer OSRM alternatives when available.

**Progress (2026-11-12):** The Flutter Android/iOS projects and application source are implemented. `flutter analyze` passes; Android debug APK and release AAB builds pass, including Flutter's final native-symbol check. A workspace-local Android command-line-tools package supplies `apkanalyzer`; the package SHA-256 matched Google's published checksum, and `.toolcache`/`.android-sdk` are Git-ignored. Navigation location updates now stop when navigation ends, disposed screens ignore callbacks, and hazard viewport API refreshes are throttled to 15 seconds while manual/map movement refreshes remain immediate. `flutter doctor` still reports unaccepted Android SDK component licenses, which were not accepted during this work. The debug APK uses `127.0.0.1:8001` for USB ADB reverse; the release build uses the generated debug signing key and a placeholder API URL, so it is not a Play-ready artifact. The connected Android phone is currently absent from ADB, so on-device launch and permission behavior remain unverified. Mobile API smoke checks pass for deduplicated reports and evidence galleries. Live photo upload still needs AWS S3/CloudFront configuration. The destination field accepts coordinates; geocoding/address search is not implemented.

- [ ] Complete on-device validation of camera, location permissions, active-navigation geofence, map, and route flow on Android and iOS.

### Phase 4: Production AWS Cloud Migration
* **Goal:** Scale system from local Docker Compose to resilient AWS microservices.
* **Checklist:**
  - [ ] Create AWS ECR repository and push production Docker images for FastAPI, OSRM, and background scrapers.
  - [ ] Provision Amazon RDS for PostgreSQL with PostGIS extension enabled.
  - [ ] Provision Amazon ElastiCache (Redis) multi-AZ cluster.
  - [ ] Deploy FastAPI and OSRM services on AWS ECS Fargate behind an Application Load Balancer (ALB).
  - [ ] Configure Amazon S3 bucket with strict CORS policies and AWS CloudFront CDN distribution.
  - [ ] Deploy Qwen2.5-3B-Instruct on AWS Bedrock or SageMaker Serverless.
  - [ ] Build mobile `.aab` package and release to Google Play Store Internal Testing track for on-road field validation.

**Progress (2026-11-12):** A Terraform foundation is in `infra/aws/` for ECR, ECS/Fargate API and workers, OSRM, RDS/PostGIS, ElastiCache, ALB, S3, and CloudFront. Formatting and validation pass. The full no-refresh plan proposes 48 resource additions, with no changes or destroys; a separate bootstrap plan proposes two ECR repositories and the evidence bucket. Neither plan was applied. Read-only inventory found no issued ACM certificate, Route 53 hosted zone, ECR repositories, or ECS clusters in `ap-south-1`; a domain and certificate are needed before the API can be deployed. Terraform now defaults ALB ingress to closed and prevents service deployment without a certificate, built images, and restricted CIDRs. PostgreSQL 16.15 and `db.t4g.medium` were confirmed available in the region. The configuration selects managed Bedrock Qwen3 32B because Amazon Bedrock does not list the local Qwen2.5-3B-AWQ checkpoint among hosted Qwen models. Model quality/cost validation and an account owner review of the proposed billable resources remain pending.
