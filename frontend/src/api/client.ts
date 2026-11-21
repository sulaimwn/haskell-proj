// Thin, typed wrappers around fetch, one per backend endpoint.
//
// The request and response types come from ./generated.ts, which is generated
// from the Haskell types (`make codegen`). Never declare an API type by hand
// here: add it to backend/src/Reckon/Api/Types.hs and regenerate.
import type {
  AccountSummary,
  ActionResult,
  AddPersonRequest,
  AddRuleRequest,
  ApiProblem,
  ApplyRuleRequest,
  BalanceRequest,
  CheckRuleRequest,
  HealthResponse,
  ImportCsvRequest,
  ImportScreenshotsRequest,
  LedgerAccountView,
  ReceivablesResponse,
  ReviewQueue,
  RuleCheck,
  RuleView,
  SettleRequest,
  SpendingMonth,
  SplitRequest,
  TransactionView,
  UploadedFile,
} from './generated'

export class ApiError extends Error {
  readonly status: number

  constructor(status: number, message: string) {
    super(message)
    this.name = 'ApiError'
    this.status = status
  }
}

/** The server explains refusals as `{ "problem": "..." }`; show that, not a bare status code. */
async function failureFrom(response: Response, what: string): Promise<ApiError> {
  try {
    const body = (await response.json()) as Partial<ApiProblem>
    if (typeof body.problem === 'string') {
      return new ApiError(response.status, body.problem)
    }
  } catch {
    // Not JSON (a proxy's error page, say): fall through to the generic message.
  }
  return new ApiError(response.status, `${response.status} ${response.statusText} from ${what}`)
}

async function getJson<Response>(path: string, query: Record<string, string | number | null | undefined> = {}): Promise<Response> {
  const parameters = new URLSearchParams()
  for (const [name, value] of Object.entries(query)) {
    // Empty filters are "not set", so the URL stays readable and the backend sees only real ones.
    if (value !== null && value !== undefined && value !== '') {
      parameters.set(name, String(value))
    }
  }
  const text = parameters.toString()
  const url = text === '' ? path : `${path}?${text}`
  const response = await fetch(url, { headers: { Accept: 'application/json' } })
  if (!response.ok) {
    throw await failureFrom(response, `GET ${path}`)
  }
  // The cast is safe as long as generated.ts is current, which CI enforces.
  return (await response.json()) as Response
}

async function postJson<Response>(path: string, body: unknown): Promise<Response> {
  const response = await fetch(path, {
    method: 'POST',
    // The backend refuses writes that aren't application/json (DECISIONS D061).
    headers: { Accept: 'application/json', 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  })
  if (!response.ok) {
    throw await failureFrom(response, `POST ${path}`)
  }
  return (await response.json()) as Response
}

/** A browser File as the API wants it: name and base64 content (DECISIONS D062). */
export async function toUploadedFile(file: File): Promise<UploadedFile> {
  const bytes = new Uint8Array(await file.arrayBuffer())
  // Build the binary string in slices: spreading a large array into fromCharCode overflows the call stack.
  let binary = ''
  const slice = 0x8000
  for (let start = 0; start < bytes.length; start += slice) {
    binary += String.fromCharCode(...bytes.subarray(start, start + slice))
  }
  return { fileName: file.name, contentBase64: btoa(binary) }
}

export interface TransactionQuery {
  from?: string
  to?: string
  search?: string
  limit?: number
}

const enc = encodeURIComponent

export const api = {
  getHealth: () => getJson<HealthResponse>('/api/health'),

  getAccounts: (asOf?: string) => getJson<AccountSummary[]>('/api/accounts', { asOf }),
  getTransactions: (last4: string, query: TransactionQuery = {}) =>
    getJson<TransactionView[]>(`/api/accounts/${enc(last4)}/transactions`, {
      from: query.from,
      to: query.to,
      q: query.search,
      limit: query.limit,
    }),
  getSpending: (from?: string, to?: string) => getJson<SpendingMonth[]>('/api/spending', { from, to }),
  getReceivables: (asOf?: string) => getJson<ReceivablesResponse>('/api/receivables', { asOf }),
  getReview: () => getJson<ReviewQueue>('/api/review'),
  getLedgerAccounts: () => getJson<LedgerAccountView[]>('/api/ledger-accounts'),
  getRules: () => getJson<RuleView[]>('/api/rules'),

  importCsv: (request: ImportCsvRequest) => postJson<ActionResult>('/api/imports/csv', request),
  importScreenshots: (request: ImportScreenshotsRequest) => postJson<ActionResult>('/api/imports/screenshots', request),
  postPendingRows: () => postJson<ActionResult>('/api/post', {}),

  settleRow: (rowId: number, request: SettleRequest) => postJson<ActionResult>(`/api/rows/${rowId}/settle`, request),
  recategorizeRow: (rowId: number, request: SettleRequest) => postJson<ActionResult>(`/api/rows/${rowId}/recategorize`, request),
  splitRow: (rowId: number, request: SplitRequest) => postJson<ActionResult>(`/api/rows/${rowId}/split`, request),
  releaseProvisional: (screenshotRowId: number) => postJson<ActionResult>(`/api/provisional/${screenshotRowId}/release`, {}),

  addPerson: (request: AddPersonRequest) => postJson<ActionResult>('/api/people', request),
  addRule: (request: AddRuleRequest) => postJson<ActionResult>('/api/rules', request),
  /** Reads and previews a rule without saving it. A bad rule is a normal answer, with where it went wrong. */
  checkRule: (request: CheckRuleRequest) => postJson<RuleCheck>('/api/rules/check', request),
  applyRule: (request: ApplyRuleRequest) => postJson<ActionResult>('/api/rules/apply', request),
  deleteRule: (ruleId: number) => postJson<ActionResult>(`/api/rules/${ruleId}/delete`, {}),
  setOpeningBalance: (last4: string, request: BalanceRequest) =>
    postJson<ActionResult>(`/api/accounts/${enc(last4)}/opening-balance`, request),
  addCheckpoint: (last4: string, request: BalanceRequest) => postJson<ActionResult>(`/api/accounts/${enc(last4)}/checkpoints`, request),
}
