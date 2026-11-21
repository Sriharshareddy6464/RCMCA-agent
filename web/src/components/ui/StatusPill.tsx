import type { Status, StatusColor } from '../../types/rcmca'

export interface StatusPillProps { status: Status | string; statusColor?: StatusColor | null; label?: string }

export function StatusPill({ status, statusColor, label }: StatusPillProps) {
  const color = statusColor?.toLowerCase() ?? status.toLowerCase().replaceAll('_', '-')
  return <span className={`status-pill status-${color}`}>{label ?? status.replaceAll('_', ' ')}</span>
}
