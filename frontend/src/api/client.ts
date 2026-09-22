// Thin, typed wrappers around fetch, one per backend endpoint.
//
// The request and response types come from ./generated.ts, which is generated
// from the Haskell types (`make codegen`). Never declare an API type by hand
// here: add it to backend/src/Reckon/Api/Types.hs and regenerate.
import type { HealthResponse } from './generated'

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

async function getJson<Response>(path: string): Promise<Response> {
  const response = await fetch(path, { headers: { Accept: 'application/json' } })
  if (!response.ok) {
    throw new ApiError(response.status, `${response.status} ${response.statusText} from GET ${path}`)
  }
  // The cast is safe as long as generated.ts is current, which CI enforces.
  return (await response.json()) as Response
}

export const api = {
  getHealth: () => getJson<HealthResponse>('/api/health'),
}
