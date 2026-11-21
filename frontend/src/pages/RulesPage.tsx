import { keepPreviousData, useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api } from '../api/client'
import type { PreviewRowView, RulePreviewView } from '../api/generated'
import { Money } from '../components/Money'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { Section } from '../components/Section'
import { pointAt } from '../lib/caret'
import { pluralize } from '../lib/plural'
import { useAction } from '../lib/useAction'
import { useDebounced } from '../lib/useDebounced'

const examples = [
  'when description contains "TIM HORTONS" then categorize expense:coffee',
  'when description starts with "UBER" and amount < -50.00 then categorize expense:transport',
  'when description contains "DINNER" and account is credit card then split expense:food equally with alex, sam',
]

export function RulesPage() {
  const rules = useQuery({ queryKey: ['rules'], queryFn: api.getRules })
  return (
    <>
      <Section title="Rules" hint="Rows are categorized by the first rule, in this order, whose conditions all hold. A rule you save applies to rows posted from now on.">
        <QueryState query={rules}>
          {(list) =>
            list.length === 0 ? (
              <p className="muted">No rules yet. Write one below.</p>
            ) : (
              <ol className="rule-list">
                {list.map((rule) => (
                  <RuleItem key={rule.ruleId} ruleId={rule.ruleId} text={rule.ruleText} priority={rule.priority} problem={rule.problem} />
                ))}
              </ol>
            )
          }
        </QueryState>
      </Section>
      <Section title="Write a rule" hint="It is read as you type. Nothing changes until you save it.">
        <RuleEditor />
      </Section>
    </>
  )
}

function RuleItem({ ruleId, text, priority, problem }: { ruleId: number; text: string; priority: number; problem: string | null }) {
  const remove = useAction<void>(() => api.deleteRule(ruleId))
  return (
    <li className="rule-item">
      <code>{text}</code>
      <span className="muted"> priority {priority}</span>
      {problem !== null && <div className="notice notice-bad">This rule no longer reads as a rule, so it is being skipped: {problem}</div>}
      <button type="button" className="secondary" disabled={remove.isPending} onClick={() => remove.mutate()}>
        Delete
      </button>
      <Notice error={remove.error} />
    </li>
  )
}

function RuleEditor() {
  const [text, setText] = useState('')
  const [priority, setPriority] = useState('100')
  const settled = useDebounced(text, 300)
  const check = useQuery({
    queryKey: ['rule-check', settled],
    queryFn: () => api.checkRule({ ruleText: settled }),
    enabled: settled.trim() !== '',
    placeholderData: keepPreviousData,
  })
  const save = useAction((request: { apply: boolean }) => saveRule(text, priority, request.apply))

  // What the answer is about: while typing, it describes an older text.
  const stale = text !== settled
  const result = check.data
  const priorityNumber = Number(priority)
  const priorityValid = Number.isInteger(priorityNumber)
  const canSave = !stale && result !== undefined && result.problem === null && priorityValid && !save.isPending

  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (canSave) {
      save.mutate({ apply: false })
    }
  }

  return (
    <form onSubmit={submit} className="rule-editor">
      <label>
        Rule
        <textarea
          value={text}
          onChange={(event) => setText(event.target.value)}
          rows={3}
          spellCheck={false}
          placeholder={examples[0]}
          aria-describedby="rule-help"
        />
      </label>

      {text.trim() !== '' && check.isError && (
        <div className="notice notice-bad" role="alert">
          {check.error.message}
        </div>
      )}
      {!stale && result?.problem && (
        <div className="notice notice-bad" role="alert">
          <strong>
            Line {result.problem.line}, column {result.problem.column}: {result.problem.message}
          </strong>
          <pre className="rule-caret">{pointAt(text, result.problem.line, result.problem.column)}</pre>
        </div>
      )}
      {!stale && result?.problem === null && result.canonicalText !== null && (
        <p className="muted">
          Saved as: <code>{result.canonicalText}</code>
        </p>
      )}

      <div className="inline-form">
        <label>
          Priority <span className="muted">(lower runs first)</span>
          <input inputMode="numeric" value={priority} onChange={(event) => setPriority(event.target.value)} />
        </label>
        <button type="submit" disabled={!canSave}>
          {save.isPending ? 'Saving…' : 'Save rule'}
        </button>
        {!stale && result?.preview && result.preview.wouldMove > 0 && (
          <button type="button" className="secondary" disabled={!canSave} onClick={() => save.mutate({ apply: true })}>
            Save and move {pluralize(result.preview.wouldMove, 'posted row')}
          </button>
        )}
      </div>
      {!priorityValid && <div className="notice notice-bad">Priority must be a whole number.</div>}
      <Notice result={save.data} error={save.error} />

      {!stale && result?.preview && <Preview preview={result.preview} />}

      <details id="rule-help">
        <summary>How to write a rule</summary>
        <p className="muted hint">
          A rule is <code>when</code> one or more conditions joined by <code>and</code>, then <code>categorize ACCOUNT</code> or{' '}
          <code>split ACCOUNT equally with NAME, NAME</code>. Conditions: <code>description contains|starts with|ends with &quot;TEXT&quot;</code> (case and spacing don't matter),{' '}
          <code>amount &lt; | &lt;= | &gt; | &gt;= | = | != 12.50</code> (money out is negative), and{' '}
          <code>account is chequing|savings|credit card</code>. A split applies to money going out only, and the friends must already be added.
        </p>
        <ul className="plain-list">
          {examples.map((example) => (
            <li key={example}>
              <button type="button" className="link" onClick={() => setText(example)}>
                <code>{example}</code>
              </button>
            </li>
          ))}
        </ul>
      </details>
    </form>
  )
}

/** Saves the rule, then (if asked) applies it to the posted rows it would move. */
async function saveRule(text: string, priority: string, apply: boolean) {
  const saved = await api.addRule({ ruleText: text, priority: Number(priority) })
  if (!apply) {
    return saved
  }
  const applied = await api.applyRule({ ruleText: text })
  return { message: `${saved.message} ${applied.message}`, details: applied.details }
}

function Preview({ preview }: { preview: RulePreviewView }) {
  if (preview.matched === 0) {
    return <p className="muted">It matches none of the rows imported so far.</p>
  }
  return (
    <div>
      <p>
        <strong>{pluralize(preview.matched, 'imported row')} match.</strong> {pluralize(preview.wouldMove, 'posted row')} would move
        {preview.alreadyThere > 0 && `, ${preview.alreadyThere} already there`}
        {preview.onNextPost > 0 && `, ${preview.onNextPost} not posted yet`}
        {preview.cannotChange > 0 && `, ${preview.cannotChange} can't change`}.
      </p>
      <div className="table-wrap">
        <table>
          <thead>
            <tr>
              <th>Date</th>
              <th>Description</th>
              <th className="number">Amount</th>
              <th>What happens</th>
            </tr>
          </thead>
          <tbody>
            {preview.rows.map((row) => (
              <tr key={row.rowId}>
                <td className="nowrap">{row.date}</td>
                <td>{row.description}</td>
                <td className="number">
                  <Money cents={row.amountCents} signed />
                </td>
                <td>{effectText(row)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
      {preview.matched > preview.rows.length && <p className="muted">Showing the newest {preview.rows.length}.</p>}
    </div>
  )
}

function effectText(row: PreviewRowView): string {
  switch (row.effect) {
    case 'move':
      return `Moves from ${row.detail ?? 'another account'}`
    case 'already_there':
      return 'Already there'
    case 'on_next_post':
      return 'Applied when it is posted'
    case 'cannot_change':
      return `Can't change: ${row.detail ?? 'see the rule'}`
    default:
      return row.effect satisfies never
  }
}
