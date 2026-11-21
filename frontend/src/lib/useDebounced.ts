import { useEffect, useState } from 'react'

/** The value, but only once it has stopped changing for `delayMs`: so a request isn't sent for every keystroke. */
export function useDebounced<Value>(value: Value, delayMs: number): Value {
  const [settled, setSettled] = useState(value)
  useEffect(() => {
    const timer = setTimeout(() => setSettled(value), delayMs)
    return () => clearTimeout(timer)
  }, [value, delayMs])
  return settled
}
