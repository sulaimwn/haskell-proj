import { useEffect, useState } from 'react'
import { parseRoute, type Route } from './route'

/** The current page, kept in step with the URL's #fragment (back/forward and links just work). */
export function useHashRoute(): Route {
  const [route, setRoute] = useState<Route>(() => parseRoute(window.location.hash))
  useEffect(() => {
    const onChange = () => setRoute(parseRoute(window.location.hash))
    window.addEventListener('hashchange', onChange)
    return () => window.removeEventListener('hashchange', onChange)
  }, [])
  return route
}
