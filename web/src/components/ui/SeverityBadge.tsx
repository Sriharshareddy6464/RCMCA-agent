import type { Severity, StatusColor } from '../../types/rcmca'

export interface SeverityBadgeProps { severity: Severity | number; statusColor?: StatusColor | null; label?: string }

export function SeverityBadge({ severity, statusColor, label }: SeverityBadgeProps) {
  const score = Math.max(1, Math.min(5, Math.round(severity))) as Severity
  const className = statusColor
    ? `severity-${statusColor.toLowerCase()}`
    : `severity-score-${score}`
  return <span className={`severity-badge ${className}`}>{label ?? `Severity ${score}/5`}</span>
}
