/**
 * A category's share of the month, as a bar width in percent. This is the
 * one place a division touches money, and its result is only ever a CSS
 * width: never shown, never summed. Refunds can push a category below zero
 * and a month's total can be zero, so the result is clamped to 0-100.
 */
export function barPercent(categoryCents: number, totalCents: number): number {
  if (totalCents <= 0) {
    return 0
  }
  return Math.min(100, Math.max(0, (categoryCents / totalCents) * 100))
}
