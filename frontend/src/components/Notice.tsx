import type { ActionResult } from '../api/generated'

/**
 * What an action said: its message and detail lines on success, the
 * server's own explanation on failure. Nothing is hidden behind "Error".
 */
export function Notice({ result, error }: { result?: ActionResult | undefined; error?: Error | null | undefined }) {
  if (error) {
    return (
      <div className="notice notice-bad" role="alert">
        {error.message}
      </div>
    )
  }
  if (!result) {
    return null
  }
  return (
    <div className="notice notice-good" role="status">
      <strong>{result.message}</strong>
      {result.details.length > 0 && (
        <ul>
          {result.details.map((line, index) => (
            <li key={index}>{line}</li>
          ))}
        </ul>
      )}
    </div>
  )
}
