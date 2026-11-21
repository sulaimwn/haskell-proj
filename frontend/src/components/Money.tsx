import { formatCents } from '../lib/money'

/** An amount in integer cents. With `signed`, money in is green and money out is plain, so a column scans at a glance. */
export function Money({ cents, signed = false }: { cents: number; signed?: boolean }) {
  const className = signed ? (cents > 0 ? 'money money-in' : 'money') : 'money'
  return <span className={className}>{formatCents(cents)}</span>
}
