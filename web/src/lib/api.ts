import type {
  ChatRequest,
  ChatResponse,
  HealthResponse,
  Issue,
  IssueAssessmentRequest,
  IssueAssessmentResponse,
  NearbyIssuesResponse,
  PresignRequest,
  PresignResponse,
  RefreshResponse,
  ReportIssuePayload,
  ReportIssueResponse,
  RoutePlan,
  RoutePlanRequest,
  UploadLocalResponse,
  VerificationResponse,
  VerificationSubmission,
  VisionAssessmentAccepted,
  VisionAssessmentStatus,
} from '../types/rcmca'

export const API_BASE_URL = (
  import.meta.env.VITE_API_BASE_URL || 'https://rcmca.adapalasriharshareddy.online'
).replace(/\/$/, '')

export class ApiError extends Error {
  readonly status: number
  readonly payload: unknown

  constructor(message: string, status: number, payload: unknown) {
    super(message)
    this.name = 'ApiError'
    this.status = status
    this.payload = payload
  }
}

export class RefreshCooldownError extends ApiError {
  readonly retryAfterSeconds: number

  constructor(retryAfterSeconds: number, payload?: unknown) {
    super(`Issue refresh is cooling down. Try again in ${retryAfterSeconds} seconds.`, 429, payload)
    this.name = 'RefreshCooldownError'
    this.retryAfterSeconds = retryAfterSeconds
  }
}

/** Backend v1.5 caches refresh counts for 60 seconds; a 429 is handled if a deployment emits one. */
export function refreshCooldownSeconds(lastRefreshAt: number | null, now = Date.now()): number {
  if (lastRefreshAt === null) return 0
  return Math.max(0, Math.ceil((lastRefreshAt + 60_000 - now) / 1000))
}

export function resolveAssetUrl(path: string | null | undefined): string | null {
  if (!path) return null
  try {
    return new URL(path, `${API_BASE_URL}/`).toString()
  } catch {
    return null
  }
}

async function parseResponse<T>(response: Response): Promise<T> {
  const raw = await response.text()
  let payload: unknown = null
  if (raw) {
    try { payload = JSON.parse(raw) as unknown } catch { payload = raw }
  }
  if (!response.ok) {
    if (response.status === 429 && response.url.includes('/api/v1/issues/refresh')) {
      const header = response.headers.get('Retry-After')
      const retryAfterSeconds = header && Number.isFinite(Number(header)) ? Number(header) : 60
      throw new RefreshCooldownError(retryAfterSeconds, payload)
    }
    const detail = typeof payload === 'object' && payload !== null && 'detail' in payload
      ? String((payload as { detail: unknown }).detail)
      : response.statusText || 'Request failed'
    throw new ApiError(detail, response.status, payload)
  }
  return payload as T
}

async function get<T>(path: string): Promise<T> {
  return parseResponse<T>(await fetch(`${API_BASE_URL}${path}`, { headers: { Accept: 'application/json' } }))
}

async function json<T>(path: string, method: 'POST', body: unknown): Promise<T> {
  return parseResponse<T>(await fetch(`${API_BASE_URL}${path}`, {
    method,
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  }))
}

export const getHealth = (): Promise<HealthResponse> => get('/health')

export function getIssues(bounds: { south: number; west: number; north: number; east: number; limit?: number }): Promise<NearbyIssuesResponse> {
  const query = new URLSearchParams({
    south: String(bounds.south), west: String(bounds.west),
    north: String(bounds.north), east: String(bounds.east),
    limit: String(bounds.limit ?? 500),
  })
  return get(`/api/v1/issues?${query}`)
}

export const getIssue = (issueId: string): Promise<Issue> =>
  get(`/api/v1/issues/${encodeURIComponent(issueId)}`)

export const reportIssue = (payload: ReportIssuePayload): Promise<ReportIssueResponse> =>
  json('/api/v1/issues/report', 'POST', payload)

export async function refreshIssues(): Promise<RefreshResponse> {
  return parseResponse<RefreshResponse>(await fetch(`${API_BASE_URL}/api/v1/issues/refresh`, {
    method: 'POST',
    headers: { Accept: 'application/json' },
  }))
}

export const planRoute = (payload: RoutePlanRequest): Promise<RoutePlan> =>
  json('/api/v1/routes/plan', 'POST', payload)

export const sendChatMessage = (payload: ChatRequest): Promise<ChatResponse> =>
  json('/api/v1/chat', 'POST', payload)

export const verifyIssue = (issueId: string, payload: VerificationSubmission): Promise<VerificationResponse> =>
  json(`/api/v1/issues/${encodeURIComponent(issueId)}/verify`, 'POST', payload)

export const verifyIssueById = (payload: VerificationSubmission & { issue_id: string }): Promise<VerificationResponse> =>
  json('/api/v1/issues/verify', 'POST', payload)

export const assessIssue = (payload: IssueAssessmentRequest): Promise<IssueAssessmentResponse> =>
  json('/api/v1/issues/assess', 'POST', payload)

export async function uploadLocal(files: File[]): Promise<UploadLocalResponse> {
  const form = new FormData()
  for (const file of files) form.append('files', file, file.name)
  return parseResponse<UploadLocalResponse>(await fetch(`${API_BASE_URL}/api/v1/uploads/local`, {
    method: 'POST',
    headers: { Accept: 'application/json' },
    body: form,
  }))
}

export const presignUpload = (payload: PresignRequest): Promise<PresignResponse> =>
  json('/api/v1/uploads/presign', 'POST', payload)

export async function uploadVisionImage(issueId: string, image: File): Promise<VisionAssessmentAccepted> {
  const form = new FormData()
  form.append('image', image, image.name)
  return parseResponse<VisionAssessmentAccepted>(await fetch(
    `${API_BASE_URL}/api/v1/issues/${encodeURIComponent(issueId)}/vision`,
    { method: 'POST', headers: { Accept: 'application/json' }, body: form },
  ))
}

export const getVisionAssessment = (issueId: string, assessmentId: string): Promise<VisionAssessmentStatus> =>
  get(`/api/v1/issues/${encodeURIComponent(issueId)}/vision/${encodeURIComponent(assessmentId)}`)
