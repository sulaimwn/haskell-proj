import { useQuery } from '@tanstack/react-query'
import { useState } from 'react'
import { api } from '../api/client'
import type { SpendingMonth } from '../api/generated'
import { Money } from '../components/Money'
import { QueryState } from '../components/QueryState'
import { Section } from '../components/Section'
import { barPercent } from '../lib/bars'
import { daysBefore, isoToday, monthLabel } from '../lib/months'

export function SpendingPage() {
  const [to, setTo] = useState(isoToday())
  const [from, setFrom] = useState(() => daysBefore(new Date(), 365))
  const months = useQuery({ queryKey: ['spending', from, to], queryFn: () => api.getSpending(from, to) })

  return (
    <Section title="Spending" hint="What went to expense accounts, month by month. Transfers, friends' shares and refunds are not spending.">
      <div className="filters">
        <label>
          From
          <input type="date" value={from} onChange={(event) => setFrom(event.target.value)} />
        </label>
        <label>
          To
          <input type="date" value={to} onChange={(event) => setTo(event.target.value)} />
        </label>
      </div>
      <QueryState query={months}>
        {(list) => (list.length === 0 ? <p className="muted">No spending in this range.</p> : list.map((month) => <MonthCard key={month.month} month={month} />))}
      </QueryState>
    </Section>
  )
}

function MonthCard({ month }: { month: SpendingMonth }) {
  return (
    <article className="card">
      <header className="card-header">
        <h3>{monthLabel(month.month)}</h3>
        <div className="balance">
          <Money cents={month.totalCents} />
        </div>
      </header>
      <ul className="bars">
        {month.categories.map((category) => (
          <li key={category.account}>
            <div className="bar-label">
              <span>{category.account}</span>
              <Money cents={category.cents} />
            </div>
            {/* The percentage only sets a bar's width: it is never shown or summed. */}
            <div className="bar-track" aria-hidden="true">
              <div className="bar-fill" style={{ width: `${barPercent(category.cents, month.totalCents)}%` }} />
            </div>
          </li>
        ))}
      </ul>
    </article>
  )
}
