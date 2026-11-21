import react from '@vitejs/plugin-react'
import { defineConfig } from 'vitest/config'

// Port of the Haskell API. scripts/dev.sh exports RECKON_PORT from .env.
const apiPort = process.env.RECKON_PORT ?? '8080'

export default defineConfig({
  plugins: [react()],
  test: {
    // Display logic is plain functions; the few component tests need a DOM.
    environment: 'jsdom',
    include: ['src/**/*.test.{ts,tsx}'],
  },
  server: {
    port: 5173,
    strictPort: true,
    proxy: {
      // The browser calls /api/... on the Vite origin and Vite forwards it to
      // the backend, so in development the API is same-origin and needs no CORS.
      '/api': `http://localhost:${apiPort}`,
    },
  },
})
