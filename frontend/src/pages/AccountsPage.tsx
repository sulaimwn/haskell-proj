import { useQuery } from '@tanstack/react-query'
import { api } from '../api/client'
import type { AccountSummary, CheckpointSummary } from '../api/generated'
import { BalanceForm } from '../components/BalanceForm'
import { Money } from '../components/Money'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { Section } from '../components/Section'
import { formatCents } from '../lib/money'
import { pluralize } from '../lib/plural'
import { hrefFor } from '../lib/route'
import { useAction } from '../lib/useAction'

export function AccountsPage() {
  const accounts = useQuery({ queryKey: ['accounts'], queryFn: () => api.getAccounts() })
  const posting = useAction<void>(() => api.postPendingRows())

  return (
    <>
      <Section title="Accounts" hint="Balances are today's, in the sign the bank prints: money in a chequing or savings account, money owed on a card.">
        <QueryState query={accounts}>
          {(list) =>
            list.length === 0 ? (
              <p className="muted">
                No accounts yet. <a href={hrefFor({ page: 'import' })}>Import a bank CSV</a> to create them.
              </p>
            ) : (
              <>
                <PostingBar accounts={list} onPost={() => posting.mutate()} busy={posting.isPending} />
                <Notice result={posting.data} error={posting.error} />
                <div className="cards">
                  {list.map((account) => (
                    <AccountCard key={account.last4} account={account} />
                  ))}
                </div>
              </>
            )
          }
        </QueryState>
      </Section>
    </>
  )
}

function PostingBar({ accounts, onPost, busy }: { accounts: AccountSummary[]; onPost: () => void; busy: boolean }) {
  const waiting = accounts.reduce((total, account) => total + account.unpostedRows, 0)
  return (
    <div className="toolbar">
      <span>
        {waiting === 0 ? 'Every imported row is in the ledger.' : `${pluralize(waiting, 'imported row')} ${waiting === 1 ? 'is' : 'are'} not in the ledger yet.`}
      </span>
      <button type="button" onClick={onPost} disabled={busy || waiting === 0}>
        {busy ? 'Posting…' : 'Post imported rows'}
      </button>
    </div>
  )
}

function AccountCard({ account }: { account: AccountSummary }) {
  return (
    <article className="card">
      <header className="card-header">
        <div>
          <h3>{account.nickname}</h3>
          <p className="muted">
            {kindLabel(account.kind)} · ending {account.last4}
          </p>
        </div>
        <div className="balance">
          <Money cents={account.balanceCents} />
        </div>
      </header>

      <ul className="facts">
        <li>
          {account.unpostedRows === 0 ? 'All rows posted' : `${pluralize(account.unpostedRows, 'row')} not posted`}
          {account.unpostedRows > 0 && (
            <>
              {' '}
              (<a href={hrefFor({ page: 'review' })}>review</a>)
            </>
          )}
        </li>
        {account.openProvisional > 0 && <li>{pluralize(account.openProvisional, 'screenshot row')} waiting for a bank CSV</li>}
      </ul>

      <Checkpoint checkpoint={account.latestCheckpoint} />

      <p>
        <a href={hrefFor({ page: 'transactions', last4: account.last4 })}>See transactions →</a>
      </p>

      <details>
        <summary>Record a statement</summary>
        <BalanceForm
          label="Statement balance"
          submitLabel="Reconcile"
          send={(request) => api.addCheckpoint(account.last4, request)}
        />
        <BalanceForm
          label="Opening balance"
          submitLabel="Set opening balance"
          send={(request) => api.setOpeningBalance(account.last4, request)}
        />
      </details>
    </article>
  )
}

function Checkpoint({ checkpoint }: { checkpoint: CheckpointSummary | null }) {
  if (checkpoint === null) {
    return <p className="muted">No statement recorded yet.</p>
  }
  const reconciled = checkpoint.state === 'reconciled'
  return (
    <div className={`checkpoint ${reconciled ? 'checkpoint-good' : 'checkpoint-bad'}`}>
      <p>
        <span className={`badge ${reconciled ? 'badge-good' : 'badge-bad'}`}>{reconciled ? 'Reconciled' : 'Gap'}</span>{' '}
        statement of {checkpoint.asOf}: bank says {formatCents(checkpoint.statementBalanceCents)}, ledger says{' '}
        {formatCents(checkpoint.ledgerBalanceCents)}
      </p>
      {/* The server's explanation is indented to show which lines belong to which finding, so keep its whitespace. */}
      {checkpoint.explanation.length > 0 && <pre className="explanation">{checkpoint.explanation.join('\n')}</pre>}
    </div>
  )
}

function kindLabel(kind: string): string {
  switch (kind) {
    case 'chequing':
      return 'Chequing'
    case 'savings':
      return 'Savings'
    case 'credit_card':
      return 'Credit card'
    default:
      return kind
  }
}
