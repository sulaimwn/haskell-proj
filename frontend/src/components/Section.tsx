import type { ReactNode } from 'react'

export function Section({ title, hint, children }: { title: string; hint?: string; children: ReactNode }) {
  return (
    <section className="section">
      <h2>{title}</h2>
      {hint && <p className="muted hint">{hint}</p>}
      {children}
    </section>
  )
}
