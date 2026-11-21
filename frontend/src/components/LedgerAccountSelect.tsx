import { useQuery } from '@tanstack/react-query'
import { api } from '../api/client'

/** Pick a ledger account by name (expense:groceries, income:refunds, ...), optionally only one type. */
export function LedgerAccountSelect({
  value,
  onChange,
  accountType,
}: {
  value: string
  onChange: (account: string) => void
  accountType?: string
}) {
  const accounts = useQuery({ queryKey: ['ledger-accounts'], queryFn: api.getLedgerAccounts })
  const names = (accounts.data ?? []).filter((account) => accountType === undefined || account.accountType === accountType).map((account) => account.name)
  return (
    <select value={value} onChange={(event) => onChange(event.target.value)} aria-label="Ledger account" required>
      <option value="" disabled>
        {accounts.isPending ? 'Loading…' : 'Choose an account'}
      </option>
      {names.map((name) => (
        <option key={name} value={name}>
          {name}
        </option>
      ))}
    </select>
  )
}
