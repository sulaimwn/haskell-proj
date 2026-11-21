import { useState, type FormEvent } from 'react'
import type { ActionResult, BalanceRequest } from '../api/generated'
import { parseAmountToCents } from '../lib/money'
import { isoToday } from '../lib/months'
import { useAction } from '../lib/useAction'
import { Notice } from './Notice'

/**
 * A date and a balance as typed on the statement, in the account's natural
 * sign (money in a chequing account, money owed on a card). Used for both
 * the opening balance and a statement checkpoint: they ask for the same two
 * things and differ only in what the backend does with them.
 */
export function BalanceForm({
  label,
  submitLabel,
  send,
}: {
  label: string
  submitLabel: string
  send: (request: BalanceRequest) => Promise<ActionResult>
}) {
  const [date, setDate] = useState(isoToday())
  const [amount, setAmount] = useState('')
  const [formError, setFormError] = useState<string | null>(null)
  const action = useAction(send)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    const balanceCents = parseAmountToCents(amount)
    if (balanceCents === null) {
      setFormError('Enter the balance as dollars and cents, like 1234.56 (at most two decimals).')
      return
    }
    setFormError(null)
    action.mutate({ date, balanceCents })
  }

  return (
    <form className="inline-form" onSubmit={submit} aria-label={label}>
      <strong className="form-label">{label}</strong>
      <label>
        Date
        <input type="date" value={date} onChange={(event) => setDate(event.target.value)} required />
      </label>
      <label>
        Balance
        <input inputMode="decimal" placeholder="0.00" value={amount} onChange={(event) => setAmount(event.target.value)} required />
      </label>
      <button type="submit" disabled={action.isPending}>
        {action.isPending ? 'Working…' : submitLabel}
      </button>
      {formError && (
        <div className="notice notice-bad" role="alert">
          {formError}
        </div>
      )}
      <Notice result={action.data} error={action.error} />
    </form>
  )
}
