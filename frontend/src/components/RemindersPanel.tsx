import { useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api } from '../api/client'
import type { DueDateView, ReminderKindTag, ReminderView } from '../api/generated'
import { pluralize } from '../lib/plural'
import { useAction } from '../lib/useAction'
import { Notice } from './Notice'
import { QueryState } from './QueryState'

/**
 * What the recurring checks found (a month with no statement, screenshot rows
 * nobody confirmed, a due date coming up), and the due dates to be reminded of.
 * The server runs the checks daily; "Check now" runs them on demand.
 */
export function RemindersPanel() {
  const reminders = useQuery({ queryKey: ['reminders'], queryFn: api.getReminders })
  const checkNow = useAction<void>(() => api.checkReminders())
  return (
    <QueryState query={reminders}>
      {(data) => (
        <>
          <div className="toolbar">
            <span className="muted">{data.lastCheckedAt === null ? 'The checks have not run yet.' : `Last checked ${new Date(data.lastCheckedAt).toLocaleString()}. They run daily.`}</span>
            <button type="button" className="secondary" disabled={checkNow.isPending} onClick={() => checkNow.mutate()}>
              {checkNow.isPending ? 'Checking…' : 'Check now'}
            </button>
          </div>
          {data.reminders.length === 0 ? (
            <p className="muted">Nothing needs your attention.</p>
          ) : (
            <ul className="plain-list">
              {data.reminders.map((reminder) => (
                <ReminderItem key={reminder.reminderId} reminder={reminder} />
              ))}
            </ul>
          )}
          <Notice error={checkNow.error} />
          <DueDates dueDates={data.dueDates} />
        </>
      )}
    </QueryState>
  )
}

function kindLabel(kind: ReminderKindTag): string {
  switch (kind) {
    case 'statement_missing':
      return 'Statement'
    case 'provisional_stale':
      return 'Screenshots'
    case 'due_soon':
      return 'Due date'
    default:
      return kind satisfies never
  }
}

function ReminderItem({ reminder }: { reminder: ReminderView }) {
  const dismiss = useAction<void>(() => api.dismissReminder(reminder.reminderId))
  return (
    <li className="reminder">
      <span className="badge badge-neutral">{kindLabel(reminder.kind)}</span> {reminder.message}{' '}
      <button type="button" className="secondary" disabled={dismiss.isPending} onClick={() => dismiss.mutate()}>
        Dismiss
      </button>
      <Notice error={dismiss.error} />
    </li>
  )
}

function DueDates({ dueDates }: { dueDates: DueDateView[] }) {
  return (
    <details>
      <summary>Due dates ({dueDates.length})</summary>
      <p className="muted hint">A day of every month to be reminded of, like a card payment. Months too short for it use their last day.</p>
      {dueDates.length > 0 && (
        <ul className="plain-list">
          {dueDates.map((due) => (
            <DueDateItem key={due.dueDateId} due={due} />
          ))}
        </ul>
      )}
      <AddDueDateForm />
    </details>
  )
}

function DueDateItem({ due }: { due: DueDateView }) {
  const remove = useAction<void>(() => api.deleteDueDate(due.dueDateId))
  return (
    <li>
      {due.label}: day {due.dayOfMonth} of every month, reminded {pluralize(due.warnDays, 'day')} ahead{' '}
      <button type="button" className="secondary" disabled={remove.isPending} onClick={() => remove.mutate()}>
        Delete
      </button>
      <Notice error={remove.error} />
    </li>
  )
}

function AddDueDateForm() {
  const [label, setLabel] = useState('')
  const [day, setDay] = useState('')
  const [warn, setWarn] = useState('5')
  const [formError, setFormError] = useState<string | null>(null)
  const action = useAction(api.addDueDate)

  const submit = (event: FormEvent) => {
    event.preventDefault()
    const dayOfMonth = Number(day)
    const warnDays = warn.trim() === '' ? null : Number(warn)
    if (!Number.isInteger(dayOfMonth) || dayOfMonth < 1 || dayOfMonth > 31) {
      setFormError('The day of the month must be a whole number from 1 to 31.')
      return
    }
    if (warnDays !== null && (!Number.isInteger(warnDays) || warnDays < 0 || warnDays > 28)) {
      setFormError('Remind me must be a whole number of days, from 0 to 28.')
      return
    }
    setFormError(null)
    action.mutate({ label: label.trim(), dayOfMonth, warnDays })
  }

  return (
    <form className="inline-form" onSubmit={submit} aria-label="Add a due date">
      <label>
        What
        <input value={label} onChange={(event) => setLabel(event.target.value)} placeholder="Visa payment" required />
      </label>
      <label>
        Day of the month
        <input inputMode="numeric" value={day} onChange={(event) => setDay(event.target.value)} placeholder="15" required />
      </label>
      <label>
        Remind me (days ahead)
        <input inputMode="numeric" value={warn} onChange={(event) => setWarn(event.target.value)} />
      </label>
      <button type="submit" disabled={action.isPending}>
        {action.isPending ? 'Adding…' : 'Add due date'}
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
