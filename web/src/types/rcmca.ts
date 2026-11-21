export type Severity = 1 | 2 | 3 | 4 | 5
export type Category =
  | 'pothole'
  | 'waterlogging'
  | 'damaged_surface'
  | 'open_manhole'
  | 'broken_divider'
  | 'other'
export type Status = 'community_pending' | 'verified_ghmc' | 'active_hazard' | 'resolved'
export type StatusColor = 'GREEN' | 'BLUE' | 'YELLOW' | 'ORANGE' | 'RED'
export type VoteType = 'CONFIRM' | 'RESOLVED'

export interface LatLng { latitude: number; longitude: number }
export interface Coordinate { longitude: number; latitude: number }
export interface GeoJSONPoint { type: 'Point'; coordinates: [number, number] }
export interface GeoJSONLineString { type: 'LineString'; coordinates: [number, number][] }
export type GeoJSONGeometry = GeoJSONPoint | GeoJSONLineString

export interface EvidenceImage {
  id: string
  image_url: string
  latitude: number
  longitude: number
  accuracy_m: number | null
  heading_degrees: number | null
  captured_at: string
  created_at: string
}

/** Matches IssueResponse and the live GET /api/v1/issues sample. */
export interface Issue {
  id: string
  category: Category
  severity: Severity
  confidence_score: number
  report_count: number
  description: string
  evidence_image_url: string | null
  latitude: number
  longitude: number
  source: string
  source_url: string | null
  external_ticket_id: string | null
  status: Status
  created_at: string
  updated_at: string
  evidence: EvidenceImage[]
  corporation: string | null
  zone: string | null
  ward_no: number | null
  ward_name: string | null
  authority_designation: string | null
  authority_email: string | null
  status_color: StatusColor | null
  impact_mcq: string | null
  image_urls: string[]
}

/** GET /api/v1/issues returns a bare Issue[] (not a nearby wrapper). */
export type NearbyIssuesResponse = Issue[]

export interface ResolvedPlace extends LatLng {
  longitude: number
  latitude: number
  display_name?: string
  corporation?: string | null
  zone?: string | null
  ward_name?: string | null
  resolution?: string
}

export type RouteEndpoint = string | [longitude: number, latitude: number] | LatLng
export interface RoutePlanRequest { origin: RouteEndpoint; destination: RouteEndpoint }

export interface RouteIssue {
  id: string
  title: string
  status_color: StatusColor
  ward_name: string | null
  corporation: string | null
  category: Category
  severity: Severity
  status: Status
  latitude: number
  longitude: number
  geometry: GeoJSONPoint
  distance_from_route_m: number
}

export interface RouteCandidate {
  route_id: string
  label: string
  is_recommended: boolean
  distance_km: number
  duration_min: number
  issues_on_route: RouteIssue[]
  geometry: GeoJSONLineString
}

export interface RouteHazard {
  id: string
  category: Category
  severity: Severity
  status: Status
  description: string
  distance_from_route_m: number
  latitude: number
  longitude: number
}

/** POST /api/v1/routes/plan response (routing.py); mobile displays the same ETA fields. */
export interface RoutePlan {
  origin: ResolvedPlace
  destination: ResolvedPlace
  alternatives_considered: number
  recommended_route_id: string
  routes: RouteCandidate[]
  routing_source: 'osrm' | 'fallback_geometry' | string
  geometry: GeoJSONLineString
  distance_m: number
  duration_s: number
  avoided_severe_hazards: boolean
  hazards: RouteHazard[]
}

/** Route comparison presents the recommended clean/safe option against the remaining normal alternatives. */
export interface RouteComparison {
  recommended: RouteCandidate
  alternatives: RouteCandidate[]
  warnings: RouteIssue[]
}

export interface RouteEta {
  distance_km: number
  duration_min: number
  eta_at?: string
}

export type SurveyAnswer = boolean | Severity | string
export interface SurveyQuestion {
  id: string
  prompt: string
  kind: 'yes_no' | 'condition_rating' | 'impact_choice'
  options?: readonly string[]
}
export type SurveySheet = 'presence' | 'quality' | 'impact' | 'evidence'

/** Exact Flutter prompts in mobile/lib/widgets/survey_sheets.dart:57-133. */
export const SURVEY_QUESTIONS: Record<Exclude<SurveySheet, 'evidence'>, readonly SurveyQuestion[]> = {
  presence: [
    'Is the road damage visible right now?',
    'Is the hazard still at the map pin location?',
    'Is the surface broken, loose, or uneven?',
    'Does water collect or drain poorly here?',
    'Is the affected area wider than a dinner plate?',
    'Do vehicles slow down or swerve to avoid it?',
    'Is the footpath or roadside drain affected?',
    'Is the hazard hard to see after dark?',
    'Has the damage worsened since the last report?',
    'Would a fresh report still help the ward engineer?',
  ].map((prompt, index) => ({ id: `presence-${index + 1}`, prompt, kind: 'yes_no' as const })),
  quality: [
    'Overall surface quality of this stretch',
    'Ride smoothness for two-wheelers',
    'Pothole or crater severity',
    'Loose gravel or debris on the carriageway',
    'Waterlogging and drainage',
    'Road edge and shoulder condition',
    'Visibility of lane markings',
    'Night-time safety for commuters',
    'Footpath and pedestrian safety',
    'Urgency of the repair',
  ].map((prompt, index) => ({ id: `quality-${index + 1}`, prompt, kind: 'condition_rating' as const })),
  impact: [
    { prompt: 'What is the main problem at this spot?', options: ['Traffic Bottleneck', 'Waterlogging / Sewage', 'Pothole / Crater', 'Footpath / Debris', 'Ecosystem Hazard'] },
    { prompt: 'How much of the road is affected?', options: ['One spot', 'Part of a lane', 'A full lane', 'Multiple lanes'] },
    { prompt: 'Who is most affected?', options: ['Two-wheelers', 'Cars', 'Pedestrians', 'Heavy vehicles'] },
    { prompt: 'When is it worst?', options: ['Peak hours', 'After dark', 'During rain', 'All day'] },
    { prompt: 'How long has it been here?', options: ['Under a week', '1-4 weeks', '1-6 months', 'Over 6 months'] },
    { prompt: 'Have there been injuries or near misses?', options: ['None seen', 'Near misses', 'Minor injuries', 'Serious injuries'] },
    { prompt: 'What happens during rain?', options: ['Nothing notable', 'Water pools', 'Surface washes away', 'Drain overflows'] },
    { prompt: 'Is traffic diverted?', options: ['No diversion', 'Partial diversion', 'Full diversion', 'Road closed'] },
    { prompt: 'What repair is needed?', options: ['Patch repair', 'Full resurfacing', 'Drain cleaning', 'Signage or barriers'] },
    { prompt: 'How urgent is the repair?', options: ['Routine', 'Within a month', 'Within a week', 'Immediate'] },
  ].map((question, index) => ({ id: `impact-${index + 1}`, ...question, kind: 'impact_choice' as const })),
}

export interface VerificationSubmission {
  user_id: string
  still_present: boolean
  condition_score?: Severity
  impact_mcq?: string
}
export interface VerificationResponse {
  issue_id: string
  confidence_score: number
  status: Status
  vote_recorded: boolean
  still_present: boolean | null
  condition_score: Severity | null
  impact_mcq: string | null
  severity: Severity | null
  status_color: StatusColor | null
}

/** JSON body accepted by POST /api/v1/issues/report. Photos are uploaded first. */
export interface ReportIssuePayload {
  category: Category
  description: string
  latitude: number
  longitude: number
  severity?: Severity
  evidence_image_url?: string | null
  capture_accuracy_m?: number | null
  capture_heading_degrees?: number | null
  captured_at?: string | null
  still_present?: true
  condition_score?: Severity | null
  impact_mcq?: string | null
  image_urls?: string[]
}
export interface ReportIssueResponse { issue: Issue; deduplicated: boolean; deduplication_radius_m: number }

export interface IssueAssessmentRequest {
  description: string
  latitude?: number | null
  longitude?: number | null
  near_sensitive_site?: boolean
  language?: 'en' | 'te' | 'hi'
}
export interface IssueFacts {
  category: Category
  severity: Severity
  concise_description: string
  uncertainty: string
}
export interface IssueAssessmentResponse {
  issue: IssueFacts
  priority_score: number
  dispatch_tier: 'HIGH' | 'MEDIUM' | 'LOW'
  action_required: string
  complaint_subject: string
  complaint_draft: string
}

export interface ChatRequest { message: string; user_lat?: number | null; user_lon?: number | null }
export interface DraftEmail { to: string; subject: string; body: string }
export interface ChatIssue extends Partial<Issue> { id: string; category: Category }
export interface ChatRouteAction {
  routeId: string
  label: string
  distanceKm: number
  durationMin: number
  geometry: GeoJSONLineString
  issuesOnRoute: RouteIssue[]
  routes: RouteCandidate[]
}
export interface ChatResponse {
  intent: 'route' | 'issue' | 'other' | string
  message: string
  plans_evaluated?: number
  routes?: RouteCandidate[]
  recommended_route_id?: string
  recommended_route_geojson?: GeoJSONLineString
  deep_link?: string
  issue?: ChatIssue
  draft_email?: DraftEmail
}

export type ChatAction =
  | { type: 'forward_route'; route: ChatRouteAction }
  | { type: 'select_issue'; issue_id: string }
  | { type: 'draft_email'; draft: DraftEmail }

export interface RefreshResponse { imported: number; total_issues: number }
export interface HealthResponse { status: string }
export interface UploadLocalResponse { image_urls: string[]; count: number }
export interface PresignRequest { content_type: string; file_name: string }
export interface PresignResponse {
  upload_url: string
  method: 'PUT'
  headers: Record<string, string>
  object_key: string
  evidence_image_url: string
  expires_in_seconds: number
}
export interface VisionAssessmentAccepted {
  assessment_id: string
  issue_id: string
  status: 'pending'
  message: string
}
export interface VisionAssessmentStatus {
  id: string
  issue_id: string
  status: string
  model_name: string | null
  severity_estimate: number | null
  detections: unknown[] | Record<string, unknown> | null
  error: string | null
  created_at: string
  updated_at: string
}
