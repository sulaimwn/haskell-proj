/** 1 -> "1 row", 3 -> "3 rows". Only for regular English plurals (add an s). */
export function pluralize(count: number, noun: string): string {
  return `${count} ${noun}${count === 1 ? '' : 's'}`
}
