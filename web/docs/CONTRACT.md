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
- Remaining endpoints: `RefreshResponse`, `HealthResponse`, upload/presign types, and vision accepted/status types.

## API layer

`src/lib/api.ts` exports a typed function for every backend operation and `ApiError`, `RefreshCooldownError`, `refreshCooldownSeconds`, and `resolveAssetUrl`. Multipart upload functions append exact backend field names and let `fetch` set the multipart boundary. Relative `/uploads/...` assets resolve against the configured API base URL.

No POST endpoint was invoked on production. Request and response types were derived from backend Pydantic models, the mounted route implementations, and Flutter request builders. The live list/detail samples agree with `IssueResponse`.

## Component contracts

`src/types/contracts.ts` is the shared component boundary:

- `MapCanvasProps` carries issues, selection, filters, route, location, refresh state, and callbacks. Map rendering is presentational; shell owns fetching, filters, selection, active route, and cooldown.
- `MapCanvasHandle` provides `flyTo(point, zoom?)` and `fitRoute()`.
- `SurveySheetDrawerProps`, `IssueDetailSheetProps`, `ReportIssueModalProps`, and `LocationPickerProps` are controlled props.
- `ChatPanelProps` receives current location and exposes route-forward and issue-selection callbacks. Chat does not import map.
- `ForwardedRoute` aliases Flutter's actual `ChatRoutePlan` payload (`routeId`, label, ETA, GeoJSON, route issues, alternatives). The requested shorthand origin/destination/waypoints/labels is not the object Flutter currently hands off; the chat callback in `main.dart` forwards route metadata and geometry only.
- The report modal owns its self-contained MapLibre location picker using `src/lib/mapStyle.ts`; Flutter's primary flow auto-locks device GPS, and the pinned-map shortcut receives a point selected from the main map. This web contract keeps the requested contained picker.
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
- Roboto, matching Flutter Material's default font family. Flutter does not declare a gradient or a custom dark theme. `data-theme="dark"` uses browser system semantic surface/text roles while retaining explicit Flutter accent colors; exact dark Material roles remain framework-derived, not source literals.

Every explicit token comment includes the Flutter source location. Token entries from Flutter's framework-generated Material 3 defaults cite the seed declaration.

## Open questions

1. Flutter has no explicit `darkTheme`; should the web version use system color scheme roles as the CSS currently does, or should a later theme task introduce a dark Material 3 palette?
2. Flutter's actual chat-to-map payload omits origin/destination names and waypoints; should a future Flutter change add those fields, or should web continue forwarding the exact route geometry/metadata object?
3. Flutter offers both GPS auto-lock reporting and a main-map pinned-report shortcut. The report modal contract requires an internal location picker; confirm whether that should be the default report path in the web shell.
4. The production GET samples include a real demo issue. The production issue detail endpoint returned the sample issue successfully; the vision status endpoint was sampled with an unknown UUID and returned its real 404 shape.
