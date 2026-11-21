/**
 * Points at where a rule went wrong: the offending line of the text, and a
 * line under it with a ^ at the column the server reported (counting from 1).
 * Tabs are kept as tabs so the caret lines up with the text above it.
 */
export function pointAt(text: string, line: number, column: number): string {
  const offending = text.split('\n')[line - 1] ?? ''
  const padding = offending
    .slice(0, Math.max(0, column - 1))
    .replace(/[^\t]/g, ' ')
    .padEnd(Math.max(0, column - 1), ' ')
  return `${offending}\n${padding}^`
}
