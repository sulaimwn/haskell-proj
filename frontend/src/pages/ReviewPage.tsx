import { useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api } from '../api/client'
import type { ImportFlag, ProvisionalRow, ReviewReasonKind, ReviewRow } from '../api/generated'
import { LedgerAccountSelect } from '../components/LedgerAccountSelect'
import { Money } from '../components/Money'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { RemindersPanel } from '../components/RemindersPanel'
import { Section } from '../components/Section'
import { hrefFor } from '../lib/route'
import { useAction } from '../lib/useAction'

export function ReviewPage() {
  const queue = useQuery({ queryKey: ['review'], queryFn: api.getReview })
  return (
    <QueryState query={queue}>
      {(data) => (
        <>
          <Section title="Reminders" hint="Things the ledger noticed that you might forget: a month with no statement, screenshot rows the bank hasn't confirmed, a payment coming due.">
            <RemindersPanel />
          </Section>
          <Section title="Needs a decision" hint="Rows the ledger would not post on its own, because it can't tell where they belong.">
            {data.unposted.length === 0 ? <p className="muted">Nothing to decide.</p> : data.unposted.map((row) => <UnpostedRow key={row.rowId} row={row} />)}
          </Section>
          <Section title="Read from screenshots" hint="These are in the ledger as provisional entries until a bank CSV confirms them.">
            {data.provisional.length === 0 ? <p className="muted">None waiting.</p> : data.provisional.map((row) => <ProvisionalCard key={row.screenshotRowId} row={row} />)}
          </Section>
          <Section title="Worth a look" hint="Things the importer noticed. Nothing here has been changed.">
            {data.importFlags.length === 0 ? <p className="muted">No import warnings.</p> : <ImportFlags flags={data.importFlags} />}
          </Section>
          <Section title="Teach it a rule" hint="Rows you settle by hand here can be settled for good by a rule.">
            <p>
              <a href={hrefFor({ page: 'rules' })}>Write a rule →</a>
            </p>
          </Section>
        </>
      )}
    </QueryState>
  )
}

function reasonLabel(reason: ReviewReasonKind): string {
  switch (reason) {
    case 'ambiguous_pair':
      return 'Could be a transfer between your accounts'
    case 'zero_amount':
      return 'Zero amount'
    case 'possible_repayment':
      return 'Might be a friend paying you back'
    default:
      return reason satisfies never
  }
}

function UnpostedRow({ row }: { row: ReviewRow }) {
  const [account, setAccount] = useState('')
  const action = useAction((chosen: string) => api.settleRow(row.rowId, { account: chosen }))
  const submit = (event: FormEvent) => {
    event.preventDefault()
    action.mutate(account)
  }
  return (
    <article className="card">
      <header className="card-header">
        <div>
          <h3>{row.description}</h3>
          <p className="muted">
            {row.date} · account {row.account} · {reasonLabel(row.reason)}
          </p>
        </div>
        <div className="balance">
          <Money cents={row.amountCents} signed />
        </div>
      </header>
      <p>{row.detail}</p>
      {row.people.length > 0 && (
        <p className="button-row">
          {row.people.map((person) => (
            <button key={person} type="button" disabled={action.isPending} onClick={() => action.mutate(`receivable:${person}`)}>
              Repayment from {person}
            </button>
          ))}
        </p>
      )}
      <form className="inline-form" onSubmit={submit}>
        <label>
          Post it to
          <LedgerAccountSelect value={account} onChange={setAccount} />
        </label>
        <button type="submit" disabled={action.isPending || account === ''}>
          Post
        </button>
      </form>
      <Notice result={action.data} error={action.error} />
    </article>
  )
}

function ProvisionalCard({ row }: { row: ProvisionalRow }) {
  const action = useAction<void>(() => api.releaseProvisional(row.screenshotRowId))
  return (
    <article className="card">
      <header className="card-header">
        <div>
          <h3>{row.description}</h3>
          <p className="muted">
            {row.date} · account {row.account} · {row.pending ? 'pending' : 'posted'} in the app
          </p>
        </div>
        <div className="balance">
          <Money cents={row.amountCents} signed />
        </div>
      </header>
      <p className="muted hint">If the bank never shows this, release it and the ledger forgets it.</p>
      <button type="button" disabled={action.isPending} onClick={() => action.mutate()}>
        Release
      </button>
      <Notice result={action.data} error={action.error} />
    </article>
  )
}

function ImportFlags({ flags }: { flags: ImportFlag[] }) {
  return (
    <ul className="plain-list">
      {flags.map((flag, index) => (
        <li key={index}>
          <strong>{flag.kind === 'possible_duplicate' ? 'Possible duplicate' : 'Missing from a newer export'}</strong> · {flag.date} · {flag.account} ·{' '}
          {flag.description} · <Money cents={flag.amountCents} signed />
          {flag.relatedDescription !== null && <span className="muted"> (looks like “{flag.relatedDescription}”)</span>}
        </li>
      ))}
    </ul>
  )
}
