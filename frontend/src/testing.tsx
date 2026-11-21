// Helpers shared by the component tests: a fake `fetch` that answers from a
// table of routes (and remembers what it was asked), and a render function
// with a fresh query cache so no test sees another's data.
import { QueryClient, QueryClientProvider } from '@tanstack/react-query'
import { cleanup, render } from '@testing-library/react'
import type { ReactElement } from 'react'
import { afterEach, vi } from 'vitest'

afterEach(() => {
  cleanup()
  vi.unstubAllGlobals()
})

export interface FakeCall {
  method: string
  url: string
  headers: Record<string, string>
  body: unknown
}

type Answer = { status?: number; body: unknown }

/**
 * Replaces `fetch`. `routes` maps "METHOD /path" (query string ignored) to a
 * body, `{status, body}`, or a function of the request's JSON body returning
 * either. A request with no route fails the test loudly.
 */
export function fakeBackend(routes: Record<string, unknown>): FakeCall[] {
  const calls: FakeCall[] = []
  vi.stubGlobal(
    'fetch',
    vi.fn(async (input: RequestInfo | URL, init?: RequestInit) => {
      const url = String(input)
      const method = init?.method ?? 'GET'
      const path = url.split('?')[0]
      calls.push({
        method,
        url,
        headers: Object.fromEntries(Object.entries((init?.headers ?? {}) as Record<string, string>)),
        body: typeof init?.body === 'string' ? JSON.parse(init.body) : undefined,
      })
      const route = routes[`${method} ${path}`]
      if (route === undefined) {
        throw new Error(`The test has no answer for ${method} ${url}`)
      }
      const answer = typeof route === 'function' ? (route as (body: unknown) => unknown)(calls[calls.length - 1]?.body) : route
      const { status = 200, body } = isAnswer(answer) ? answer : { body: answer }
      return new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json' } })
    }),
  )
  return calls
}

function isAnswer(value: unknown): value is Answer {
  return typeof value === 'object' && value !== null && 'body' in value && Object.keys(value).every((key) => key === 'body' || key === 'status')
}

export function renderWithQueries(element: ReactElement) {
  const client = new QueryClient({ defaultOptions: { queries: { retry: false }, mutations: { retry: false } } })
  return render(<QueryClientProvider client={client}>{element}</QueryClientProvider>)
}
