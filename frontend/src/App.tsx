import { HealthBadge } from './components/HealthBadge'

export default function App() {
  return (
    <div className="app">
      <header className="app-header">
        <h1 className="wordmark">reckon</h1>
        <HealthBadge />
      </header>
      <main>
        <p className="lead">
          A personal double-entry ledger that reconciles to the cent against real bank statements.
        </p>
        <p className="muted">
          Phase 0 skeleton. Accounts, imports and reconciliation arrive in later phases.
        </p>
      </main>
    </div>
  )
}
