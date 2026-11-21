// Money is integer cents everywhere. These two functions are the only places
// it becomes text or comes from text, and neither goes through a float that
// could round.

/** 123456 -> "$1,234.56", -5 -> "-$0.05". */
export function formatCents(cents: number): string {
  const sign = cents < 0 ? '-' : ''
  const magnitude = Math.abs(cents)
  const remainder = magnitude % 100
  // (magnitude - remainder) is a multiple of 100, so this division is exact.
  const dollars = (magnitude - remainder) / 100
  return `${sign}$${dollars.toLocaleString('en-CA')}.${String(remainder).padStart(2, '0')}`
}

/**
 * What a person types into an amount box: "12.34", "$1,234.5", "-5".
 * Returns integer cents, or null if it isn't an amount (including more
 * than two decimal places, which would silently lose money).
 */
export function parseAmountToCents(text: string): number | null {
  const cleaned = text.replace(/[$,\s]/g, '')
  const match = /^(-?)(\d+)(?:\.(\d{1,2}))?$/.exec(cleaned)
  if (match === null) {
    return null
  }
  const [, minus, whole, fraction = ''] = match
  const magnitude = Number(whole) * 100 + Number(fraction.padEnd(2, '0'))
  if (!Number.isSafeInteger(magnitude)) {
    return null
  }
  return minus === '-' ? -magnitude : magnitude
}
