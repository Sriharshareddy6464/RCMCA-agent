# Foundation contract

This contract is grounded in the inspected Flutter sources and backend routes/schemas. Flutter/backend win over the mission brief when they differ. Live GET samples were captured from `https://rcmca.adapalasriharshareddy.online` on 2026-11-21 (UTC); samples contain real production response bodies.

## Endpoint inventory and reconciliation

| Operation | Method and path | Flutter usage | Request / response | Live sample |
|---|---|---|---|---|
| Health | `GET /health` | No current Flutter call | `HealthResponse` | [health.json](./samples/health.json) |
| Viewport issues | `GET /api/v1/issues?south&west&north&east&limit` | `main.dart` `_loadHazards` | Bare `Issue[]`, active issues inside bounds | [issues-list.json](./samples/issues-list.json) |
| Issue detail | `GET /api/v1/issues/{issue_id}` | `issue_detail_sheet.dart` detail sheet uses issue data passed from map; does not fetch this URL | `Issue` | [issue-detail.json](./samples/issue-detail.json) |
| Vision status | `GET /api/v1/issues/{issue_id}/vision/{assessment_id}` | No current Flutter call | vision assessment status | [vision-status-not-found.json](./samples/vision-status-not-found.json) (valid 404 sample) |
| Assess issue | `POST /api/v1/issues/assess` | No current Flutter call | `IssueAssessmentRequest` → assessment/draft fields | Not called in Phase 0 |
| Report issue | `POST /api/v1/issues/report` | survey and pinned-map reporting | JSON `ReportIssuePayload` → `{issue, deduplicated, deduplication_radius_m}`; Flutter requires HTTP 201 | Not called in Phase 0 |
| Verify by issue path | `POST /api/v1/issues/{issue_id}/verify` | `survey_sheets.dart` | `{user_id, still_present, condition_score?, impact_mcq?}` → `VerificationResponse` | Not called in Phase 0 |
| Verify legacy body | `POST /api/v1/issues/verify` | No current Flutter call | Same survey fields plus required `issue_id` | Not called in Phase 0 |
| Refresh issue feeds | `POST /api/v1/issues/refresh` | `main.dart` refresh control | Empty JSON body → `{imported,total_issues}`; optional `X-Refresh-Token`; backend returns cached counts during its unauthenticated 60-second cooldown | Not called in Phase 0 |
| Plan route | `POST /api/v1/routes/plan` | `main.dart` route planner | `{origin,destination}` strings, `[lon,lat]`, or legacy coordinate objects → route audit and alternatives | Not called in Phase 0 |
| Chat | `POST /api/v1/chat` | `chat_screen.dart` | `{message,user_lat?,user_lon?}` → route, issue/email, or other intent shape | Not called in Phase 0 |
| Local image upload | `POST /api/v1/uploads/local` | `survey_sheets.dart` | multipart `files`, up to 4 JPEG/PNG/WebP files of at most 8 MiB each → `{image_urls,count}` | Not called in Phase 0 |
| Presign image upload | `POST /api/v1/uploads/presign` | No current Flutter call | JSON `{content_type,file_name}` → presigned PUT metadata | Not called in Phase 0 |
| Image vision assessment | `POST /api/v1/issues/{issue_id}/vision` | No current Flutter call | multipart field `image`, max 10 MiB → HTTP 202 pending assessment | Not called in Phase 0 |

### Brief, Flutter, backend, and live differences

- Mission brief says nearby data comes from `GET /api/v1/issues/nearby`; backend exposes viewport `GET /api/v1/issues` and Flutter calls that. A read-only GET of the brief path returned HTTP 422 because FastAPI matches `nearby` against the `{issue_id}` route and rejects its UUID. See [brief-nearby-mismatch.json](./samples/brief-nearby-mismatch.json).
- Mission brief suggests report multipart/JSON; actual Flutter first sends photos as multipart `files` to `/api/v1/uploads/local`, then submits issue metadata as JSON to `/api/v1/issues/report`.
- The route brief describes `/api/v1/routes/...`; Flutter and backend use `/api/v1/routes/plan`.
- `backend/app/schemas.py` defines generic coordinate `RoutePlanRequest` / `RoutePlanResponse`; the actual mounted route accepts the richer `RouteRequest` and returns `routes`, recommended route fields, and hazard details. The active route implementation is authoritative.
- Backend includes both `routing_router` and `chat_router` in `main.py`, while `routing.py` also includes `chat_router`; path behavior is the same. Chat accepts exact request fields and returns `recommended_route_id`, `recommended_route_geojson`, and `deep_link` for route intent.
- `IssueResponse` includes nullable `source_url`, `ward_name`, authority fields, status color, evidence, and image URL arrays. The live list sample matches this shape. List result is a bare array, not a wrapper.
- Refresh backend v1.5 does not currently return HTTP 429 or a retry header during cooldown; it returns cached counts as HTTP 200. The API layer includes `RefreshCooldownError` for deployments that expose 429 and a 60-second helper to let the shell track the server cooldown. No production POST was sent.
- Flutter has a legacy loopback base URL, but web always uses `VITE_API_BASE_URL` or the production default specified in `src/lib/api.ts`.

## Types index

Defined in `src/types/rcmca.ts`:

- Issue model: `Issue`, `EvidenceImage`, `Category`, `Severity`, `Status`, `StatusColor`, `VoteType`, `NearbyIssuesResponse`.
- Location and geometry: `LatLng`, `Coordinate`, `GeoJSONPoint`, `GeoJSONLineString`, `GeoJSONGeometry`, `ResolvedPlace`.
- Routes/ETA: `RouteEndpoint`, `RoutePlanRequest`, `RouteIssue`, `RouteCandidate`, `RouteHazard`, `RoutePlan`, `RouteEta`.
- Survey: `SurveyAnswer`, `SurveyQuestion`, `SurveySheet`, `VerificationSubmission`, `VerificationResponse`.
- Report and assessment: `ReportIssuePayload`, `ReportIssueResponse`, `IssueAssessmentRequest`, `IssueAssessmentResponse`.
- Chat: `ChatRequest`, `ChatResponse`, `ChatAction`, `ChatRouteAction`, `ChatIssue`, `DraftEmail`.
- Component coordination: `ViewportBounds`, `ViewportChange`, `RoutePlannerInput`, and `DrivewayState` in `src/types/contracts.ts`.
- Remaining endpoints: `RefreshResponse`, `HealthResponse`, upload/presign types, and vision accepted/status types.

## API layer

`src/lib/api.ts` exports a typed function for every backend operation and `ApiError`, `RefreshCooldownError`, `refreshCooldownSeconds`, and `resolveAssetUrl`. Multipart upload functions append exact backend field names and let `fetch` set the multipart boundary. Relative `/uploads/...` assets resolve against the configured API base URL.

No POST endpoint was invoked on production. Request and response types were derived from backend Pydantic models, the mounted route implementations, and Flutter request builders. The live list/detail samples agree with `IssueResponse`.

## Component contracts

`src/types/contracts.ts` is the shared component boundary:

- `MapCanvasProps` carries issues, selection, filters, route, location, refresh state, viewport callbacks, optional route-planner input/change/submit callbacks, and optional `DrivewayState`. `ViewportChange.bounds` carries exact south/west/north/east bounds when emitted; map rendering is presentational and the shell owns fetching, filters, selection, active route, and cooldown.
- `SearchFilterBarProps` has the same optional controlled origin/destination values and route-plan callback so the map planner can remain presentational. The callback submits the backend `RoutePlanRequest` to the shell.
- `RouteEtaCardProps` receives optional `DrivewayState` and optional start/exit callbacks; `MapControlsProps` can expose an exit callback while driveway mode is active. Navigation remains shell-owned.
- `MapCanvasHandle` provides `flyTo(point, zoom?)` and `fitRoute()`.
- `SurveySheetDrawerProps` optionally receives `userLocation` so the shell can provide Flutter's verification-distance context. `IssueDetailSheetProps`, `ReportIssueModalProps`, and `LocationPickerProps` are controlled props.
- `ChatPanelProps` receives current location and exposes route-forward and issue-selection callbacks. Chat does not import map.
- `ForwardedRoute` aliases Flutter's actual `ChatRoutePlan` payload (`routeId`, label, ETA, GeoJSON, route issues, alternatives). `ChatPanelProps.onForwardRoute` already carries it. The shell converts that payload to active route state from its existing geometry and metadata; this handoff does not call `/routes/plan` again.
- `ReportIssueModalProps.locationMode` is optional and defaults to `gps`; `map_pin` opens the modal's internal MapLibre `LocationPicker`. The report entry is the shell's Report tab; v1 has no report-from-main-map shortcut.
- `IssueFilters` is already controlled by props. Flutter's map has an informational status legend but no category/status/severity filter UI; do not present the existing web filter shape as a Flutter behavior.
- `IssueDetailSheetProps.issue` provides the selected `Issue`; the detail sheet does not fetch `GET /api/v1/issues/{id}`.
- `ResponsiveSheet` is a bottom sheet below 768 px and right drawer at/above 768 px, with Escape close, body scroll lock, and focus trapping.

Skeleton component exports live at every requested path and render exactly a `data-skeleton` div. No feature UI or mock data is included.

## Map contract

`src/lib/mapStyle.ts` exports Flutter's OpenFreeMap Liberty style URL, Hyderabad center `[78.4867, 17.385]` in MapLibre longitude/latitude order, and zoom `12.3`. Flutter route overlays use recommended `#00BCD4` (width 6.5) and rejected `#94A3B8` (dashed width 4); the style tokens are in `src/theme/tokens.ts` where appropriate.

## Token index

`src/theme/tokens.ts`, `src/index.css`, and `tailwind.config.ts` contain:

- Material 3 teal seed `#00838F`, dark teal `#004D40`, route cyan and alternative gray.
- Five map status colors and the separate condition-rating palette from the survey UI.
- Separate issue-detail status pill colors from `issue_detail_sheet.dart` (its palette differs from map marker status colors).
- Explicit slate and route warning/success colors used in Flutter widgets.
- Flutter card shadow/elevation approximation, radii (4/9/10/12/14/16/20/24 px), spacing (4/8/12/14/16/18/20/24 px), and visible typography sizes.
- Roboto, matching Flutter Material's default font family. Flutter does not declare a gradient or a dark theme; the web is light-only regardless of OS appearance.

Every explicit token comment includes the Flutter source location. Token entries from Flutter's framework-generated Material 3 defaults cite the seed declaration.

## Decisions

- **D1 Theme:** light-only. Flutter has no `darkTheme` or `themeMode` and renders light regardless of OS appearance.
- **D2 Chat → map:** forward the exact Flutter `ChatRoutePlan` object (geometry and metadata). The Flutter app is not modified.
- **D3 Report:** default to GPS auto-lock as in Flutter. The internal `LocationPicker` is the “pin on map” option. There is no report-from-main-map shortcut in v1.
- **D4 Production data:** production demo data is read-only until Phase 2.

## Per-step notes

- **(a) Chat route handoff:** forwarded routes already carry geometry. The shell converts `ForwardedRoute` to active `RoutePlan` state without a second API call. `POST /api/v1/routes/plan` is only for the Flutter route-planner input.
- **(b) Refresh cooldown:** the endpoint returns HTTP 200 with cached counts during its 60-second cooldown. The shell tracks cooldown client-side via `refreshCooldownSeconds`.
- **(c) Issue detail:** `IssueDetailSheet` uses the `Issue` object passed in; it does not call `GET /api/v1/issues/{id}`.
- **(d) Report:** call `POST /api/v1/uploads/local` with multipart `files` (max 4 files, 8 MiB each, JPEG/PNG/WebP), then call `POST /api/v1/issues/report` with JSON and expect HTTP 201. Production writes remain prohibited until Phase 2.
- **(e) Viewport:** fetch with `GET /api/v1/issues?south=...&west=...&north=...&east=...&limit=...`.

The production issue detail sample returned HTTP 200. The vision status sample used an unknown UUID and returned its real 404 shape.
