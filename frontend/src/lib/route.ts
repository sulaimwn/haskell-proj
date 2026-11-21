// A tiny hash router: the page is in the URL's #fragment, so there's nothing
// for the server to know about and a refresh keeps you where you were.

export type Route =
  | { page: 'accounts' }
  | { page: 'transactions'; last4: string | null }
  | { page: 'spending' }
  | { page: 'receivables' }
  | { page: 'review' }
  | { page: 'import' }

export const pageTitles: Record<Route['page'], string> = {
  accounts: 'Accounts',
  transactions: 'Transactions',
  spending: 'Spending',
  receivables: 'Receivables',
  review: 'Review',
  import: 'Import',
}

/** "#/transactions/1234" -> { page: 'transactions', last4: '1234' }. Anything unknown is the accounts page. */
export function parseRoute(hash: string): Route {
  const [page = '', argument = ''] = hash.replace(/^#\/?/, '').split('/')
  switch (page) {
    case 'transactions':
      return { page, last4: /^\d{4}$/.test(argument) ? argument : null }
    case 'spending':
    case 'receivables':
    case 'review':
    case 'import':
      return { page }
    default:
      return { page: 'accounts' }
  }
}

export function hrefFor(route: Route): string {
  return route.page === 'transactions' && route.last4 !== null
    ? `#/transactions/${route.last4}`
    : `#/${route.page}`
}
