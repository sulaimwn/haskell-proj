import { useQuery } from '@tanstack/react-query'
import { useState, type FormEvent } from 'react'
import { api, toUploadedFile } from '../api/client'
import { Notice } from '../components/Notice'
import { QueryState } from '../components/QueryState'
import { Section } from '../components/Section'
import { useAction } from '../lib/useAction'

export function ImportPage() {
  return (
    <>
      <Section title="Bank CSV" hint="An RBC export. Importing is safe to repeat: rows already imported are recognized and skipped. After importing, post the rows from the Accounts page.">
        <CsvForm />
      </Section>
      <Section
        title="Screenshots"
        hint="Screenshots of the RBC app are read by Claude and kept as provisional entries until a bank CSV confirms them. Only what was read is stored, not the image. The images are sent to Anthropic's API, so crop out anything you don't want sent."
      >
        <ScreenshotForm />
      </Section>
    </>
  )
}

function CsvForm() {
  const [file, setFile] = useState<File | null>(null)
  const action = useAction(async (chosen: File) => api.importCsv({ file: await toUploadedFile(chosen) }))
  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (file !== null) {
      action.mutate(file)
    }
  }
  return (
    <form className="inline-form" onSubmit={submit}>
      <label>
        CSV file
        <input type="file" accept=".csv,text/csv" onChange={(event) => setFile(event.target.files?.[0] ?? null)} />
      </label>
      <button type="submit" disabled={action.isPending || file === null}>
        {action.isPending ? 'Importing…' : 'Import'}
      </button>
      <Notice result={action.data} error={action.error} />
    </form>
  )
}

function ScreenshotForm() {
  const accounts = useQuery({ queryKey: ['accounts'], queryFn: () => api.getAccounts() })
  return (
    <QueryState query={accounts}>
      {(list) =>
        list.length === 0 ? (
          <p className="muted">Import a CSV first, so there's an account to attach screenshots to.</p>
        ) : (
          <ScreenshotFields accountChoices={list.map((account) => ({ last4: account.last4, label: `${account.nickname} · ${account.last4}` }))} />
        )
      }
    </QueryState>
  )
}

function ScreenshotFields({ accountChoices }: { accountChoices: { last4: string; label: string }[] }) {
  const [last4, setLast4] = useState(accountChoices[0]?.last4 ?? '')
  const [takenOn, setTakenOn] = useState('')
  const [files, setFiles] = useState<File[]>([])
  const action = useAction(async (chosen: File[]) =>
    api.importScreenshots({ last4, takenOn: takenOn === '' ? null : takenOn, files: await Promise.all(chosen.map(toUploadedFile)) }),
  )
  const submit = (event: FormEvent) => {
    event.preventDefault()
    if (files.length > 0) {
      action.mutate(files)
    }
  }
  return (
    <form className="inline-form" onSubmit={submit}>
      <label>
        Account
        <select value={last4} onChange={(event) => setLast4(event.target.value)}>
          {accountChoices.map((choice) => (
            <option key={choice.last4} value={choice.last4}>
              {choice.label}
            </option>
          ))}
        </select>
      </label>
      <label>
        Taken on <span className="muted">(optional; helps with dates that show no year)</span>
        <input type="date" value={takenOn} onChange={(event) => setTakenOn(event.target.value)} />
      </label>
      <label>
        Screenshots, in scroll order
        <input type="file" accept="image/png,image/jpeg,image/webp,image/gif" multiple onChange={(event) => setFiles(Array.from(event.target.files ?? []))} />
      </label>
      <button type="submit" disabled={action.isPending || files.length === 0}>
        {action.isPending ? 'Reading…' : 'Read screenshots'}
      </button>
      <Notice result={action.data} error={action.error} />
    </form>
  )
}
