# Foundation handoff

## Created

- Vite + React 18 + TypeScript + Tailwind scaffold, exact dependency pins, and npm lockfile.
- Flutter-referenced light-only CSS variables, Tailwind theme entries, token export, and the Material Roboto font.
- Typed RCMCA endpoint models, API wrappers, map-style defaults, responsive UI primitives, component contracts, and all requested skeleton components.
- Endpoint inventory, API mismatch notes, live GET response samples, exact agent rules, and foundation contract.

## Exports and props

- `src/lib/api.ts`: typed wrapper for each backend route; `ApiError`, `RefreshCooldownError`, `refreshCooldownSeconds`, `resolveAssetUrl`.
- `src/lib/mapStyle.ts`: `MAP_STYLE_URL`, `DEFAULT_MAP_CENTER`, `DEFAULT_MAP_ZOOM`, `DEFAULT_MAP_VIEW`.
- `src/theme/tokens.ts`: exported `tokens` and `IssueStatusColor`.
- `src/components/ui`: `ResponsiveSheet`, `SeverityBadge`, `StatusPill`, `useIsMobile`.
- Contracts and props are in `src/types/contracts.ts`; model/request/response interfaces are in `src/types/rcmca.ts`.
- Skeletons export default components at all requested component paths; `MapCanvas` uses `forwardRef` with `MapCanvasHandle`.

## Step 0b additive signature changes

Each change is additive; existing props, names, and exports remain intact. Skeleton component bodies still render only their `data-skeleton` div.

| File | Old signature | New signature | Flutter reason |
|---|---|---|---|
| `src/types/contracts.ts` — `ViewportChange` | `{ center: LatLng; zoom: number; radiusM: number }` | Same fields plus `bounds?: ViewportBounds` (`south`, `west`, `north`, `east`) | `mobile/lib/main.dart` reads the visible map region and requests `/api/v1/issues` with those four bounds. |
| `src/types/contracts.ts` — `MapCanvasProps` | Existing issue/selection/filter/route/location/refresh props and map callbacks | Same props plus optional `routePlanner`, `onRoutePlannerChange`, `onPlanRoute`, and `onSwapRouteEndpoints` | Flutter's map includes controlled A→B inputs, swap, planning state, and submits `/api/v1/routes/plan`; fetching remains shell-owned. |
| `src/types/contracts.ts` — driveway state | No live driveway presentation type | Adds `DrivewayState { active; remainingMeters; etaMinutes; bearingDegrees?; nearbyHazard? }`, optional on `MapCanvasProps` and `RouteEtaCardProps` | Flutter map updates vehicle/driveway state from live position, remaining distance, ETA, bearing, and nearby hazard. |
| `src/types/contracts.ts` — `SearchFilterBarProps` | `{ filters; onFiltersChange; onRefresh; refresh }` | Same fields plus optional `routePlanner`, `onRoutePlannerChange`, `onPlanRoute`, and `onSwapRouteEndpoints` | Provides the map's A→B route planner inputs and callbacks without putting API calls in the component. |
| `src/types/contracts.ts` — `RouteEtaCardProps` | `{ route; onClearRoute }` | Same fields plus optional `driveway`, `onStartDriveway`, and `onExitDriveway` | Flutter exposes route ETA and Driveway start/exit controls. |
| `src/types/contracts.ts` — `MapControlsProps` | `{ onLocate; onClearRoute; hasRoute }` | Same fields plus optional `drivewayActive` and `onExitDriveway` | Flutter exposes an exit action while in active driveway mode. |
| `src/types/contracts.ts` — `SurveySheetDrawerProps` | `{ issue; open; onClose; onIssueChanged }` | Same fields plus optional `userLocation?: LatLng | null` | Flutter checks verification distance against the citizen location and its 50 m geofence. |
| `src/types/contracts.ts` — `ReportIssueModalProps` | `{ open; initialLocation; onClose; onSubmitted }` | Same fields plus optional `locationMode?: 'gps' | 'map_pin'` (default `gps`) | Flutter auto-locks GPS for a report; this makes its internal map picker an explicit alternate mode. |

No direct skeleton component signature or body edits were needed: the skeletons consume the updated shared prop interfaces. `ChatPanelProps.onForwardRoute` already passes Flutter's exact `ChatRoutePlan` data. `RefreshState` already exposes loading/cooldown and `onRefresh`; shell uses `refreshCooldownSeconds`. `IssueDetailSheetProps.issue` already carries the selected issue.

Flutter's map shows a status legend but no filters. The existing `IssueFilters` contract is preserved without claiming that category/status/severity filtering exists in Flutter. The Report tab is the report entry point; no report-from-main-map callback is added under the v1 decision. App shell owns that tab state internally.

Flutter has no `darkTheme` or `themeMode`, and no gradient literals. Web CSS is now light-only. Flutter's chat route handoff forwards route ID, label, ETA, GeoJSON, issues, and candidate routes; it does not send separate origin/destination/waypoint labels. The actual nearby endpoint is `GET /api/v1/issues`, not `/api/v1/issues/nearby`; see `docs/CONTRACT.md`.

## Decisions

- D1: light-only, regardless of OS appearance.
- D2: forward exact ChatRoutePlan geometry and metadata; Flutter remains unchanged.
- D3: GPS auto-lock by default; the internal LocationPicker is the pin-on-map option; no map-origin report shortcut in v1.
- D4: production demo data stays read-only until Phase 2.

## Requests

None.

## Verification

- `npm ci && npm run build`: passed; Vite 8.3.8 emitted a production bundle.
- `npx tsc --noEmit`: passed with no diagnostics.
- `npm run dev -- --host 0.0.0.0`: Vite 8.3.8 ready in 1238 ms at `http://localhost:5173/`.
- Not visually verified at 1440x900 or 390x844: Chrome could not connect to `localhost:5173` (`ERR_CONNECTION_TIMED_OUT`) although Vite reported ready.
- All 12 requested skeleton paths exist.
- Production GET `/health`: HTTP 200, `{"status":"ok"}`. GET issue list and detail: HTTP 200. Vision status sample: HTTP 404 for the unknown test UUID. Brief-only `/api/v1/issues/nearby`: HTTP 422.
- No production POST requests were sent.
- Commits: `a89c10d`, `807bda3`, `1898c57`, `80a67c2`.
- The local checkout has no `web/integration` branch, so the exact `git diff --name-only web/integration...HEAD` handoff check cannot run. The committed foundation files are confined to `web/`; user reference-image renames/deletions remain unstaged.
- `npm ci` reports one high severity dependency audit finding. No audit fix was applied during foundation setup.

## Step 0c contract fixes

All changes below are additive; existing function exports and prop names/types remain intact.

| File | Old signature/content | New signature/content | Flutter reason |
|---|---|---|---|
| `src/types/contracts.ts` — `SurveySheetDrawerProps` | Optional `userLocation?: LatLng | null` only | Retains `userLocation` with a warning not to use it for geofencing; adds `distanceMeters?: number | null` | `survey_sheets.dart` uses null for pin taps and a measured distance from the 50 m proximity prompt. |
| `src/types/contracts.ts` — `MapCanvasProps` | `onRefresh(): void` | Adds optional `onReloadHazards?(): void`; preserves `onRefresh` | Flutter has a GET-only “Refresh hazards” icon and a separate POST “Scrape news & reload hazards” action. |
| `src/types/contracts.ts` — `SearchFilterBarProps` | `onRefresh(): void` | Adds optional `onReloadHazards?(): void`; preserves `onRefresh` | Keeps the two refresh actions distinguishable if surfaced in this bar. |
| `src/types/contracts.ts` — `ChatPanelProps` | Existing `onForwardRoute(route: ForwardedRoute): void` | Same signature with Flutter callback and web Start Driveway behavior documented | Flutter calls `onStartDriveway(ChatRoutePlan)`; web shows the plotted route and ETA before an explicit start action. |
| `src/lib/api.ts` | Requests had no explicit timeout | Adds 12 s for GET issue list, 15 s for POST refresh, and 30 s for every other request; a timeout becomes `ApiError('Request timed out', 408, null)` | Matches the route-specific mobile refresh window and bounds all API waits without changing exported signatures. |
| `docs/AGENT_RULES.md` — rule 5 | No cross-track component imports | Adds the forms ownership exception allowing `report/` to import shared survey-flow components from `sheets/survey/` | The survey flow is shared by report and verification surfaces. |
| `docs/CONTRACT.md` | Decisions D1–D4 and notes (a)–(e) | Adds verified D5–D9 and note (f) for GET reload vs POST refresh | Aligns the web contracts with Flutter's route handoff, geofence, report survey, refresh actions, and persistent IndexedStack tabs. |

D5–D9 were checked in `mobile/lib/main.dart`, `mobile/lib/widgets/survey_sheets.dart`, `mobile/lib/screens/chat_screen.dart`, and `mobile/lib/navigation_controller.dart`. The report flow includes the observed-description field as well as photos and GPS pin; its standard Report tab does not use the separate pinned-map category/severity shortcut, which is excluded by D3.
