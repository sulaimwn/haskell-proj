import { useQuery } from '@tanstack/react-query'
import { api } from '../api/client'
import type { DatabaseStatus } from '../api/generated'

// Shows whether the API and its database are up. Polls every 10 seconds.
export function HealthBadge() {
  const health = useQuery({
    queryKey: ['health'],
    queryFn: api.getHealth,
    refetchInterval: 10_000,
    retry: false,
  })

  if (health.isPending) {
    return <span className="badge badge-neutral">Checking API…</span>
  }
  if (health.isError) {
    return (
      <span className="badge badge-bad" title={health.error.message}>
        API unreachable
      </span>
    )
  }

  const { databaseStatus, serverVersion } = health.data
  return (
    <span className={`badge ${databaseBadgeClass(databaseStatus)}`} title={`reckon-server ${serverVersion}`}>
      API ok · {databaseLabel(databaseStatus)}
    </span>
  )
}

// DatabaseStatus is a generated union type. If the backend adds a status,
// regenerating the types makes these switches fail to compile until the new
// case is handled.
function databaseLabel(status: DatabaseStatus): string {
  switch (status) {
    case 'reachable':
      return 'database ok'
    case 'unreachable':
      return 'database unreachable'
    default:
      return status satisfies never
  }
}

function databaseBadgeClass(status: DatabaseStatus): string {
  switch (status) {
    case 'reachable':
      return 'badge-good'
    case 'unreachable':
      return 'badge-bad'
    default:
      return status satisfies never
  }
}
