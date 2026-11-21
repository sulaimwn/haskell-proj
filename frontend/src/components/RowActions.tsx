import { useState, type FormEvent } from 'react'
import { api } from '../api/client'
import { useAction } from '../lib/useAction'
import { LedgerAccountSelect } from './LedgerAccountSelect'
import { Notice } from './Notice'

/** Change where a posted bank row went, either wholesale or as a shared expense. */
export function RowActions({ rowId }: { rowId: number }) {
  return (
    <details className="row-actions">
      <summary>Change…</summary>
      <h4>Move it to another account</h4>
      <RecategorizeForm rowId={rowId} />
      <h4>Or split it with friends</h4>
      <SplitForm rowId={rowId} />
    </details>
  )
}

function RecategorizeForm({ rowId }: { rowId: number }) {
  const [account, setAccount] = useState('')
  const action = useAction((chosen: string) => api.recategorizeRow(rowId, { account: chosen }))
  const submit = (event: FormEvent) => {
    event.preventDefault()
    action.mutate(account)
  }
  return (
    <form className="inline-form" onSubmit={submit}>
      <LedgerAccountSelect value={account} onChange={setAccount} />
      <button type="submit" disabled={action.isPending || account === ''}>
        {action.isPending ? 'Working…' : 'Move it there'}
      </button>
      <Notice result={action.data} error={action.error} />
    </form>
  )
}

function SplitForm({ rowId }: { rowId: number }) {
  const [category, setCategory] = useState('')
  const [friends, setFriends] = useState('')
  const action = useAction((request: { category: string; equalWith: string[] }) => api.splitRow(rowId, { ...request, shares: null }))
  const submit = (event: FormEvent) => {
    event.preventDefault()
    const names = friends
      .split(',')
      .map((name) => name.trim())
      .filter((name) => name !== '')
    action.mutate({ category, equalWith: names })
  }
  return (
    <form className="inline-form" onSubmit={submit}>
      <label>
        Category
        <LedgerAccountSelect value={category} onChange={setCategory} accountType="expense" />
      </label>
      <label>
        Split equally with
        <input value={friends} onChange={(event) => setFriends(event.target.value)} placeholder="Alex, Sam" required />
      </label>
      <p className="muted hint">You pay your equal share; each friend's share becomes something they owe you.</p>
      <button type="submit" disabled={action.isPending || category === ''}>
        {action.isPending ? 'Working…' : 'Split it'}
      </button>
      <Notice result={action.data} error={action.error} />
    </form>
  )
}
