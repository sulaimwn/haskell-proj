import { fireEvent, screen, waitFor, within } from '@testing-library/react'
import { describe, expect, it } from 'vitest'
import type { AccountSummary, ReviewQueue, RuleCheck } from '../api/generated'
import { fakeBackend, renderWithQueries } from '../testing'
import { AccountsPage } from './AccountsPage'
import { ReviewPage } from './ReviewPage'
import { RulesPage } from './RulesPage'
import { ImportPage } from './ImportPage'
import { SpendingPage } from './SpendingPage'
import { TransactionsPage } from './TransactionsPage'

const chequing: AccountSummary = {
  last4: '1234',
  nickname: 'Everyday chequing',
  kind: 'chequing',
  balanceCents: 155243,
  unpostedRows: 0,
  openProvisional: 0,
  latestCheckpoint: { asOf: '2026-02-28', statementBalanceCents: 155243, ledgerBalanceCents: 155243, state: 'reconciled', explanation: [] },
}

describe('the accounts page', () => {
  it('shows each balance in dollars and whether the last statement reconciled', async () => {
    fakeBackend({ 'GET /api/accounts': [chequing] })
    renderWithQueries(<AccountsPage />)
    expect(await screen.findByText('Everyday chequing')).toBeTruthy()
    expect(screen.getAllByText('$1,552.43').length).toBeGreaterThan(0)
    expect(screen.getByText('Reconciled')).toBeTruthy()
  })

  it('explains a gap in the server’s words', async () => {
    const gap: AccountSummary = {
      ...chequing,
      latestCheckpoint: {
        asOf: '2026-02-28',
        statementBalanceCents: 155243,
        ledgerBalanceCents: 150000,
        state: 'gap',
        explanation: ['The ledger is $52.43 short of the statement.'],
      },
    }
    fakeBackend({ 'GET /api/accounts': [gap] })
    renderWithQueries(<AccountsPage />)
    expect(await screen.findByText('Gap')).toBeTruthy()
    expect(screen.getByText('The ledger is $52.43 short of the statement.')).toBeTruthy()
  })

  it('posts imported rows, then shows what the server said', async () => {
    const waiting = { ...chequing, unpostedRows: 8 }
    const calls = fakeBackend({
      'GET /api/accounts': [waiting],
      'POST /api/post': { message: 'Posted 5 rows.', details: ['Left for review: 3'] },
    })
    renderWithQueries(<AccountsPage />)
    fireEvent.click(await screen.findByRole('button', { name: 'Post imported rows' }))
    expect(await screen.findByText('Posted 5 rows.')).toBeTruthy()
    expect(screen.getByText('Left for review: 3')).toBeTruthy()
    expect(calls.filter((call) => call.method === 'POST')).toHaveLength(1)
  })

  it('records a statement balance as integer cents, and refuses one with a stray decimal', async () => {
    const calls = fakeBackend({
      'GET /api/accounts': [chequing],
      'POST /api/accounts/1234/checkpoints': { message: 'Recorded.', details: [] },
    })
    renderWithQueries(<AccountsPage />)
    const form = (await screen.findByRole('form', { name: 'Statement balance' })) as HTMLFormElement
    const balance = within(form).getByLabelText('Balance')

    fireEvent.change(balance, { target: { value: '1,552.435' } })
    fireEvent.submit(form)
    expect(await within(form).findByRole('alert')).toBeTruthy()
    expect(calls.some((call) => call.method === 'POST')).toBe(false)

    fireEvent.change(balance, { target: { value: '1,552.43' } })
    fireEvent.change(within(form).getByLabelText('Date'), { target: { value: '2026-02-28' } })
    fireEvent.submit(form)
    await waitFor(() => expect(calls.some((call) => call.method === 'POST')).toBe(true))
    expect(calls.find((call) => call.method === 'POST')?.body).toEqual({ date: '2026-02-28', balanceCents: 155243 })
  })

  it('says what is wrong when the API is down', async () => {
    fakeBackend({ 'GET /api/accounts': { status: 500, body: { problem: 'The database is unreachable.' } } })
    renderWithQueries(<AccountsPage />)
    expect(await screen.findByText('The database is unreachable.')).toBeTruthy()
  })
})

describe('the review page', () => {
  const queue: ReviewQueue = {
    unposted: [
      {
        rowId: 41,
        account: '1234',
        date: '2026-02-14',
        description: 'E-TRANSFER ALEX EXAMPLE',
        amountCents: 2500,
        reason: 'possible_repayment',
        detail: 'Looks like a payment from ALEX.',
        people: ['ALEX'],
      },
    ],
    provisional: [],
    importFlags: [],
  }

  it('applies a possible repayment to the friend it names', async () => {
    const calls = fakeBackend({
      'GET /api/review': queue,
      'GET /api/ledger-accounts': [{ name: 'income:refunds', accountType: 'income' }],
      'POST /api/rows/41/settle': { message: 'Posted.', details: [] },
    })
    renderWithQueries(<ReviewPage />)
    fireEvent.click(await screen.findByRole('button', { name: 'Repayment from ALEX' }))
    expect(await screen.findByText('Posted.')).toBeTruthy()
    expect(calls.find((call) => call.method === 'POST')?.body).toEqual({ account: 'receivable:ALEX' })
  })
})

describe('the spending page', () => {
  it('shows a month’s total and its categories', async () => {
    fakeBackend({
      'GET /api/spending': [
        {
          month: '2026-02',
          totalCents: 12000,
          categories: [
            { account: 'expense:groceries', cents: 9000 },
            { account: 'expense:transit', cents: 3000 },
          ],
        },
      ],
    })
    renderWithQueries(<SpendingPage />)
    expect(await screen.findByText('February 2026')).toBeTruthy()
    expect(screen.getByText('expense:groceries')).toBeTruthy()
    expect(screen.getByText('$90.00')).toBeTruthy()
    expect(screen.getAllByText('$120.00').length).toBeGreaterThan(0)
  })
})

describe('the transactions page', () => {
  const groceries = {
    entryId: 9,
    date: '2026-03-04',
    description: 'Interac purchase - CORNER GROCERY',
    amountCents: -10000,
    counterLines: [{ account: 'expense:groceries', amountCents: 10000 }],
    source: 'csv',
    rowId: 77,
    provisional: false,
  }

  it('shows money out as negative and sends the search text to the server', async () => {
    const calls = fakeBackend({ 'GET /api/accounts': [chequing], 'GET /api/accounts/1234/transactions': [groceries] })
    renderWithQueries(<TransactionsPage last4="1234" />)
    expect(await screen.findByText('-$100.00')).toBeTruthy()
    expect(screen.getByText('expense:groceries')).toBeTruthy()

    fireEvent.change(screen.getByLabelText('Description contains'), { target: { value: 'corner' } })
    await waitFor(() => expect(calls.some((call) => call.url.includes('q=corner'))).toBe(true))
  })

  it('splits a row equally with the friends typed, as the API expects', async () => {
    const calls = fakeBackend({
      'GET /api/accounts': [chequing],
      'GET /api/accounts/1234/transactions': [groceries],
      'GET /api/ledger-accounts': [{ name: 'expense:food', accountType: 'expense' }],
      'POST /api/rows/77/split': { message: 'Split it three ways.', details: [] },
    })
    renderWithQueries(<TransactionsPage last4="1234" />)
    fireEvent.click(await screen.findByText('Change…'))
    fireEvent.change(await screen.findByLabelText('Category'), { target: { value: 'expense:food' } })
    fireEvent.change(screen.getByLabelText('Split equally with'), { target: { value: 'Alex, Sam ,' } })
    fireEvent.click(screen.getByRole('button', { name: 'Split it' }))
    expect(await screen.findByText('Split it three ways.')).toBeTruthy()
    expect(calls.find((call) => call.method === 'POST')?.body).toEqual({ category: 'expense:food', equalWith: ['Alex', 'Sam'], shares: null })
  })

  it('offers no changes on a row that came from a screenshot', async () => {
    const provisional = { ...groceries, source: 'screenshot', provisional: true }
    fakeBackend({ 'GET /api/accounts': [chequing], 'GET /api/accounts/1234/transactions': [provisional] })
    renderWithQueries(<TransactionsPage last4="1234" />)
    expect(await screen.findByText('from screenshot')).toBeTruthy()
    expect(screen.queryByText('Change…')).toBeNull()
  })
})

describe('the import page', () => {
  it('uploads a CSV as base64 JSON and shows what the importer said', async () => {
    const calls = fakeBackend({ 'POST /api/imports/csv': { message: '4 rows added.', details: ['0 already present'] } })
    renderWithQueries(<ImportPage />)
    const input = screen.getAllByLabelText(/CSV file/)[0] as HTMLInputElement
    const file = new File(['a,b\n1,2\n'], 'export.csv', { type: 'text/csv' })
    fireEvent.change(input, { target: { files: [file] } })
    fireEvent.click(screen.getByRole('button', { name: 'Import' }))
    expect(await screen.findByText('4 rows added.')).toBeTruthy()
    const body = calls.find((call) => call.method === 'POST')?.body as { file: { fileName: string; contentBase64: string } }
    expect(body.file.fileName).toBe('export.csv')
    expect(atob(body.file.contentBase64)).toBe('a,b\n1,2\n')
  })
})

describe('the rules page', () => {
  const source = 'when description contains "bistro" and amount < 0 then categorize expense:food'
  const goodCheck: RuleCheck = {
    problem: null,
    canonicalText: 'when description contains "BISTRO" and amount < 0.00 then categorize expense:food',
    preview: {
      matched: 3,
      wouldMove: 2,
      alreadyThere: 0,
      onNextPost: 1,
      cannotChange: 0,
      rows: [
        { rowId: 2, date: '2026-02-05', description: 'Interac purchase - TASTY BISTRO', amountCents: -1200, effect: 'move', detail: 'expense:uncategorized' },
        { rowId: 1, date: '2026-02-03', description: 'Interac purchase - TASTY BISTRO', amountCents: -3001, effect: 'move', detail: 'expense:uncategorized' },
        { rowId: 4, date: '2026-02-20', description: 'Interac purchase - TASTY BISTRO', amountCents: -500, effect: 'on_next_post', detail: null },
      ],
    },
  }
  const badCheck: RuleCheck = {
    problem: { line: 1, column: 15, message: 'amounts have at most two decimals, like 12.50' },
    canonicalText: null,
    preview: null,
  }

  it('lists the rules in order, flagging one that no longer reads', async () => {
    fakeBackend({
      'GET /api/rules': [
        { ruleId: 1, ruleText: 'when description contains "HYDRO" then categorize expense:utilities', priority: 50, problem: null },
        { ruleId: 2, ruleText: 'when the moon is full', priority: 100, problem: 'line 1, column 6: expected a condition' },
      ],
    })
    renderWithQueries(<RulesPage />)
    expect(await screen.findByText('when description contains "HYDRO" then categorize expense:utilities')).toBeTruthy()
    expect(screen.getByText(/no longer reads as a rule/)).toBeTruthy()
  })

  it('points at the mistake as the rule is typed, and keeps Save off', async () => {
    const calls = fakeBackend({ 'GET /api/rules': [], 'POST /api/rules/check': badCheck })
    renderWithQueries(<RulesPage />)
    fireEvent.change(await screen.findByLabelText('Rule'), { target: { value: 'when amount < 1.234 then categorize expense:x' } })
    expect(await screen.findByText('Line 1, column 15: amounts have at most two decimals, like 12.50')).toBeTruthy()
    expect(document.querySelector('.rule-caret')?.textContent).toBe('when amount < 1.234 then categorize expense:x\n              ^')
    expect((screen.getByRole('button', { name: 'Save rule' }) as HTMLButtonElement).disabled).toBe(true)
    expect(calls.filter((call) => call.method === 'POST' && call.url === '/api/rules')).toHaveLength(0)
  })

  it('previews what a good rule would do, then saves exactly what was typed', async () => {
    const calls = fakeBackend({
      'GET /api/rules': [],
      'POST /api/rules/check': goodCheck,
      'POST /api/rules': { message: 'Saved the rule.', details: [] },
    })
    renderWithQueries(<RulesPage />)
    fireEvent.change(await screen.findByLabelText('Rule'), { target: { value: source } })
    expect(await screen.findByText(/3 imported rows match\./)).toBeTruthy()
    expect(screen.getAllByText('Moves from expense:uncategorized')).toHaveLength(2)
    expect(screen.getByText('Applied when it is posted')).toBeTruthy()
    expect(screen.getByText('when description contains "BISTRO" and amount < 0.00 then categorize expense:food')).toBeTruthy()

    fireEvent.click(screen.getByRole('button', { name: 'Save rule' }))
    expect(await screen.findByText('Saved the rule.')).toBeTruthy()
    expect(calls.find((call) => call.method === 'POST' && call.url === '/api/rules')?.body).toEqual({ ruleText: source, priority: 100 })
  })

  it('can save and then move the posted rows it matches', async () => {
    const calls = fakeBackend({
      'GET /api/rules': [],
      'POST /api/rules/check': goodCheck,
      'POST /api/rules': { message: 'Saved the rule.', details: [] },
      'POST /api/rules/apply': { message: 'Moved 2 rows.', details: [] },
    })
    renderWithQueries(<RulesPage />)
    fireEvent.change(await screen.findByLabelText('Rule'), { target: { value: source } })
    fireEvent.click(await screen.findByRole('button', { name: 'Save and move 2 posted rows' }))
    expect(await screen.findByText('Saved the rule. Moved 2 rows.')).toBeTruthy()
    expect(calls.filter((call) => call.method === 'POST' && call.url !== '/api/rules/check').map((call) => call.url)).toEqual(['/api/rules', '/api/rules/apply'])
    expect(calls.find((call) => call.url === '/api/rules/apply')?.body).toEqual({ ruleText: source })
  })

  it('refuses a priority that is not a whole number without asking the server', async () => {
    fakeBackend({ 'GET /api/rules': [], 'POST /api/rules/check': goodCheck })
    renderWithQueries(<RulesPage />)
    fireEvent.change(await screen.findByLabelText('Rule'), { target: { value: source } })
    await screen.findByText(/3 imported rows match\./)
    fireEvent.change(screen.getByLabelText(/Priority/), { target: { value: '1.5' } })
    expect(screen.getByText('Priority must be a whole number.')).toBeTruthy()
    expect((screen.getByRole('button', { name: 'Save rule' }) as HTMLButtonElement).disabled).toBe(true)
  })
})
