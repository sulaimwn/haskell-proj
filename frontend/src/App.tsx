import { HealthBadge } from './components/HealthBadge'
import { hrefFor, pageTitles, type Route } from './lib/route'
import { useHashRoute } from './lib/useHashRoute'
import { AccountsPage } from './pages/AccountsPage'
import { ImportPage } from './pages/ImportPage'
import { ReceivablesPage } from './pages/ReceivablesPage'
import { ReviewPage } from './pages/ReviewPage'
import { RulesPage } from './pages/RulesPage'
import { SpendingPage } from './pages/SpendingPage'
import { TransactionsPage } from './pages/TransactionsPage'

const navigation: Route[] = [
  { page: 'accounts' },
  { page: 'transactions', last4: null },
  { page: 'spending' },
  { page: 'receivables' },
  { page: 'review' },
  { page: 'rules' },
  { page: 'import' },
]

export default function App() {
  const route = useHashRoute()
  return (
    <div className="app">
      <header className="app-header">
        <h1 className="wordmark">reckon</h1>
        <HealthBadge />
      </header>
      <nav className="nav" aria-label="Pages">
        {navigation.map((item) => (
          <a key={item.page} href={hrefFor(item)} aria-current={item.page === route.page ? 'page' : undefined}>
            {pageTitles[item.page]}
          </a>
        ))}
      </nav>
      <main>
        <Page route={route} />
      </main>
    </div>
  )
}

function Page({ route }: { route: Route }) {
  switch (route.page) {
    case 'accounts':
      return <AccountsPage />
    case 'transactions':
      return <TransactionsPage last4={route.last4} />
    case 'spending':
      return <SpendingPage />
    case 'receivables':
      return <ReceivablesPage />
    case 'review':
      return <ReviewPage />
    case 'rules':
      return <RulesPage />
    case 'import':
      return <ImportPage />
    default:
      return route satisfies never
  }
}
