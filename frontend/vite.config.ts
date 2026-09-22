import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Port of the Haskell API. scripts/dev.sh exports RECKON_PORT from .env.
const apiPort = process.env.RECKON_PORT ?? '8080'

export default defineConfig({
  plugins: [react()],
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
