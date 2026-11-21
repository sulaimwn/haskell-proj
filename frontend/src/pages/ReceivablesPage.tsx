import { useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api } from '../api/client'
import { Money } from '../components/Money'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { Section } from '../components/Section'
import { useAction } from '../lib/useAction'

export function ReceivablesPage() {
  const receivables = useQuery({ queryKey: ['receivables'], queryFn: () => api.getReceivables() })
  return (
    <>
      <Section title="Who owes you" hint="Each friend's share of what you paid for them, less what they've paid back.">
        <QueryState query={receivables}>
          {(data) =>
            data.people.length === 0 ? (
              <p className="muted">Nobody yet. Add a friend below, then split a payment from the Transactions page.</p>
            ) : (
              <>
                <div className="table-wrap">
                  <table>
                    <thead>
                      <tr>
                        <th>Friend</th>
                        <th className="number">Owes you</th>
                      </tr>
                    </thead>
                    <tbody>
                      {data.people.map((person) => (
                        <tr key={person.name}>
                          <td>{person.name}</td>
                          <td className="number">
                            <Money cents={person.owedCents} />
                          </td>
                        </tr>
                      ))}
                    </tbody>
                    <tfoot>
                      <tr>
                        <th>Total</th>
                        <th className="number">
                          <Money cents={data.totalOwedCents} />
                        </th>
                      </tr>
                    </tfoot>
                  </table>
                </div>
              </>
            )
          }
        </QueryState>
      </Section>
      <Section title="Add a friend" hint="The text is what appears in their e-Transfers, so a repayment from them can be recognized later.">
        <AddPersonForm />
      </Section>
    </>
  )
}

function AddPersonForm() {
  const [name, setName] = useState('')
  const [matchText, setMatchText] = useState('')
  const action = useAction(api.addPerson)
  const submit = (event: FormEvent) => {
    event.preventDefault()
    action.mutate({ name: name.trim(), matchText: matchText.trim() })
  }
  return (
    <form className="inline-form" onSubmit={submit}>
      <label>
        Name
        <input value={name} onChange={(event) => setName(event.target.value)} required />
      </label>
      <label>
        Appears in e-Transfers as
        <input value={matchText} onChange={(event) => setMatchText(event.target.value)} required />
      </label>
      <button type="submit" disabled={action.isPending}>
        {action.isPending ? 'Adding…' : 'Add friend'}
      </button>
      <Notice result={action.data} error={action.error} />
    </form>
  )
}
