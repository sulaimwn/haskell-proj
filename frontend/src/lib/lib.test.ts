import { describe, expect, it } from 'vitest'
import { barPercent } from './bars'
import { daysBefore, isoToday, monthLabel } from './months'
import { formatCents, parseAmountToCents } from './money'
import { pluralize } from './plural'
import { hrefFor, parseRoute } from './route'

describe('formatCents', () => {
  it('shows dollars and cents with thousands separators', () => {
    expect(formatCents(123456)).toBe('$1,234.56')
    expect(formatCents(100000000)).toBe('$1,000,000.00')
    expect(formatCents(5)).toBe('$0.05')
    expect(formatCents(0)).toBe('$0.00')
  })

  it('puts the minus sign before the dollar sign', () => {
    expect(formatCents(-5)).toBe('-$0.05')
    expect(formatCents(-123456)).toBe('-$1,234.56')
  })

  it('is exact for every amount from 0 to 20000 cents', () => {
    for (let cents = 0; cents <= 20000; cents++) {
      const text = formatCents(cents)
      expect(parseAmountToCents(text)).toBe(cents)
    }
  })
})

describe('parseAmountToCents', () => {
  it('reads what a person types', () => {
    expect(parseAmountToCents('12.34')).toBe(1234)
    expect(parseAmountToCents('$1,234.5')).toBe(123450)
    expect(parseAmountToCents('  7 ')).toBe(700)
    expect(parseAmountToCents('-5')).toBe(-500)
    expect(parseAmountToCents('0.07')).toBe(7)
  })

  it('refuses anything that is not an amount, and amounts that would lose cents', () => {
    expect(parseAmountToCents('')).toBeNull()
    expect(parseAmountToCents('twelve')).toBeNull()
    expect(parseAmountToCents('1.234')).toBeNull()
    expect(parseAmountToCents('1.')).toBeNull()
    expect(parseAmountToCents('.5')).toBeNull()
    expect(parseAmountToCents('1e3')).toBeNull()
    expect(parseAmountToCents('9'.repeat(40))).toBeNull()
  })
})

describe('routes', () => {
  it('reads a page and an account from the hash', () => {
    expect(parseRoute('#/review')).toEqual({ page: 'review' })
    expect(parseRoute('#/transactions/1234')).toEqual({ page: 'transactions', last4: '1234' })
    expect(parseRoute('#/transactions')).toEqual({ page: 'transactions', last4: null })
    expect(parseRoute('#/transactions/not-digits')).toEqual({ page: 'transactions', last4: null })
  })

  it('falls back to the accounts page for anything else', () => {
    expect(parseRoute('')).toEqual({ page: 'accounts' })
    expect(parseRoute('#/nonsense')).toEqual({ page: 'accounts' })
  })

  it('round-trips through the link', () => {
    for (const hash of ['#/accounts', '#/spending', '#/receivables', '#/review', '#/import', '#/transactions/0042']) {
      expect(hrefFor(parseRoute(hash))).toBe(hash)
    }
  })
})

describe('months and days', () => {
  it('names a month', () => {
    expect(monthLabel('2026-03')).toBe('March 2026')
    expect(monthLabel('2026-12')).toBe('December 2026')
    expect(monthLabel('2026-13')).toBe('2026-13')
    expect(monthLabel('soon')).toBe('soon')
  })

  it('counts days back across a month and a year boundary, in UTC', () => {
    expect(daysBefore(new Date('2026-03-02T12:00:00Z'), 2)).toBe('2026-02-28')
    expect(daysBefore(new Date('2026-01-01T00:00:00Z'), 1)).toBe('2025-12-31')
    expect(daysBefore(new Date('2024-03-01T00:00:00Z'), 1)).toBe('2024-02-29')
    expect(isoToday(new Date('2026-11-20T23:59:59Z'))).toBe('2026-11-20')
  })
})

describe('barPercent', () => {
  it('is the share of the month, as a width', () => {
    expect(barPercent(2500, 10000)).toBe(25)
    expect(barPercent(10000, 10000)).toBe(100)
  })

  it('never goes outside a bar, even for refunds or an empty month', () => {
    expect(barPercent(-300, 10000)).toBe(0)
    expect(barPercent(500, 0)).toBe(0)
    expect(barPercent(500, -100)).toBe(0)
    expect(barPercent(20000, 10000)).toBe(100)
  })
})

describe('pluralize', () => {
  it('only adds the s when there is not exactly one', () => {
    expect(pluralize(0, 'row')).toBe('0 rows')
    expect(pluralize(1, 'row')).toBe('1 row')
    expect(pluralize(2, 'screenshot row')).toBe('2 screenshot rows')
  })
})
