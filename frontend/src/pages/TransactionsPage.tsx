import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api } from '../api/client'
import type { TransactionView } from '../api/generated'
import { Money } from '../components/Money'
import { QueryState } from '../components/QueryState'
import { RowActions } from '../components/RowActions'
import { Section } from '../components/Section'
import { hrefFor } from '../lib/route'

const pageSize = 200

export function TransactionsPage({ last4 }: { last4: string | null }) {
  const accounts = useQuery({ queryKey: ['accounts'], queryFn: () => api.getAccounts() })
  return (
    <Section title="Transactions" hint="Money in is positive and money out is negative, for every kind of account. Corrections show as the corrected entry; the original stays in the ledger's history.">
      <QueryState query={accounts}>
        {(list) => {
          const chosen = last4 ?? list[0]?.last4 ?? null
          if (chosen === null) {
            return <p className="muted">No accounts yet.</p>
          }
          return (
            <>
              <nav className="tabs" aria-label="Account">
                {list.map((account) => (
                  <a
                    key={account.last4}
                    href={hrefFor({ page: 'transactions', last4: account.last4 })}
                    aria-current={account.last4 === chosen ? 'page' : undefined}
                  >
                    {account.nickname}
                  </a>
                ))}
              </nav>
              <TransactionTable key={chosen} last4={chosen} />
            </>
          )
        }}
      </QueryState>
    </Section>
  )
}

function TransactionTable({ last4 }: { last4: string }) {
  const [from, setFrom] = useState('')
  const [to, setTo] = useState('')
  const [search, setSearch] = useState('')
  const query = useQuery({
    queryKey: ['transactions', last4, from, to, search],
    queryFn: () => api.getTransactions(last4, { from, to, search, limit: pageSize }),
  })

  return (
    <>
      <div className="filters">
        <label>
          From
          <input type="date" value={from} onChange={(event) => setFrom(event.target.value)} />
        </label>
        <label>
          To
          <input type="date" value={to} onChange={(event) => setTo(event.target.value)} />
        </label>
        <label className="grow">
          Description contains
          <input type="search" value={search} onChange={(event) => setSearch(event.target.value)} placeholder="e.g. grocery" />
        </label>
      </div>
      <QueryState query={query}>
        {(rows) =>
          rows.length === 0 ? (
            <p className="muted">Nothing matches.</p>
          ) : (
            <>
              <div className="table-wrap">
                <table>
                  <thead>
                    <tr>
                      <th>Date</th>
                      <th>Description</th>
                      <th>Went to</th>
                      <th className="number">Amount</th>
                    </tr>
                  </thead>
                  <tbody>
                    {rows.map((row) => (
                      <TransactionRow key={row.entryId} row={row} />
                    ))}
                  </tbody>
                </table>
              </div>
              {rows.length === pageSize && <p className="muted">Showing the newest {pageSize}. Narrow the dates or search to see older ones.</p>}
            </>
          )
        }
      </QueryState>
    </>
  )
}

function TransactionRow({ row }: { row: TransactionView }) {
  // Only a posted CSV row can be re-pointed: screenshot rows are provisional
  // and settle themselves when their CSV arrives.
  const changeableRowId = row.source === 'csv' ? row.rowId : null
  return (
    <tr className={row.provisional ? 'provisional' : undefined}>
      <td className="nowrap">{row.date}</td>
      <td>
        {row.description}
        {row.provisional && <span className="badge badge-neutral tag">from screenshot</span>}
        {row.source === 'opening_balance' && <span className="badge badge-neutral tag">opening balance</span>}
        {changeableRowId !== null && <RowActions rowId={changeableRowId} />}
      </td>
      <td>
        {row.counterLines.map((line, index) => (
          <div key={index} className="counter-line">
            {line.account}
            {row.counterLines.length > 1 && (
              <>
                {' '}
                <Money cents={Math.abs(line.amountCents)} />
              </>
            )}
          </div>
        ))}
      </td>
      <td className="number">
        <Money cents={row.amountCents} signed />
      </td>
    </tr>
  )
}
