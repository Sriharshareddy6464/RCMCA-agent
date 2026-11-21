\# Mission: Pixel-Accurate React + Vite + TailwindCSS Replica of RCMCA Flutter App



\## Objective

Build a responsive, production-ready web application in `03\_langgraph\_mcp/web/` using \*\*React 18 + TypeScript + Vite + TailwindCSS + MapLibre GL JS + Lucide React\*\* that is an \*\*exact visual, behavioral, and API-level replica\*\* of the existing Flutter mobile app in `03\_langgraph\_mcp/mobile/`.



\## Ground-Truth Source Files (Read Before Writing Any Code)

1\. \*\*Flutter UI \& State Source:\*\* Inspect every file under `03\_langgraph\_mcp/mobile/lib/` (specifically `lib/main.dart`, `lib/widgets/survey\_sheets.dart`, and any models/services/themes). Mirror the exact color palette, typography, spacing, border radii, dark/light theme tokens, bottom/side navigation structure, map marker styling, bottom sheets/drawers, compact driveway/route ETA cards, chat bubbles, route forwarding flows, and form inputs.

2\. \*\*Backend API \& Schema Source:\*\* Inspect `03\_langgraph\_mcp/backend/` routes/schemas so every request payload, query param, multipart upload field, and response parser matches 100%.

3\. \*\*Live Production API Base URL:\*\*

&#x20;  - Default `VITE\_API\_BASE\_URL=https://rcmca.adapalasriharshareddy.online` in `.env` and `.env.example` (CORS is already enabled on Caddy).

&#x20;  - Never hardcode `127.0.0.1:8001` in production builds; read `import.meta.env.VITE\_API\_BASE\_URL || "https://rcmca.adapalasriharshareddy.online"`.



\## Non-Negotiable Parity Rules

\- \*\*Visual \& UX Parity:\*\* Match the Flutter app's exact layout hierarchy, card elevation, glass/surface colors, severity badge colors, icon choices, micro-copy, and empty/loading/error states. Adapt mobile bottom sheets cleanly to desktop slide-over drawers / responsive bottom sheets on mobile viewports (`< 768px`).

\- \*\*Functional Parity:\*\*

&#x20; - Live MapLibre GL JS map centered on Hyderabad (`17.3850, 78.4867`) rendering nearby road issues from `GET /api/v1/issues/nearby`, severity/category filters, marker clustering/selection, and issue detail sheets (including `survey\_sheets.dart` verification/audit workflows).

&#x20; - OSRM safe-route \& normal-route comparison overlay (`POST /api/v1/routes/...` or equivalent endpoint used in `lib/main.dart`) with the compact driveway/route ETA card and hazard warning callouts.

&#x20; - AI Road Intelligence Chat assistant (`POST /api/v1/chat`) supporting real route forwarding (clicking a suggested/forwarded route in chat immediately plots it on the map and switches/focuses the map view, matching the Flutter fix).

&#x20; - Citizen Hazard Reporting flow (`POST /api/v1/issues/report` multipart/JSON) with image upload/preview, GPS geolocation + interactive map pin drop, category/severity selectors, and immediate map refresh.

&#x20; - Manual/admin feed refresh action (`POST /api/v1/issues/refresh`) with rate-limit cooldown handling matching the backend v1.5 behavior.

\- \*\*Zero Stubs / Zero Mock Data:\*\* Every list, marker, route polyline, survey sheet, and chat reply must hit the live API.



\---



\## Multi-Agent Task Split (Execute Tracks 1–3 in Parallel, Then Track 4)



\### Agent 1 — Scaffold, Design System \& Typed API Layer (`web/src/lib/`, `web/src/types/`, `web/src/theme/`)

\*\*Scope:\*\*

1\. Initialize Vite + React + TypeScript + TailwindCSS inside `03\_langgraph\_mcp/web/` with `maplibre-gl` and `lucide-react`.

2\. Extract every hex color, gradient, shadow, font scale, corner radius, and severity color token from `03\_langgraph\_mcp/mobile/lib/` into `tailwind.config.ts` and `src/index.css`.

3\. Create `src/types/rcmca.ts` defining exact TypeScript interfaces for Issues, Nearby Responses, Route/ETA Responses, Survey Sheets, and Chat Messages/Actions based on `mobile/lib/` + `backend/`.

4\. Create `src/lib/api.ts` wrapping all endpoints (`health`, `issues/nearby`, `issues/report`, `issues/refresh`, routing endpoints, survey endpoints, and `chat`) using `VITE\_API\_BASE\_URL` with clean error handling and cooldown state tracking.

5\. Configure `.env` (`VITE\_API\_BASE\_URL=https://rcmca.adapalasriharshareddy.online`) and `.env.example`.



\### Agent 2 — Interactive MapLibre Canvas, Route Polylines \& Compact ETA Overlay (`web/src/components/map/`)

\*\*Scope:\*\*

1\. Build `MapCanvas.tsx` using `maplibre-gl` with the exact map style, Hyderabad default viewport, user location puck, and custom HTML/SVG hazard pins matching `lib/main.dart` (color-coded by severity/status, active ring on selected marker).

2\. Render OSRM safe vs. standard route GeoJSON polylines with distinct stroke widths/colors matching the Flutter map layers.

3\. Replicate the floating top search/filter bar, map layer/refresh controls, and the \*\*compact driveway/route ETA card\*\* exactly as styled in `lib/main.dart`.

4\. Expose imperative/state hooks so clicking a marker opens the Issue Detail / Survey Sheet and receiving a forwarded route from Chat zooms to fit bounds and renders the ETA card.



\### Agent 3 — Survey Sheets, Hazard Report Modal \& AI Chat Assistant (`web/src/components/sheets/`, `chat/`, `report/`)

\*\*Scope:\*\*

1\. Replicate `lib/widgets/survey\_sheets.dart` into `SurveySheetDrawer.tsx` (responsive bottom sheet on mobile, right-side inspector drawer on desktop) with all verification questions, status pills, photo previews (resolving relative `/uploads/...` URLs against `VITE\_API\_BASE\_URL`), and submission actions.

2\. Replicate the Citizen Report flow in `ReportIssueModal.tsx` with drag-and-drop/camera image input, browser geolocation + click-on-map coordinate picker, category/severity chips, description field, and live API submission.

3\. Replicate the Road Intelligence Chat view in `ChatPanel.tsx` wired to `POST /api/v1/chat`, preserving quick-prompt chips, structured hazard cards in replies, and \*\*real route forwarding\*\* (`onForwardRoute`) that passes origin/destination/waypoints directly to Agent 2's map state.



\### Agent 4 — App Shell Integration, Navigation Parity \& End-to-End Verification (`web/src/App.tsx`, `web/package.json`)

\*\*Scope:\*\*

1\. Wire Agents 1, 2, and 3 together in `App.tsx` mirroring the exact tab/navigation architecture and state transitions from `lib/main.dart`.

2\. Ensure full responsiveness across desktop (`1440x900`) and mobile (`390x844`) viewports without layout overflow or clipped sheets.

3\. Run `npm run build` in `03\_langgraph\_mcp/web/` to verify zero TypeScript or Vite bundling errors.

4\. Start the dev server and smoke-test live calls against `https://rcmca.adapalasriharshareddy.online` (`/health`, `/api/v1/issues/nearby`, `/api/v1/chat`, and image asset loading).

