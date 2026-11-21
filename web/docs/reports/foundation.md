# Foundation handoff

## Created

- Vite + React 18 + TypeScript + Tailwind scaffold, exact dependency pins, and npm lockfile.
- Flutter-referenced light/dark CSS variables, Tailwind theme entries, token export, and the Material Roboto font.
- Typed RCMCA endpoint models, API wrappers, map-style defaults, responsive UI primitives, component contracts, and all requested skeleton components.
- Endpoint inventory, API mismatch notes, live GET response samples, exact agent rules, and foundation contract.

## Exports and props

- `src/lib/api.ts`: typed wrapper for each backend route; `ApiError`, `RefreshCooldownError`, `refreshCooldownSeconds`, `resolveAssetUrl`.
- `src/lib/mapStyle.ts`: `MAP_STYLE_URL`, `DEFAULT_MAP_CENTER`, `DEFAULT_MAP_ZOOM`, `DEFAULT_MAP_VIEW`.
- `src/theme/tokens.ts`: exported `tokens` and `IssueStatusColor`.
- `src/components/ui`: `ResponsiveSheet`, `SeverityBadge`, `StatusPill`, `useIsMobile`.
- Contracts and props are in `src/types/contracts.ts`; model/request/response interfaces are in `src/types/rcmca.ts`.
- Skeletons export default components at all requested component paths; `MapCanvas` uses `forwardRef` with `MapCanvasHandle`.

## Flutter differences and open questions

- Flutter has no explicit dark theme or gradient literals. CSS keeps explicit accent colors and uses browser semantic roles for dark surfaces.
- Flutter's chat route handoff forwards route ID, label, ETA, GeoJSON, issues, and candidate routes; it does not forward origin/destination/waypoints/labels as a separate object.
- The web report contract keeps an internal location picker as requested, while Flutter uses auto-locked GPS for the full report and a pin chosen from the main map for its shortcut.
- The actual nearby endpoint is `GET /api/v1/issues`, not `/api/v1/issues/nearby`; see `docs/CONTRACT.md`.

## Requests

None.
