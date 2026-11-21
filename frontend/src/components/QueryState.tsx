import type { UseQueryResult } from '@tanstack/react-query'
import type { ReactNode } from 'react'

/** Loading and failure for a query, so each page only writes the case where there is data. */
export function QueryState<Data>({ query, children }: { query: UseQueryResult<Data, Error>; children: (data: Data) => ReactNode }) {
  if (query.isPending) {
    return <p className="muted">Loading…</p>
  }
  if (query.isError) {
    return (
      <div className="notice notice-bad" role="alert">
        {query.error.message}
      </div>
    )
  }
  return <>{children(query.data)}</>
}
