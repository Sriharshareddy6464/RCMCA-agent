import type { ReactNode } from 'react'
import type {
  ChatRouteAction,
  Category,
  Issue,
  LatLng,
  RoutePlan,
  RoutePlanRequest,
  Severity,
  StatusColor,
} from './rcmca'

export interface ViewportChange {
  center: LatLng
  zoom: number
  radiusM: number
  /** Exact bounds used by GET /api/v1/issues; optional for existing viewport emitters. */
  bounds?: ViewportBounds
}

export interface ViewportBounds {
  south: number
  west: number
  north: number
  east: number
}

export interface RoutePlannerInput {
  origin: string
  destination: string
  planning?: boolean
}

export interface IssueFilters {
  categories: Category[]
  statusColors: StatusColor[]
  minimumSeverity: Severity | null
}

export interface RefreshState { loading: boolean; cooldownUntil: number | null }

/** Map is presentational: data fetching and filter state belong to the shell. */
export interface MapCanvasProps {
  issues: Issue[]
  selectedIssueId: string | null
  filters: IssueFilters
  route: RoutePlan | null
  userLocation: LatLng | null
  refresh: RefreshState
  onSelectIssue(id: string | null): void
  onViewportChange(viewport: ViewportChange): void
  onFiltersChange(filters: IssueFilters): void
  onRefresh(): void
  onLocate(): void
  onClearRoute(): void
  /** Presentational route-planner controls; the shell makes the API request. */
  routePlanner?: RoutePlannerInput
  onRoutePlannerChange?(input: RoutePlannerInput): void
  onPlanRoute?(request: RoutePlanRequest): void
  onSwapRouteEndpoints?(): void
}

export interface MapCanvasHandle {
  flyTo(point: LatLng, zoom?: number): void
  fitRoute(): void
}

export interface SearchFilterBarProps {
  filters: IssueFilters
  onFiltersChange(filters: IssueFilters): void
  onRefresh(): void
  refresh: RefreshState
  /** Optional to preserve existing consumers; the shell owns the input state. */
  routePlanner?: RoutePlannerInput
  onRoutePlannerChange?(input: RoutePlannerInput): void
  onPlanRoute?(request: RoutePlanRequest): void
  onSwapRouteEndpoints?(): void
}

export interface MapControlsProps {
  onLocate(): void
  onClearRoute(): void
  hasRoute: boolean
}

export interface RouteEtaCardProps {
  route: RoutePlan | null
  onClearRoute(): void
}

export interface SurveySheetDrawerProps {
  issue: Issue | null
  open: boolean
  onClose(): void
  onIssueChanged(issue: Issue): void
}

export interface IssueDetailSheetProps {
  issue: Issue | null
  open: boolean
  onClose(): void
  onVerify(issue: Issue): void
}

export interface ReportIssueModalProps {
  open: boolean
  initialLocation: LatLng | null
  onClose(): void
  onSubmitted(issue: Issue): void
  /** Defaults to GPS auto-lock; map_pin opens the internal LocationPicker. */
  locationMode?: 'gps' | 'map_pin'
}

export interface LocationPickerProps {
  value: LatLng | null
  onChange(location: LatLng): void
}

/** Flutter hands ChatRoutePlan metadata, GeoJSON, hazards, and alternatives to its map callback. */
export type ForwardedRoute = ChatRouteAction

export interface ChatPanelProps {
  userLocation: LatLng | null
  onForwardRoute(route: ForwardedRoute): void
  onSelectIssue(id: string): void
}

export interface ResponsiveSheetProps {
  open: boolean
  onClose(): void
  children: ReactNode
  ariaLabel?: string
  className?: string
}
