const monthNames = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
]

/** "2026-03" -> "March 2026". Anything else comes back unchanged. */
export function monthLabel(month: string): string {
  const match = /^(\d{4})-(0[1-9]|1[0-2])$/.exec(month)
  if (match === null) {
    return month
  }
  const [, year, number] = match
  return `${monthNames[Number(number) - 1]} ${year}`
}

/** The day, as YYYY-MM-DD, that is `days` before `from` (UTC, so it never depends on the machine's time zone). */
export function daysBefore(from: Date, days: number): string {
  const date = new Date(Date.UTC(from.getUTCFullYear(), from.getUTCMonth(), from.getUTCDate() - days))
  return date.toISOString().slice(0, 10)
}

export function isoToday(now: Date = new Date()): string {
  return now.toISOString().slice(0, 10)
}
